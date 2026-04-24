import Foundation

final class OpenClickyMessageLogStore: @unchecked Sendable {
    static let shared = OpenClickyMessageLogStore()

    private let fileManager: FileManager
    private let lock = NSLock()

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
            guard !fileManager.fileExists(atPath: agentReviewCommentsFile.path) else { return }
            let header = """
            # OpenClicky Log Review Comments

            Agents should read this file when the user asks to fix issues flagged from message logs. Each entry includes the source log file, source line, user comment, and raw JSONL entry.
            """
            try Data(header.utf8).write(to: agentReviewCommentsFile, options: [.atomic])
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
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)

            let entry: [String: Any] = [
                "timestamp": isoFormatter.string(from: Date()),
                "lane": lane,
                "direction": direction,
                "event": event,
                "fields": Self.sanitizedJSONObject(fields)
            ]

            guard JSONSerialization.isValidJSONObject(entry) else { return }
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)

            try append(data, to: currentLogFile)
        } catch {
            print("OpenClicky message log write failed: \(error.localizedDescription)")
        }
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

    private static func truncated(_ string: String, maxLength: Int = 12_000) -> String {
        guard string.count > maxLength else { return string }
        let endIndex = string.index(string.startIndex, offsetBy: maxLength)
        return "\(string[..<endIndex])... [truncated \(string.count - maxLength) chars]"
    }
}
