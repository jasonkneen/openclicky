import Combine
import CoreGraphics
import Foundation

enum WikiManager {
    struct Article: Identifiable, Equatable {
        var id: String { relativePath }
        var relativePath: String
        var title: String
        var body: String
        var aliases: [String]
    }

    struct Skill: Identifiable, Equatable {
        var id: String { identifier }
        var identifier: String
        var title: String
        var summary: String
        var body: String
    }

    struct Index: Equatable {
        var articles: [Article]
        var skills: [Skill]

        static let empty = Index(articles: [], skills: [])

        static func loadForAppBundle(bundle: Bundle = .main, fileManager: FileManager = .default) -> Index {
            do {
                if let resourcesRoot = bundle.resourceURL {
                    return try load(fromBundledResourcesRoot: resourcesRoot, fileManager: fileManager)
                }
                if let sourceResources = CodexRuntimeLocator.sourceAppResourcesDirectory(fileManager: fileManager) {
                    return try load(fromBundledResourcesRoot: sourceResources, fileManager: fileManager)
                }
            } catch {
                print("⚠️ OpenClicky wiki index load failed: \(error)")
            }
            return .empty
        }

        static func load(fromBundledResourcesRoot resourcesRoot: URL, fileManager: FileManager = .default) throws -> Index {
            let wikiRoot = resourcesRoot.appendingPathComponent("OpenClickyBundledWikiSeed", isDirectory: true)
            let skillsRoot = resourcesRoot.appendingPathComponent("OpenClickyBundledSkills", isDirectory: true)

            return try load(
                articleRoots: [wikiRoot],
                skillRoots: [skillsRoot],
                fileManager: fileManager
            )
        }

        static func load(articleRoots: [URL], skillRoots: [URL], fileManager: FileManager = .default) throws -> Index {
            let articles = try articleRoots.flatMap { try loadArticles(root: $0, fileManager: fileManager) }
            let skills = try skillRoots.flatMap { try loadSkills(root: $0, fileManager: fileManager) }
            return Index(articles: articles, skills: skills)
        }

        func combined(with other: Index) -> Index {
            let mergedArticles = Dictionary(grouping: articles + other.articles, by: \.id)
                .compactMap { $0.value.last }
                .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            let mergedSkills = Dictionary(grouping: skills + other.skills, by: \.id)
                .compactMap { $0.value.last }
                .sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
            return Index(articles: mergedArticles, skills: mergedSkills)
        }

        func article(containingTitle query: String) -> Article? {
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

enum PermissionStatus: Equatable {
    case missing
    case granted
}

struct PermissionSnapshot: Equatable {
    var accessibility: PermissionStatus
    var screenRecording: PermissionStatus
    var microphone: PermissionStatus
    var screenContent: PermissionStatus
}

enum PermissionGuideAssistant {
    enum EntryContext: Equatable {
        case panel
        case onboarding
        case returningUser
    }

    enum StepKind: String, Equatable, CaseIterable {
        case accessibility
        case screenRecording
        case microphone
        case screenContent

        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .microphone: return "Microphone"
            case .screenContent: return "Screen Content"
            }
        }

        var systemImageName: String {
            switch self {
            case .accessibility: return "hand.raised"
            case .screenRecording: return "rectangle.dashed.badge.record"
            case .microphone: return "mic"
            case .screenContent: return "eye"
            }
        }

        var settingsURL: URL {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .screenContent:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }

        var detail: String {
            switch self {
            case .accessibility:
                return "Lets OpenClicky follow the cursor and respond to the global hotkey."
            case .screenRecording:
                return "Lets OpenClicky capture a screenshot only when you ask for help."
            case .microphone:
                return "Lets OpenClicky hear your push-to-talk request."
            case .screenContent:
                return "Confirms ScreenCaptureKit can read the selected screen."
            }
        }
    }

    struct Step: Identifiable, Equatable {
        var id: StepKind { kind }
        var kind: StepKind
        var status: PermissionStatus
        var settingsURL: URL { kind.settingsURL }
        var title: String { kind.title }
        var detail: String { kind.detail }
        var systemImageName: String { kind.systemImageName }
    }

    struct ViewState: Equatable {
        var headline: String
        var summary: String
        var steps: [Step]
        var primaryStep: Step?
        var entryContext: EntryContext

        var completedCount: Int {
            steps.filter { $0.status == .granted }.count
        }
    }

    static func viewState(for snapshot: PermissionSnapshot, entryContext: EntryContext) -> ViewState {
        let steps = [
            Step(kind: .accessibility, status: snapshot.accessibility),
            Step(kind: .screenRecording, status: snapshot.screenRecording),
            Step(kind: .microphone, status: snapshot.microphone),
            Step(kind: .screenContent, status: snapshot.screenContent)
        ]
        let primaryStep = steps.first { $0.status == .missing }
        let headline = primaryStep == nil ? "Permissions ready" : "Permissions needed"
        let summary: String
        if let primaryStep {
            summary = "Start with \(primaryStep.title). OpenClicky needs all four checks before voice and Agent Mode can run cleanly."
        } else {
            summary = "OpenClicky can listen, see the active screen when invoked, and hand work to Agent Mode."
        }
        return ViewState(headline: headline, summary: summary, steps: steps, primaryStep: primaryStep, entryContext: entryContext)
    }
}

struct ClickyResponseCard: Identifiable, Equatable {
    enum Source: String, Equatable {
        case voice
        case agent
        case handoff
    }

    static let maximumDisplayCharacters = 220

    let id: String
    var source: Source
    var rawText: String
    var contextTitle: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        source: Source,
        rawText: String,
        contextTitle: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.rawText = rawText
        self.contextTitle = contextTitle
        self.createdAt = createdAt
    }

    var title: String {
        switch source {
        case .voice: return "Voice response"
        case .agent: return "Agent response"
        case .handoff: return "Handoff queued"
        }
    }

    var displayText: String {
        Self.sanitizedDisplayText(from: rawText, maximumCharacters: Self.maximumDisplayCharacters)
    }

    var displayTitle: String {
        let titleSeed = contextTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? contextTitle ?? title
            : title
        return Self.displayTitle(from: titleSeed)
    }

    var completionLabel: String {
        switch source {
        case .handoff:
            return "Queued"
        case .voice, .agent:
            return "Done"
        }
    }

    var suggestedNextActions: [String] {
        Self.suggestedNextActions(from: rawText)
    }

    static func sanitizedDisplayText(from rawText: String, maximumCharacters: Int = maximumDisplayCharacters) -> String {
        var text = rawText
        text = text.replacingOccurrences(of: #"(?s)<NEXT_ACTIONS>.*?</NEXT_ACTIONS>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)```.*?```"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[POINT:[^\]]+\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+.*$"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*_]{3,}\s*$"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[`*_>#]"#, with: "", options: .regularExpression)
        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count > maximumCharacters else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maximumCharacters)
        let prefix = String(text[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func suggestedNextActions(from rawText: String) -> [String] {
        guard
            let blockRange = rawText.range(
                of: #"(?s)<NEXT_ACTIONS>\s*(.*?)\s*</NEXT_ACTIONS>"#,
                options: .regularExpression
            )
        else {
            return []
        }

        let blockText = String(rawText[blockRange])
        let actionTitles = blockText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line -> String? in
                guard line.hasPrefix("- ") else { return nil }
                let actionTitle = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                return actionTitle.isEmpty ? nil : actionTitle
            }

        let maximumActionCount = min(2, actionTitles.count)
        return Array(actionTitles[0..<maximumActionCount])
    }

    static func displayTitle(from rawTitle: String) -> String {
        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return "CLICKY"
        }

        let flattenedTitle = trimmedTitle
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .uppercased()

        guard flattenedTitle.count > 28 else {
            return flattenedTitle
        }

        let endIndex = flattenedTitle.index(flattenedTitle.startIndex, offsetBy: 28)
        let prefix = String(flattenedTitle[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }
}

struct WikiViewerEntry: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case article
        case skill

        var label: String {
            switch self {
            case .article: return "Article"
            case .skill: return "Skill"
            }
        }
    }

    let id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var body: String
    var relativePath: String

    init(article: WikiManager.Article) {
        self.id = "article:\(article.id)"
        self.kind = .article
        self.title = article.title
        self.subtitle = article.relativePath
        self.body = article.body
        self.relativePath = article.relativePath
    }

    init(skill: WikiManager.Skill) {
        self.id = "skill:\(skill.id)"
        self.kind = .skill
        self.title = skill.title
        self.subtitle = skill.identifier
        self.body = skill.body
        self.relativePath = "skills/\(skill.identifier)/SKILL.md"
    }

    var searchableText: String {
        [title, subtitle, body].joined(separator: " ")
    }
}

extension WikiManager.Index {
    var viewerEntries: [WikiViewerEntry] {
        let articleEntries = articles.map(WikiViewerEntry.init(article:))
        let skillEntries = skills.map(WikiViewerEntry.init(skill:))
        return (articleEntries + skillEntries)
            .sorted { leftEntry, rightEntry in
                leftEntry.title.localizedStandardCompare(rightEntry.title) == .orderedAscending
            }
    }
}

struct HandoffRegionSelection: Equatable {
    var startPositionInScreen: CGPoint
    var endPositionInScreen: CGPoint
    var screenFrame: CGRect
    var comment: String

    var captureRect: CGRect {
        let minX = min(startPositionInScreen.x, endPositionInScreen.x)
        let minY = min(startPositionInScreen.y, endPositionInScreen.y)
        let maxX = max(startPositionInScreen.x, endPositionInScreen.x)
        let maxY = max(startPositionInScreen.y, endPositionInScreen.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var normalizedCaptureRect: CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return .zero }
        let rect = captureRect
        return CGRect(
            x: (rect.minX - screenFrame.minX) / screenFrame.width,
            y: (rect.minY - screenFrame.minY) / screenFrame.height,
            width: rect.width / screenFrame.width,
            height: rect.height / screenFrame.height
        )
    }
}

struct HandoffQueuedRegionScreenshot: Identifiable, Equatable {
    enum CommentSource: Equatable {
        case none
        case typed
    }

    let id: String
    var selection: HandoffRegionSelection
    var imageData: Data
    var queuedAt: Date

    init(id: String = UUID().uuidString, selection: HandoffRegionSelection, imageData: Data, queuedAt: Date = Date()) {
        self.id = id
        self.selection = selection
        self.imageData = imageData
        self.queuedAt = queuedAt
    }

    var imageByteCount: Int { imageData.count }

    var commentSource: CommentSource {
        selection.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .typed
    }

    var metadata: [String: Any] {
        let rect = selection.captureRect
        let normalized = selection.normalizedCaptureRect
        return [
            "captureRect": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height],
            "normalizedCaptureRect": ["x": normalized.minX, "y": normalized.minY, "width": normalized.width, "height": normalized.height],
            "imageByteCount": imageByteCount,
            "commentSource": commentSource == .typed ? "typed" : "none"
        ]
    }
}
