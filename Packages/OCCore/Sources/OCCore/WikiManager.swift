import Foundation

public enum WikiManager {
    public struct Article: Identifiable, Equatable {
        public var id: String { relativePath }
        public var relativePath: String
        public var title: String
        public var body: String
        public var aliases: [String]

        public init(relativePath: String, title: String, body: String, aliases: [String]) {
            self.relativePath = relativePath
            self.title = title
            self.body = body
            self.aliases = aliases
        }
    }

    public struct Skill: Identifiable, Equatable {
        public var id: String { identifier }
        public var identifier: String
        public var title: String
        public var summary: String
        public var body: String

        public init(identifier: String, title: String, summary: String, body: String) {
            self.identifier = identifier
            self.title = title
            self.summary = summary
            self.body = body
        }
    }

    public struct Index: Equatable {
        public var articles: [Article]
        public var skills: [Skill]

        public static let empty = Index(articles: [], skills: [])

        public init(articles: [Article], skills: [Skill]) {
            self.articles = articles
            self.skills = skills
        }

        public static func loadForAppBundle(
            bundle: Bundle = .main,
            sourceResourcesURL: URL? = nil,
            fileManager: FileManager = .default
        ) -> Index {
            do {
                if let resourcesRoot = bundle.resourceURL {
                    let wikiRoot = resourcesRoot.appendingPathComponent("OpenClickyBundledWikiSeed", isDirectory: true)
                    if fileManager.fileExists(atPath: wikiRoot.path) {
                        return try load(fromBundledResourcesRoot: resourcesRoot, fileManager: fileManager)
                    }
                }
                if let sourceResources = sourceResourcesURL {
                    return try load(fromBundledResourcesRoot: sourceResources, fileManager: fileManager)
                }
            } catch {
                print("⚠️ OpenClicky wiki index load failed: \(error)")
            }
            return .empty
        }

        public static func load(fromBundledResourcesRoot resourcesRoot: URL, fileManager: FileManager = .default) throws -> Index {
            let wikiRoot = resourcesRoot.appendingPathComponent("OpenClickyBundledWikiSeed", isDirectory: true)
            let skillsRoot = resourcesRoot.appendingPathComponent("OpenClickyBundledSkills", isDirectory: true)

            return try load(
                articleRoots: [wikiRoot],
                skillRoots: [skillsRoot],
                fileManager: fileManager
            )
        }

        public static func load(articleRoots: [URL], skillRoots: [URL], fileManager: FileManager = .default) throws -> Index {
            let articles = try articleRoots.flatMap { try loadArticles(root: $0, fileManager: fileManager) }
            let skills = try skillRoots.flatMap { try loadSkills(root: $0, fileManager: fileManager) }
            return Index(articles: articles, skills: skills)
        }

        public func combined(with other: Index) -> Index {
            let mergedArticles = Dictionary(grouping: articles + other.articles, by: \.id)
                .compactMap { $0.value.last }
                .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            let mergedSkills = Dictionary(grouping: skills + other.skills, by: \.id)
                .compactMap { $0.value.last }
                .sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
            return Index(articles: mergedArticles, skills: mergedSkills)
        }

        public func article(containingTitle query: String) -> Article? {
            articles.first { article in
                article.title.localizedCaseInsensitiveContains(query)
                    || article.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }

        private static func loadArticles(root: URL, fileManager: FileManager) throws -> [Article] {
            guard fileManager.fileExists(atPath: root.path) else { return [] }
            let markdownFiles = markdownFiles(under: root, fileManager: fileManager)
            return try markdownFiles.map { url in
                let body = try String(contentsOf: url, encoding: .utf8)
                let relativePath = relativePath(from: root, to: url)
                let aliases = extractAliases(from: body)
                return Article(
                    relativePath: relativePath,
                    title: articleTitle(for: url, body: body),
                    body: body,
                    aliases: aliases
                )
            }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        }

        private static func loadSkills(root: URL, fileManager: FileManager) throws -> [Skill] {
            guard fileManager.fileExists(atPath: root.path) else { return [] }
            let skillFiles = markdownFiles(under: root, fileManager: fileManager)
                .filter { $0.lastPathComponent == "SKILL.md" }
            return try skillFiles.map { url in
                let body = try String(contentsOf: url, encoding: .utf8)
                let frontmatter = parseFrontmatter(body)
                let identifier = url.deletingLastPathComponent().lastPathComponent
                let title = frontmatter["name"] ?? headingTitle(from: body) ?? identifier
                let summary = frontmatter["description"] ?? firstNonMetadataParagraph(from: body)
                return Skill(identifier: identifier, title: title, summary: summary, body: body)
            }
            .sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
        }

        private static func markdownFiles(under root: URL, fileManager: FileManager) -> [URL] {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL, url.pathExtension.lowercased() == "md" else { return nil }
                return url
            }
        }

        private static func relativePath(from root: URL, to file: URL) -> String {
            let rootPath = root.standardizedFileURL.path
            let filePath = file.standardizedFileURL.path
            let trimmed = filePath.hasPrefix(rootPath + "/") ? String(filePath.dropFirst(rootPath.count + 1)) : file.lastPathComponent
            return trimmed
        }

        private static func articleTitle(for url: URL, body: String) -> String {
            if url.lastPathComponent == "_index.md" {
                return "Index"
            }
            if let frontmatterTitle = parseFrontmatter(body)["title"] {
                return frontmatterTitle
            }
            return headingTitle(from: body)
                ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized
        }

        private static func headingTitle(from body: String) -> String? {
            body.split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("# ") else { return nil }
                    return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .first
        }

        private static func extractAliases(from body: String) -> [String] {
            body.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.localizedCaseInsensitiveContains("also:") }
                .flatMap { line -> [String] in
                    guard let range = line.range(of: "also:", options: .caseInsensitive) else { return [] }
                    return line[range.upperBound...]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
        }

        private static func parseFrontmatter(_ body: String) -> [String: String] {
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.first == "---" else { return [:] }
            var result: [String: String] = [:]
            for line in lines.dropFirst() {
                if line == "---" { break }
                guard let separator = line.firstIndex(of: ":") else { continue }
                let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !key.isEmpty, !value.isEmpty {
                    result[key] = value
                }
            }
            return result
        }

        private static func firstNonMetadataParagraph(from body: String) -> String {
            var insideFrontmatter = false
            for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "---" {
                    insideFrontmatter.toggle()
                    continue
                }
                guard !insideFrontmatter, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                return trimmed
            }
            return ""
        }
    }
}

public struct WikiViewerEntry: Identifiable, Equatable {
    public enum Kind: String, Equatable {
        case article
        case skill

        public var label: String {
            switch self {
            case .article: return "Article"
            case .skill: return "Skill"
            }
        }
    }

    public let id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var body: String
    public var relativePath: String

    public init(article: WikiManager.Article) {
        self.id = "article:\(article.id)"
        self.kind = .article
        self.title = article.title
        self.subtitle = article.relativePath
        self.body = article.body
        self.relativePath = article.relativePath
    }

    public init(skill: WikiManager.Skill) {
        self.id = "skill:\(skill.id)"
        self.kind = .skill
        self.title = skill.title
        self.subtitle = skill.identifier
        self.body = skill.body
        self.relativePath = "skills/\(skill.identifier)/SKILL.md"
    }

    public var searchableText: String {
        [title, subtitle, body].joined(separator: " ")
    }
}

extension WikiManager.Index {
    @MainActor
    public var viewerEntries: [WikiViewerEntry] {
        let articleEntries = articles.map(WikiViewerEntry.init(article:))
        let skillEntries = skills.map(WikiViewerEntry.init(skill:))
        return (articleEntries + skillEntries)
            .sorted { leftEntry, rightEntry in
                leftEntry.title.localizedStandardCompare(rightEntry.title) == .orderedAscending
            }
    }
}
