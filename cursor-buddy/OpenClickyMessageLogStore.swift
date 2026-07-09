import Foundation

nonisolated final class OpenClickyMessageLogStore: @unchecked Sendable {
    static let shared = OpenClickyMessageLogStore()

    private let fileManager: FileManager
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.jkneen.openclicky.message-log-writes", qos: .utility)

    let logDirectory: URL

    var reviewCommentsFile: URL {
        logDirectory.appendingPathComponent("log-review-comments.jsonl", isDirectory: false)
    }

    var agentReviewCommentsFile: URL {
        logDirectory.appendingPathComponent("agent-review-comments.md", isDirectory: false)
    }

    var currentLogFile: URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return logDirectory.appendingPathComponent("messages-\(formatter.string(from: Date())).jsonl", isDirectory: false)
    }

    init(fileManager: FileManager = .default, logDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.logDirectory = logDirectory ?? Self.defaultLogDirectory(fileManager: fileManager)
    }

    /// Message logs can contain transcripts and agent output. Keep a short,
    /// privacy-oriented diagnostic window rather than a month of plaintext.
    static let defaultRetentionDays: Int = 14
    static let reviewCommentRetentionDays: Int = 30
    private static let maximumConversationPreviewLength = 2_000
    private static let maximumReviewCommentLength = 2_000
    private static let maximumReviewSourceExcerptLength = 1_200

    /// Prune message logs and review artifacts older than their retention
    /// windows. Review comments used to be exempt and could retain full raw
    /// transcripts indefinitely.
    func pruneOldMessageLogs(olderThanDays days: Int = OpenClickyMessageLogStore.defaultRetentionDays) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let files = self.availableMessageLogFiles()
            for file in files {
                let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if modDate < cutoff {
                    try? self.fileManager.removeItem(at: file)
                }
            }
            let reviewCutoff = Date().addingTimeInterval(-Double(Self.reviewCommentRetentionDays) * 86_400)
            self.pruneReviewCommentsLocked(olderThan: reviewCutoff)
        }
    }

    func availableMessageLogFiles() -> [URL] {
        do {
            try ensureLogDirectoryExists()
            let files = try fileManager.contentsOfDirectory(
                at: logDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            return files
                .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("messages-") }
                .sorted { first, second in
                    let firstDate = (try? first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let secondDate = (try? second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return firstDate > secondDate
                }
        } catch {
            print("OpenClicky message log listing failed: \(error.localizedDescription)")
            return []
        }
    }

    func ensureAgentReviewCommentsFile() {
        lock.lock()
        defer { lock.unlock() }

        do {
            try ensureLogDirectoryExists()
            if !fileManager.fileExists(atPath: agentReviewCommentsFile.path) {
                let header = """
                # OpenClicky Log Review Comments

                Review comments retain diagnostic metadata and a privacy-filtered source excerpt. They expire automatically; use the live log viewer for current context.
                """
                try writePrivateFile(Data(header.utf8), to: agentReviewCommentsFile)
            }
            try ensureEmptyJSONLReviewCommentsFileExists()
        } catch {
            print("OpenClicky log review comment file setup failed: \(error.localizedDescription)")
        }
    }

    func appendReviewComment(
        sourceLogFile: URL,
        sourceLineNumber: Int,
        entryID: String,
        entryTimestamp: String,
        lane: String,
        direction: String,
        event: String,
        rawEntry: String,
        comment: String
    ) {
        let trimmedComment = Self.truncated(
            comment.trimmingCharacters(in: .whitespacesAndNewlines),
            maxLength: Self.maximumReviewCommentLength
        )
        guard !trimmedComment.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        do {
            try ensureLogDirectoryExists()
            if !fileManager.fileExists(atPath: agentReviewCommentsFile.path) {
                let header = """
                # OpenClicky Log Review Comments

                Review comments retain diagnostic metadata and a privacy-filtered source excerpt. They expire automatically; use the live log viewer for current context.
                """
                try writePrivateFile(Data(header.utf8), to: agentReviewCommentsFile)
            }
            try ensureEmptyJSONLReviewCommentsFileExists()

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            let createdAt = isoFormatter.string(from: Date())

            let entry: [String: Any] = [
                "id": UUID().uuidString,
                "createdAt": createdAt,
                "sourceLogFile": sourceLogFile.lastPathComponent,
                "sourceLineNumber": sourceLineNumber,
                "entryID": entryID,
                "entryTimestamp": entryTimestamp,
                "lane": lane,
                "direction": direction,
                "event": event,
                "status": "open",
                "fixedBy": "",
                "verifiedAt": "",
                "comment": trimmedComment,
                "sourceExcerpt": Self.redactedReviewExcerpt(rawEntry)
            ]

            guard JSONSerialization.isValidJSONObject(entry) else { return }
            var jsonlData = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            jsonlData.append(0x0A)
            try append(jsonlData, to: reviewCommentsFile)

            let markdownEntry = Self.markdownReviewEntry(from: entry)
            try append(Data(markdownEntry.utf8), to: agentReviewCommentsFile)
        } catch {
            print("OpenClicky log review comment write failed: \(error.localizedDescription)")
        }
    }

    func append(lane: String, direction: String, event: String, fields: [String: Any] = [:]) {
        let sanitizedFields = Self.sanitizedJSONObject(fields)
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            do {
                try self.ensureLogDirectoryExists()

                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)

                let entry: [String: Any] = [
                    "timestamp": isoFormatter.string(from: Date()),
                    "lane": lane,
                    "direction": direction,
                    "event": event,
                    "fields": sanitizedFields
                ]

                guard JSONSerialization.isValidJSONObject(entry) else { return }
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                data.append(0x0A)

                try self.append(data, to: self.currentLogFile)
                self.emitConsoleLog(entry: entry)
            } catch {
                print("OpenClicky message log write failed: \(error.localizedDescription)")
            }
        }
    }

    func appendConversationTurn(
        lane: String,
        direction: String,
        role: String,
        text: String,
        source: String,
        sessionID: String? = nil,
        title: String? = nil,
        extraFields: [String: Any] = [:]
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        var fields = extraFields
        fields["role"] = role
        fields["source"] = source
        // Persist only a bounded, secret-redacted diagnostic preview. The live
        // transcript remains in the active session UI; disk logs do not need a
        // complete copy of every voice/agent conversation.
        fields["textPreview"] = Self.truncated(
            trimmedText,
            maxLength: Self.maximumConversationPreviewLength
        )
        fields["textLength"] = trimmedText.count
        if let sessionID, !sessionID.isEmpty {
            fields["sessionID"] = sessionID
        }
        if let title, !title.isEmpty {
            fields["title"] = Self.truncated(title, maxLength: 240)
        }

        append(
            lane: lane,
            direction: direction,
            event: "openclicky.conversation.turn",
            fields: fields
        )
    }

    private func append(_ data: Data, to fileURL: URL) throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try writePrivateFile(data, to: fileURL)
        }
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }

    private func ensureEmptyJSONLReviewCommentsFileExists() throws {
        guard !fileManager.fileExists(atPath: reviewCommentsFile.path) else { return }
        try writePrivateFile(Data(), to: reviewCommentsFile)
    }

    private func ensureLogDirectoryExists() throws {
        try fileManager.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: logDirectory.path)
    }

    private func writePrivateFile(_ data: Data, to fileURL: URL) throws {
        try data.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }

    private static func defaultLogDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    private func pruneReviewCommentsLocked(olderThan cutoff: Date) {
        guard fileManager.fileExists(atPath: reviewCommentsFile.path) else { return }
        guard let contents = try? String(contentsOf: reviewCommentsFile, encoding: .utf8) else { return }
        let existingMarkdown = try? String(contentsOf: agentReviewCommentsFile, encoding: .utf8)

        let dateFormatter = ISO8601DateFormatter()
        let retainedEntries: [[String: Any]] = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let createdAt = entry["createdAt"] as? String,
                      let date = dateFormatter.date(from: createdAt),
                      date >= cutoff else {
                    return nil
                }
                return Self.privacySanitizedReviewEntry(entry)
            }

        do {
            let jsonl = retainedEntries.compactMap { entry -> String? in
                guard JSONSerialization.isValidJSONObject(entry),
                      let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                      let line = String(data: data, encoding: .utf8) else {
                    return nil
                }
                return line
            }.joined(separator: "\n")
            let jsonlData = Data((jsonl.isEmpty ? "" : jsonl + "\n").utf8)
            try writePrivateFile(jsonlData, to: reviewCommentsFile)

            let markdown = retainedReviewMarkdown(
                existing: existingMarkdown,
                cutoff: cutoff,
                fallbackEntries: retainedEntries
            )
            try writePrivateFile(Data(markdown.utf8), to: agentReviewCommentsFile)
        } catch {
            print("OpenClicky review comment prune failed: \(error.localizedDescription)")
        }
    }

    private func retainedReviewMarkdown(
        existing: String?,
        cutoff: Date,
        fallbackEntries: [[String: Any]]
    ) -> String {
        let header = """
        # OpenClicky Log Review Comments

        Review comments retain diagnostic metadata and a privacy-filtered source excerpt. They expire automatically; use the live log viewer for current context.
        """
        guard let existing, existing.contains("## ") else {
            return header + fallbackEntries.map(Self.markdownReviewEntry).joined()
        }

        let formatter = ISO8601DateFormatter()
        let sections = existing.components(separatedBy: "\n## ")
        let preserved = sections.dropFirst().compactMap { section -> String? in
            let heading = section.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let dateText = heading.split(separator: " ").first.map(String.init)
            guard let dateText, let date = formatter.date(from: dateText) else {
                // Keep hand-authored sections whose heading is not a generated
                // ISO timestamp; pruning must not discard manual review notes.
                return "\n## " + section
            }
            return date >= cutoff ? "\n## " + section : nil
        }.joined()
        return header + preserved
    }

    private static func privacySanitizedReviewEntry(_ entry: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for (key, value) in entry {
            switch key {
            case "rawEntry":
                sanitized["sourceExcerpt"] = redactedReviewExcerpt(value as? String ?? "")
            case "sourceExcerpt":
                sanitized[key] = redactedReviewExcerpt(value as? String ?? "")
            case "sourceLogFile":
                let sourcePath = value as? String ?? ""
                sanitized[key] = URL(fileURLWithPath: sourcePath).lastPathComponent
            case "comment":
                sanitized[key] = truncated(value as? String ?? "", maxLength: maximumReviewCommentLength)
            default:
                sanitized[key] = sanitizedJSONObject(value, key: key)
            }
        }
        return sanitized
    }

    private static func markdownReviewEntry(from entry: [String: Any]) -> String {
        let createdAt = entry["createdAt"] as? String ?? "Unknown date"
        let event = entry["event"] as? String ?? "unknown"
        let source = entry["sourceLogFile"] as? String ?? "unknown"
        let line = entry["sourceLineNumber"] as? Int ?? 0
        let timestamp = entry["entryTimestamp"] as? String ?? ""
        let lane = entry["lane"] as? String ?? ""
        let direction = entry["direction"] as? String ?? ""
        let status = entry["status"] as? String ?? "open"
        let fixedBy = entry["fixedBy"] as? String ?? ""
        let verifiedAt = entry["verifiedAt"] as? String ?? ""
        let comment = entry["comment"] as? String ?? ""
        let sourceExcerpt = (entry["sourceExcerpt"] as? String ?? "No retained source excerpt.")
            .replacingOccurrences(of: "```", with: "'''")

        return """

        ## \(createdAt) - \(event)

        - Source: \(source):\(line)
        - Entry timestamp: \(timestamp)
        - Lane: \(lane)
        - Direction: \(direction)
        - Status: \(status)
        - Fixed by: \(fixedBy)
        - Verified at: \(verifiedAt)

        Comment:
        \(comment)

        Source excerpt (privacy filtered):
        ```json
        \(sourceExcerpt)
        ```
        """
    }

    private static func redactedReviewExcerpt(_ rawEntry: String) -> String {
        guard let data = rawEntry.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return "[unstructured source entry omitted for privacy]"
        }
        let sanitized = reviewContextValue(object)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[source entry omitted for privacy]"
        }
        return truncated(text, maxLength: maximumReviewSourceExcerptLength)
    }

    private static func reviewContextValue(_ value: Any, key: String? = nil) -> Any {
        if let key, isSensitiveKey(key) || isPrivateContentKey(key) {
            return "[redacted]"
        }
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { childKey, childValue in
                (childKey, reviewContextValue(childValue, key: childKey))
            })
        }
        if let array = value as? [Any] {
            return array.map { reviewContextValue($0) }
        }
        if let string = value as? String {
            return truncated(string, maxLength: 320)
        }
        return sanitizedJSONObject(value, key: key)
    }

    private static func sanitizedJSONObject(_ value: Any, key: String? = nil) -> Any {
        if let key, isSensitiveKey(key) || isPrivateContentKey(key) {
            return "[redacted]"
        }

        if let dictionary = value as? [String: Any] {
            var sanitized: [String: Any] = [:]
            for (childKey, childValue) in dictionary {
                sanitized[childKey] = sanitizedJSONObject(childValue, key: childKey)
            }
            return sanitized
        }

        if let array = value as? [Any] {
            return array.map { sanitizedJSONObject($0) }
        }

        if let string = value as? String {
            return truncated(string)
        }

        if let number = value as? NSNumber {
            return number
        }

        if let url = value as? URL {
            return url.path
        }

        if let date = value as? Date {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            return isoFormatter.string(from: date)
        }

        if let data = value as? Data {
            return [
                "type": "data",
                "bytes": data.count
            ]
        }

        return truncated(String(describing: value))
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        return lowered.contains("api_key")
            || lowered.contains("apikey")
            || lowered.contains("authorization")
            || lowered.contains("password")
            || lowered.contains("secret")
            || lowered.contains("token")
            || lowered == "x-api-key"
    }

    private static func isPrivateContentKey(_ key: String) -> Bool {
        let lowered = key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        return ["text", "content", "message", "prompt", "transcript", "response", "rawentry", "raw_entry"].contains(lowered)
            || lowered.contains("screenshot")
            || lowered.contains("imagebase64")
    }

    private static let sensitiveValuePatterns = [
        #"sk-ant-[A-Za-z0-9_\-]{20,}"#,
        #"sk-proj-[A-Za-z0-9_\-]{20,}"#,
        #"\bsk-[A-Za-z0-9_\-]{20,}"#,
        #"\bgh[pousr]_[A-Za-z0-9_]{20,}"#,
        #"\bAIza[0-9A-Za-z_\-]{20,}"#,
        #"\b[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\b"#,
        #"(?i)bearer\s+[A-Za-z0-9._\-=]{20,}"#,
        #"(?i)\b(openai_api_key|anthropic_api_key|elevenlabs_api_key|api[_-]?key|token|secret|password)\s*[:=]\s*['\"]?[^'\"\s,}]{8,}"#
    ]

    private static func truncated(_ string: String, maxLength: Int = 12_000) -> String {
        let redactedString = redactedSensitiveValues(in: string)
        guard redactedString.count > maxLength else { return redactedString }
        let endIndex = redactedString.index(redactedString.startIndex, offsetBy: maxLength)
        return "\(redactedString[..<endIndex])... [truncated \(redactedString.count - maxLength) chars]"
    }

    private static func redactedSensitiveValues(in string: String) -> String {
        var redacted = string
        for pattern in sensitiveValuePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = regex.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: "[redacted]")
        }
        return redacted
    }

    private func emitConsoleLog(entry: [String: Any]) {
        guard let timestamp = entry["timestamp"] as? String,
              let lane = entry["lane"] as? String,
              let direction = entry["direction"] as? String,
              let event = entry["event"] as? String else {
            return
        }

        let fields = (entry["fields"] as? [String: Any]) ?? [:]
        let previewText: String
        if fields.isEmpty {
            previewText = "{}"
        } else if let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  let text = String(data: json, encoding: .utf8) {
            previewText = Self.truncated(text, maxLength: 420)
        } else {
            previewText = Self.truncated(String(describing: fields), maxLength: 420)
        }

        NSLog("[OpenClickyLog][%@][%@/%@] %@ %@", timestamp, lane, direction, event, previewText)
    }
}
