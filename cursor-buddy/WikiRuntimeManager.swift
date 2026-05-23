//
//  WikiRuntimeManager.swift
//  OpenClicky Wiki Runtime
//
//  Implements the full three-layer wiki from the `save` skill spec:
//  - raw/      : immutable source snapshots + sources.jsonl log
//  - wiki/     : compiled knowledge base with articles, index, backlinks
//

import Foundation

/// Runtime manager for the OpenClicky personal knowledge wiki.
///
/// The wiki lives at `~/Library/Application Support/OpenClicky/wiki/` and follows
/// the LLM Wiki pattern: raw sources are immutable receipts, while wiki articles
/// are alive — constantly revised, interlinked, and compounded with every ingest.
@MainActor
final class WikiRuntimeManager {

    // MARK: - Paths

    private let fileManager: FileManager
    let wikiRoot: URL

    var rawDirectory: URL { wikiRoot.appendingPathComponent("raw", isDirectory: true) }
    var wikiDirectory: URL { wikiRoot.appendingPathComponent("wiki", isDirectory: true) }
    var mediaDirectory: URL { wikiDirectory.appendingPathComponent("media", isDirectory: true) }
    var sourcesLogFile: URL { rawDirectory.appendingPathComponent("sources.jsonl", isDirectory: false) }
    var indexFile: URL { wikiDirectory.appendingPathComponent("_index.md", isDirectory: false) }
    var backlinksFile: URL { wikiDirectory.appendingPathComponent("_backlinks.json", isDirectory: false) }

    // MARK: - Init

    init(
        wikiRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.wikiRoot = wikiRoot ?? WikiRuntimeManager.defaultWikiRoot(fileManager: fileManager)
    }

    static func defaultWikiRoot(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("wiki", isDirectory: true)
    }

    // MARK: - Bootstrap

    /// Ensures the full wiki directory structure exists. Safe to call repeatedly.
    func bootstrap() throws {
        try fileManager.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: wikiDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: indexFile.path) {
            let initialIndex = "# Wiki Index\n\nArticles listed with aliases for matching.\n"
            try initialIndex.write(to: indexFile, atomically: true, encoding: .utf8)
        }

        if !fileManager.fileExists(atPath: backlinksFile.path) {
            try Data("{}".utf8).write(to: backlinksFile)
        }

        if !fileManager.fileExists(atPath: sourcesLogFile.path) {
            try Data().write(to: sourcesLogFile)
        }
    }

    // MARK: - Ingest

    /// Logs a raw source to sources.jsonl and returns the assigned source ID.
    @discardableResult
    func ingestSource(
        type: String,
        summary: String,
        articlesTouched: [String],
        data: Data? = nil,
        originalURL: URL? = nil
    ) throws -> String {
        try bootstrap()

        let sourceID = nextSourceID()
        let date = isoDate()

        let entry = SourceLogEntry(
            id: sourceID,
            date: date,
            type: type,
            summary: summary,
            articlesTouched: articlesTouched
        )

        let line = try entry.jsonLine()
        let lineData = (line + "\n").data(using: .utf8)!

        if let fileHandle = try? FileHandle(forWritingTo: sourcesLogFile) {
            defer { try? fileHandle.close() }
            _ = try? fileHandle.seekToEnd()
            try? fileHandle.write(contentsOf: lineData)
        } else {
            try lineData.write(to: sourcesLogFile)
        }

        // Save raw snapshot if data provided
        if let data {
            let ext = originalURL?.pathExtension ?? "bin"
            let snapshotURL = rawDirectory.appendingPathComponent("\(sourceID).\(ext)", isDirectory: false)
            try data.write(to: snapshotURL)
        }

        return sourceID
    }

    // MARK: - Articles

    /// Writes or updates a wiki article. Creates parent directories as needed.
    func writeArticle(
        relativePath: String,
        title: String,
        type: String,
        body: String,
        related: [String] = [],
        sourceCount: Int = 1
    ) throws {
        try bootstrap()

        let articleURL = try safeArticleURL(for: relativePath)
        try fileManager.createDirectory(at: articleURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let date = isoDate()
        let existing = try? readArticle(relativePath: relativePath)
        let created = existing?.created ?? date
        let mergedSourceCount = existing.map { $0.sourceCount + sourceCount } ?? sourceCount

        let frontmatter = [
            "title: \"\(escapeFrontmatter(title))\"",
            "type: \"\(escapeFrontmatter(type))\"",
            "created: \(created)",
            "last_updated: \(date)",
            "source_count: \(mergedSourceCount)",
            related.isEmpty ? nil : "related: [\(related.map { "\"\(escapeFrontmatter($0))\"" }.joined(separator: ", "))]",
        ].compactMap { $0 }.joined(separator: "\n")

        let markdown = """
        ---
        \(frontmatter)
        ---

        # \(title)

        \(body)
        """

        try markdown.write(to: articleURL, atomically: true, encoding: .utf8)
    }

    /// Reads an article by its relative path (e.g. `people/paul-graham.md`).
    func readArticle(relativePath: String) throws -> WikiArticle {
        let articleURL = try safeArticleURL(for: relativePath)
        let body = try String(contentsOf: articleURL, encoding: .utf8)
        let frontmatter = parseFrontmatter(body)

        return WikiArticle(
            relativePath: relativePath,
            title: frontmatter["title"] ?? titleFromPath(relativePath),
            type: frontmatter["type"] ?? "entity",
            created: frontmatter["created"] ?? "",
            lastUpdated: frontmatter["last_updated"] ?? "",
            sourceCount: Int(frontmatter["source_count"] ?? "") ?? 1,
            related: parseRelated(frontmatter["related"]),
            body: body
        )
    }

    /// Returns all article relative paths found in the wiki directory.
    func allArticlePaths() -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: wikiDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "md",
                  url.lastPathComponent != "_index.md" else { return nil }
            let fullPath = url.standardizedFileURL.path
            let rootPath = wikiDirectory.standardizedFileURL.path
            guard fullPath.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
            return String(fullPath.dropFirst(rootPath.count + 1))
        }
        .sorted()
    }

    /// Returns an article whose title or aliases match the query.
    func findArticle(matching query: String) -> WikiArticle? {
        let index = loadIndex()
        guard let match = index.entries.first(where: {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
        }) else { return nil }
        return try? readArticle(relativePath: match.relativePath)
    }

    // MARK: - Index

    /// Loads the current index entries from `_index.md`.
    func loadIndex() -> WikiIndex {
        guard let content = try? String(contentsOf: indexFile, encoding: .utf8) else {
            return WikiIndex(entries: [])
        }
        return WikiIndexParser.parse(content)
    }

    /// Replaces `_index.md` with the provided entries, preserving the header.
    func saveIndex(_ index: WikiIndex) throws {
        try bootstrap()

        var lines = ["# Wiki Index", "", "Articles listed with aliases for matching.", ""]
        for entry in index.entries.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
            lines.append("- **\\[\\[\(entry.title)\\]\\]** (\(entry.relativePath)) — \(entry.summary)")
            if !entry.aliases.isEmpty {
                lines.append("  also: \(entry.aliases.joined(separator: ", "))")
            }
            lines.append("")
        }

        try lines.joined(separator: "\n").write(to: indexFile, atomically: true, encoding: .utf8)
    }

    /// Adds or updates a single entry in the index.
    func upsertIndexEntry(title: String, relativePath: String, summary: String, aliases: [String]) throws {
        var index = loadIndex()
        if let existingIndex = index.entries.firstIndex(where: { $0.title == title }) {
            index.entries[existingIndex] = WikiIndexEntry(
                title: title,
                relativePath: relativePath,
                summary: summary,
                aliases: aliases
            )
        } else {
            index.entries.append(WikiIndexEntry(
                title: title,
                relativePath: relativePath,
                summary: summary,
                aliases: aliases
            ))
        }
        try saveIndex(index)
    }

    // MARK: - Backlinks

    /// Loads the current backlink map.
    func loadBacklinks() -> [String: [String]] {
        guard let data = try? Data(contentsOf: backlinksFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return [:]
        }
        return json
    }

    /// Saves the backlink map to `_backlinks.json`.
    func saveBacklinks(_ backlinks: [String: [String]]) throws {
        try bootstrap()
        let data = try JSONSerialization.data(withJSONObject: backlinks, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: backlinksFile)
    }

    /// Rebuilds the entire backlink map by scanning all articles for `[[Title]]` wikilinks.
    func rebuildBacklinks() throws {
        var backlinks: [String: [String]] = [:]

        for path in allArticlePaths() {
            guard let article = try? readArticle(relativePath: path) else { continue }
            let links = extractWikilinks(from: article.body)
            for target in links {
                backlinks[target, default: []].append(article.title)
            }
        }

        // Deduplicate and sort
        let cleaned = backlinks.mapValues { Array(Set($0)).sorted() }
        try saveBacklinks(cleaned)
    }

    // MARK: - Media

    /// Copies image data into `wiki/media/` and returns the relative path for embedding.
    func saveMedia(data: Data, filename: String) throws -> String {
        try bootstrap()
        let destination = mediaDirectory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: destination)
        return "media/\(filename)"
    }

    // MARK: - Helpers

    /// Generates a slug suitable for filenames: lowercase, hyphenated.
    static func slug(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let lowered = folded.lowercased()
        let pieces = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return pieces.isEmpty ? "article" : pieces.joined(separator: "-")
    }

    /// Suggests a directory for an article based on its type.
    static func directoryForType(_ type: String) -> String {
        switch type.lowercased() {
        case "person", "people": return "people"
        case "project", "projects", "company", "product", "tool": return "projects"
        case "concept", "concepts", "philosophy", "pattern", "theme": return "concepts"
        case "reference", "references", "article", "paper", "talk", "tweet": return "references"
        case "idea", "ideas", "hypothesis": return "ideas"
        default: return "concepts"
        }
    }

    // MARK: - Private

    private func nextSourceID() -> String {
        let date = isoDate()
        let count = (try? String(contentsOf: sourcesLogFile, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .count ?? 0
        return "\(date)-\(String(format: "%03d", count + 1))"
    }

    private func isoDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func safeArticleURL(for relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\") else {
            throw wikiPathError("Wiki article paths must be relative paths inside the wiki directory.")
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  let value = String(component)
                  return !value.isEmpty && value != "." && value != ".."
              }) else {
            throw wikiPathError("Wiki article path contains an unsafe path component.")
        }

        guard (trimmed as NSString).pathExtension.lowercased() == "md" else {
            throw wikiPathError("Wiki article paths must end in .md.")
        }

        let rootURL = wikiDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidateURL = rootURL.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL.resolvingSymlinksInPath()
        guard candidateURL.path.hasPrefix(rootURL.path + "/") else {
            throw wikiPathError("Wiki article path escapes the wiki directory.")
        }
        return candidateURL
    }

    private func wikiPathError(_ message: String) -> NSError {
        NSError(domain: "OpenClicky.WikiRuntimeManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func titleFromPath(_ relativePath: String) -> String {
        relativePath.deletingPathExtension()
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private func escapeFrontmatter(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func parseFrontmatter(_ body: String) -> [String: String] {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func parseRelated(_ value: String?) -> [String] {
        guard let value else { return [] }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("[") && cleaned.hasSuffix("]") else { return [] }
        let inner = cleaned.dropFirst().dropLast()
        return inner.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
    }

    private func extractWikilinks(from body: String) -> [String] {
        let pattern = #"\[\[([^\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        return matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: body) else { return nil }
            return String(body[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Data Models

struct WikiArticle: Equatable {
    var relativePath: String
    var title: String
    var type: String
    var created: String
    var lastUpdated: String
    var sourceCount: Int
    var related: [String]
    var body: String
}

struct WikiIndexEntry: Equatable {
    var title: String
    var relativePath: String
    var summary: String
    var aliases: [String]
}

struct WikiIndex: Equatable {
    var entries: [WikiIndexEntry]
}

struct SourceLogEntry: Codable {
    var id: String
    var date: String
    var type: String
    var summary: String
    var articlesTouched: [String]

    func jsonLine() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }
}

// MARK: - Index Parser

enum WikiIndexParser {
    static func parse(_ content: String) -> WikiIndex {
        var entries: [WikiIndexEntry] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Match: - **[[Title]] (path) — summary
            if let match = parseEntryLine(line) {
                var aliases: [String] = []
                // Check next line for aliases
                if i + 1 < lines.count {
                    let nextLine = lines[i + 1]
                    if nextLine.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("also:") {
                        let aliasPart = nextLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
                        aliases = aliasPart.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        }.filter { !$0.isEmpty }
                        i += 1
                    }
                }
                entries.append(WikiIndexEntry(
                    title: match.title,
                    relativePath: match.relativePath,
                    summary: match.summary,
                    aliases: aliases
                ))
            }
            i += 1
        }

        return WikiIndex(entries: entries)
    }

    private static func parseEntryLine(_ line: String) -> (title: String, relativePath: String, summary: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- **[[") else { return nil }

        // Extract title between [[ and ]]
        guard let titleStart = trimmed.range(of: "[[")?.upperBound,
              let titleEnd = trimmed[titleStart...].range(of: "]]")?.lowerBound else { return nil }
        let title = String(trimmed[titleStart..<titleEnd])

        // Extract path between ( and )
        let afterTitle = trimmed[titleEnd...]
        guard let pathStart = afterTitle.range(of: "(")?.upperBound,
              let pathEnd = afterTitle[pathStart...].range(of: ")")?.lowerBound else { return nil }
        let relativePath = String(afterTitle[pathStart..<pathEnd]).trimmingCharacters(in: .whitespaces)

        // Extract summary after —
        let afterPath = afterTitle[pathEnd...]
        let summary: String
        if let dashRange = afterPath.range(of: "—") {
            summary = String(afterPath[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            summary = ""
        }

        return (title, relativePath, summary)
    }
}

// MARK: - String Helpers

private extension String {
    func deletingPathExtension() -> String {
        (self as NSString).deletingPathExtension
    }
}
