import Combine
import CoreGraphics
import Foundation
import OCCore

enum PermissionStatus: Equatable {
    case missing
    case granted
}

struct PermissionSnapshot: Equatable {
    var accessibility: PermissionStatus
    var screenRecording: PermissionStatus
    var microphone: PermissionStatus
    var camera: PermissionStatus
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
        case camera
        case screenContent

        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .microphone: return "Microphone"
            case .camera: return "Camera"
            case .screenContent: return "Screen Content"
            }
        }

        var systemImageName: String {
            switch self {
            case .accessibility: return "hand.raised"
            case .screenRecording: return "rectangle.dashed.badge.record"
            case .microphone: return "mic"
            case .camera: return "camera"
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
            case .camera:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
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
            case .camera:
                return "Lets OpenClicky use the camera for Visual Intelligence and meeting notes."
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
            Step(kind: .camera, status: snapshot.camera),
            Step(kind: .screenContent, status: snapshot.screenContent)
        ]
        let primaryStep = steps.first { $0.status == .missing }
        let headline = primaryStep == nil ? "Permissions ready" : "Permissions needed"
        let summary: String
        if let primaryStep {
            summary = "Start with \(primaryStep.title). OpenClicky needs all five checks before voice, Visual Intelligence, and Agent Mode can run cleanly."
        } else {
            summary = "OpenClicky can listen, see the active screen and camera when invoked, and hand work to Agent Mode."
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

    static let maximumDisplayCharacters = 1_200

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
        text = text.replacingOccurrences(of: #"(?is)<\s*NEXT_ACTIONS\s*>.*?<\s*/\s*NEXT_ACTIONS\s*>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?im)^\s*TASK[_\s-]*TITLE\s*:\s*.*$"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)```.*?```"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[POINT:[^\]]+\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+.*$"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*_]{3,}\s*$"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?m)^\s*(\$|>|%|find\s|mdfind\s|rg\s|grep\s|ls\s|cat\s|sed\s|awk\s|python\s|node\s|npm\s|swift\s|open\s|osascript\s).*$"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"(?m)^\s*(exit\s+\d+|stdout:|stderr:|command:).*$"#, with: " ", options: [.regularExpression, .caseInsensitive])
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
                of: #"(?is)<\s*NEXT_ACTIONS\s*>\s*(.*?)\s*<\s*/\s*NEXT_ACTIONS\s*>"#,
                options: .regularExpression
            )
        else {
            return []
        }

        var blockText = String(rawText[blockRange])
        blockText = blockText.replacingOccurrences(
            of: #"(?is)<\s*/?\s*NEXT_ACTIONS\s*>"#,
            with: " ",
            options: .regularExpression
        )

        let actionTitles: [String]
        if let regex = try? NSRegularExpression(pattern: #"(?s)(?:^|\s)-\s+(.+?)(?=\s+-\s+|$)"#) {
            let range = NSRange(blockText.startIndex..<blockText.endIndex, in: blockText)
            actionTitles = regex.matches(in: blockText, range: range).compactMap { match in
                guard let titleRange = Range(match.range(at: 1), in: blockText) else { return nil }
                let actionTitle = String(blockText[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                return actionTitle.isEmpty ? nil : actionTitle
            }
        } else {
            actionTitles = []
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

    init(article: OCCore.WikiManager.Article) {
        self.id = "article:\(article.id)"
        self.kind = .article
        self.title = article.title
        self.subtitle = article.relativePath
        self.body = article.body
        self.relativePath = article.relativePath
    }

    init(skill: OCCore.WikiManager.Skill) {
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

extension OCCore.WikiManager.Index {
    @MainActor
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
    /// Freehand trail in AppKit screen coordinates when the region was circled while talking.
    var pathPoints: [CGPoint] = []
    /// Best-effort ambient context (app, window title, URL/path summary).
    var ambientSummary: String = ""

    var captureRect: CGRect {
        // start/end are authoritative (may include padding from circle-select seal).
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

    var hasFreehandPath: Bool { pathPoints.count >= 2 }
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
