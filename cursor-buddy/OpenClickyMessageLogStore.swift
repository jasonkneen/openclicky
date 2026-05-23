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

    func availableMessageLogFiles() -> [URL] {
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
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
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: agentReviewCommentsFile.path) {
                let header = """
                # OpenClicky Log Review Comments

                Agents should read this file when the user asks to fix issues flagged from message logs. Each entry includes the source log file, source line, user comment, and raw JSONL entry.
                """
                try Data(header.utf8).write(to: agentReviewCommentsFile, options: [.atomic])
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
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedComment.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: agentReviewCommentsFile.path) {
                let header = """
                # OpenClicky Log Review Comments

                Agents should read this file when the user asks to fix issues flagged from message logs. Each entry includes the source log file, source line, user comment, and raw JSONL entry.
                """
                try Data(header.utf8).write(to: agentReviewCommentsFile, options: [.atomic])
            }
            try ensureEmptyJSONLReviewCommentsFileExists()

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            let createdAt = isoFormatter.string(from: Date())

            let entry: [String: Any] = [
                "id": UUID().uuidString,
                "createdAt": createdAt,
                "sourceLogFile": sourceLogFile.path,
                "sourceLineNumber": sourceLineNumber,
                "entryID": entryID,
                "entryTimestamp": entryTimestamp,
                "lane": lane,
                "direction": direction,
                "event": event,
                "comment": trimmedComment,
                "rawEntry": Self.truncated(rawEntry, maxLength: 20_000)
            ]

            guard JSONSerialization.isValidJSONObject(entry) else { return }
            var jsonlData = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            jsonlData.append(0x0A)
            try append(jsonlData, to: reviewCommentsFile)

            let markdownEntry = """

            ## \(createdAt) - \(event)

            - Source: \(sourceLogFile.lastPathComponent):\(sourceLineNumber)
            - Entry timestamp: \(entryTimestamp)
            - Lane: \(lane)
            - Direction: \(direction)

            Comment:
            \(trimmedComment)

            Raw entry:
            ```json
            \(Self.truncated(rawEntry, maxLength: 8_000))
            ```
            """
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
                try self.fileManager.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)

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
        fields["text"] = trimmedText
        fields["textLength"] = trimmedText.count
        if let sessionID, !sessionID.isEmpty {
            fields["sessionID"] = sessionID
        }
        if let title, !title.isEmpty {
            fields["title"] = title
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
            try data.write(to: fileURL, options: [.atomic])
        }
    }

    private func ensureEmptyJSONLReviewCommentsFileExists() throws {
        guard !fileManager.fileExists(atPath: reviewCommentsFile.path) else { return }
        try Data().write(to: reviewCommentsFile, options: [.atomic])
    }

    private static func defaultLogDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    private static func sanitizedJSONObject(_ value: Any, key: String? = nil) -> Any {
        if let key, isSensitiveKey(key) {
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
