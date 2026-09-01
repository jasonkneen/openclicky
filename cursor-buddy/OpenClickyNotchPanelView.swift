import AppKit
import OCComputerUseCore
import OCAutomation
import SwiftUI
import UniformTypeIdentifiers

/// Compact menu-bar surface inspired by the recovered Clicky notch architecture.
///
/// This is intentionally an OpenClicky-original implementation. It only reads
/// the existing fast voice state and routes actions through CompanionManager;
/// it does not replace or wrap the voice capture, transcription, or playback
/// pipeline.
@MainActor
struct OpenClickyNotchPanelView: View {
    struct PanelDraftAttachment: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let kind: AttachmentKind

        enum AttachmentKind {
            case image
            case document
        }

        var displayName: String {
            url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }

        var chipTitle: String {
            switch kind {
            case .image: return "Image attached"
            case .document: return "File attached"
            }
        }

        var systemImage: String {
            switch kind {
            case .image: return "photo"
            case .document: return "doc.text"
            }
        }

        var kindLabel: String {
            switch kind {
            case .image: return "Image"
            case .document: return "Document"
            }
        }
    }

    struct HomeSuggestionItem: Identifiable, Equatable {
        let id: String
        let title: String
        let systemImageName: String
        let prompt: String?
        let mode: OpenClickyQuickPromptMode?
        let opensSettings: Bool
    }

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var agentStore = OpenClickyAgentStore.shared
    @ObservedObject var automationStore = OpenClickyAutomationStore.shared
    @ObservedObject var skillDiscoveryStore = OpenClickySkillDiscoveryStore.shared
    @ObservedObject var petLibrary = ClickyBuddyPetLibrary.shared
    @AppStorage(ClickyAccentTheme.userDefaultsKey) var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(ClickyCursorAvatarStyle.userDefaultsKey) var avatarStyleRawValue = ClickyCursorAvatarStyle.default.storageValue
    @AppStorage(ClickyCursorAvatarSizePreference.userDefaultsKey) var cursorAvatarSizeScale = ClickyCursorAvatarSizePreference.defaultScale
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.userAppTitleFontSizeDefaultsKey) private var appTitleFontSize = 26.0
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    @AppStorage(AppBundleConfiguration.userAppLineSpacingDefaultsKey) private var appLineSpacing = 2.0
    @AppStorage(AppBundleConfiguration.userThemeDefaultsKey) private var clickyTheme = ClickyTheme.system.rawValue
    @State var isShowingHatchSheet = false
    @State var hatchPetName = ""
    @State var hatchPetDescription = ""
    @State var isPanelPinned: Bool

    let setPanelPinned: (Bool) -> Void
    let closePanel: @MainActor () -> Void

    @State var selectedTab: OpenClickyNotchTab = .home
    @State var quickPromptMode: OpenClickyQuickPromptMode = .ask
    @State var quickPrompt: String = ""
    @State var quickPromptAttachments: [PanelDraftAttachment] = []
    @State var quickPromptDroppedPathFragments: Set<String> = []
    @State var isQuickPromptDropTargeted = false
    @State var isPanelDropTargeted = false
    @State var isPanelUserResizing = false
    @State var suppressNextHomeSuggestionResize = false

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private var titleFontSize: CGFloat { CGFloat(appTitleFontSize) }
    var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }
    private var appTextLineSpacing: CGFloat { CGFloat(appLineSpacing) }

    var quickPromptAutocompleteOptions: [OpenClickyPromptAutocompleteOption] {
        OpenClickyPromptAutocomplete.options(
            for: quickPrompt,
            agents: agentStore.agents,
            skillSuggestions: skillDiscoveryStore.suggestions
        )
    }

    var expandedAgentAutocompleteOptions: [OpenClickyPromptAutocompleteOption] {
        OpenClickyPromptAutocomplete.options(
            for: expandedAgentPrompt,
            agents: agentStore.agents,
            skillSuggestions: skillDiscoveryStore.suggestions
        )
    }

    func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    func panelUIFont(size baseSize: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: scaledPanelFontSize(baseSize), weight: appResolvedWeight(weight))
    }

    private func scaledPanelFontSize(_ baseSize: CGFloat) -> CGFloat {
        let scale: CGFloat
        if baseSize >= 15 {
            scale = titleFontSize / 26.0
        } else if baseSize >= 12 {
            scale = bodyFontSize / 13.0
        } else {
            scale = subtextFontSize / 11.0
        }
        return max(7, baseSize * scale)
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        if appBoldTextEnabled {
            switch weight {
            case .light, .regular:
                return .medium
            case .medium:
                return .semibold
            case .semibold:
                return .bold
            case .bold, .heavy, .black:
                return .black
            default:
                return weight
            }
        } else {
            switch weight {
            case .black, .heavy:
                return .semibold
            case .bold:
                return .medium
            case .semibold:
                return .medium
            case .medium:
                return .regular
            case .regular:
                return .regular
            default:
                return weight
            }
        }
    }
    @State var isCompactChatExpanded = false
    @State var expandedAgentSessionID: UUID?
    @State var expandedAgentPrompt: String = ""
    @State var lastKeyboardSubmitAt: Date = .distantPast
    @State var agentPanelSelection: OpenClickyAgentPanelSelection = .sessions
    @State var agentSessionFilter: OpenClickyAgentSessionFilter = .active
    @State var expandedAgentAttachments: [PanelDraftAttachment] = []
    @State var isExpandedAgentDropTargeted = false
    @State var pendingStopAgentSessionID: UUID?
    @State var pendingArchiveAgentSessionID: UUID?
    @State var gogStatus: OpenClickyGogCLIStatus = .unknown
    @State var hasLoadedGogStatus = false
    @FocusState var isQuickPromptFocused: Bool
    @FocusState var isExpandedAgentPromptFocused: Bool

    init(
        companionManager: CompanionManager,
        isPanelPinned: Bool,
        initialFocusedAgentSessionID: UUID? = nil,
        setPanelPinned: @escaping (Bool) -> Void,
        closePanel: @escaping @MainActor () -> Void = {
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        }
    ) {
        self.companionManager = companionManager
        self.setPanelPinned = setPanelPinned
        self.closePanel = closePanel
        _isPanelPinned = State(initialValue: isPanelPinned)
        if let initialFocusedAgentSessionID {
            _selectedTab = State(initialValue: .agents)
            _agentPanelSelection = State(initialValue: .sessions)
            _agentSessionFilter = State(initialValue: .active)
            _expandedAgentSessionID = State(initialValue: initialFocusedAgentSessionID)
        }
    }

    var activeVoiceLabel: String {
        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        }
    }

    var activeVoiceIcon: String {
        switch companionManager.voiceState {
        case .idle: return "bolt.fill"
        case .listening: return "waveform"
        case .processing: return "sparkles"
        case .responding: return "speaker.wave.2.fill"
        }
    }

    var activeVoiceAccent: Color {
        switch companionManager.voiceState {
        case .idle: return DS.Colors.accentText
        case .listening: return .green
        case .processing: return .orange
        case .responding: return .purple
        }
    }

    private var voiceModelLabel: String {
        OpenClickyModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).label
    }

    private var speechModelLabel: String {
        OpenClickyModelCatalog.speechModel(withID: companionManager.selectedSpeechModel).label
    }

    var visibleAgentSessions: [CodexAgentSession] {
        companionManager.codexAgentSessions.filter { session in
            shouldShowAgentSessionInPanel(session) &&
            agentSessionFilter.includes(session: session, archivedSessionIDs: companionManager.archivedSessionIDs)
        }.sorted { leftSession, rightSession in
            if leftSession.latestActivityDate != rightSession.latestActivityDate {
                return leftSession.latestActivityDate > rightSession.latestActivityDate
            }
            return leftSession.title.localizedStandardCompare(rightSession.title) == .orderedAscending
        }
    }

    var visibleAgentSessionCount: Int {
        companionManager.codexAgentSessions.filter(shouldShowAgentSessionInPanel).count
    }

    func shouldShowAgentSessionInPanel(_ session: CodexAgentSession) -> Bool {
        session.hasVisibleActivity
    }

    var completedUnarchivedAgentSessions: [CodexAgentSession] {
        companionManager.codexAgentSessions.filter { session in
            session.isFinishedForArchive && !companionManager.archivedSessionIDs.contains(session.id)
        }
    }

    var compactChatEntries: [CodexTranscriptEntry] {
        let visibleEntries = companionManager.codexAgentSession.entries.compactMap { entry -> CodexTranscriptEntry? in
            guard entry.role != .command else { return nil }
            var displayEntry = entry
            displayEntry.text = compactChatDisplayText(from: entry.text)
            return displayEntry.text.isEmpty ? nil : displayEntry
        }
        return Array(visibleEntries.suffix(8))
    }

    var homeAgentTaskSessions: [CodexAgentSession] {
        companionManager.codexAgentSessions.filter { session in
            !companionManager.archivedSessionIDs.contains(session.id) && session.hasVisibleActivity
        }.sorted { leftSession, rightSession in
            if leftSession.latestActivityDate != rightSession.latestActivityDate {
                return leftSession.latestActivityDate > rightSession.latestActivityDate
            }
            return leftSession.createdAt > rightSession.createdAt
        }
    }

    var isHomeChatBusy: Bool {
        companionManager.codexAgentSession.isTurnActiveForChatQueue
    }

    var hasHomeConversationActivity: Bool {
        !compactChatEntries.isEmpty || isHomeChatBusy || !homeAgentTaskSessions.isEmpty
    }

    var runningAgentCount: Int {
        companionManager.codexAgentSessions.filter { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }.count
    }

    private var enabledAutomationCount: Int {
        automationStore.automations.filter(\.enabled).count
    }

    var connectionRows: [OpenClickyNotchConnectionRow] {
        let nativeComputerUseStatus = companionManager.nativeComputerUseController.status
        let backgroundComputerUseStatus = companionManager.backgroundComputerUseController.status

        return [
            OpenClickyNotchConnectionRow(
                title: "Voice",
                detail: "\(companionManager.buddyDictationManager.transcriptionProviderDisplayName) → \(companionManager.selectedTTSProvider.displayName) · \(speechModelLabel)",
                state: companionManager.hasMicrophonePermission ? .ready : .needsAttention,
                systemImageName: "waveform.circle.fill"
            ),
            OpenClickyNotchConnectionRow(
                title: "Agent Mode",
                detail: "\(visibleAgentSessionCount) sessions · \(agentStore.agents.count) specialist agents · model \(companionManager.codexAgentSession.model)",
                state: companionManager.codexAgentSessions.isEmpty ? .needsAttention : .ready,
                systemImageName: "terminal.fill"
            ),
            OpenClickyNotchConnectionRow(
                title: "Computer Use",
                detail: nativeComputerUseStatus.summary,
                state: nativeComputerUseStatus.isReadyForComputerUse ? .ready : .available,
                systemImageName: "cursorarrow.motionlines"
            ),
            OpenClickyNotchConnectionRow(
                title: "Background CUA",
                detail: backgroundComputerUseStatus.summary,
                state: backgroundComputerUseStatus.isRuntimeReady ? .ready : .available,
                systemImageName: "macwindow.badge.plus"
            ),
            OpenClickyNotchConnectionRow(
                title: "Google Workspace",
                detail: hasLoadedGogStatus ? gogStatus.readinessDetail : "Checking local gogcli files…",
                state: gogStatus.isReadyForUserAccount ? .ready : (gogStatus.isInstalled ? .available : .needsAttention),
                systemImageName: "g.circle.fill"
            ),
            OpenClickyNotchConnectionRow(
                title: "Automations",
                detail: "\(enabledAutomationCount) enabled · \(automationStore.automations.count) total local schedules",
                state: enabledAutomationCount > 0 ? .ready : .available,
                systemImageName: "clock.arrow.circlepath"
            ),
            OpenClickyNotchConnectionRow(
                title: "Skill Discovery",
                detail: "\(skillDiscoveryStore.suggestions.count) suggestions · scans local skills and targeted online sources",
                state: automationStore.skillDiscoveryAutomation?.enabled == true ? .ready : .available,
                systemImageName: "wand.and.stars.inverse"
            )
        ]
    }

    var body: some View {
        resizeAwarePanel(panelLifecycle(panelDialogs(panelRoot)))
            .preferredColorScheme(clickyTheme == ClickyTheme.light.rawValue ? .light : (clickyTheme == ClickyTheme.dark.rawValue ? .dark : nil))
    }
}

enum OpenClickyAgentSessionFilter: String, CaseIterable, Identifiable {
    case active
    case running
    case completed
    case archived
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "Active"
        case .running: return "Running"
        case .completed: return "Completed"
        case .archived: return "Archived"
        case .all: return "All"
        }
    }

    var accessibilityLabel: String { "Show \(title.lowercased()) OpenClicky agent tasks" }

    var systemImageName: String {
        switch self {
        case .active: return "tray.full"
        case .running: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        case .all: return "square.grid.2x2.fill"
        }
    }

    var emptyStateSystemImageName: String {
        switch self {
        case .active: return "terminal"
        case .running: return "bolt"
        case .completed: return "checkmark.circle"
        case .archived: return "archivebox"
        case .all: return "rectangle.stack"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .active: return "No active agent sessions"
        case .running: return "No running agents"
        case .completed: return "No completed agents"
        case .archived: return "No archived agents"
        case .all: return "No agent sessions yet"
        }
    }

    var emptyStateSubtitle: String {
        switch self {
        case .active: return "Start a new prompt from this panel."
        case .running: return "Running tasks will show here while OpenClicky works."
        case .completed: return "Finished tasks appear here once they have a reply."
        case .archived: return "Archived tasks stay tucked away until you need them."
        case .all: return "Start one from the notch panel."
        }
    }

    @MainActor
    func includes(session: CodexAgentSession, archivedSessionIDs: Set<UUID>) -> Bool {
        let isArchived = archivedSessionIDs.contains(session.id)
        switch self {
        case .active:
            return !isArchived
        case .running:
            switch session.status {
            case .starting, .running:
                return !isArchived
            case .stopped, .ready, .failed:
                return !isArchived && session.isTurnActiveForChatQueue
            }
        case .completed:
            return !isArchived && session.isFinishedForArchive
        case .archived:
            return isArchived
        case .all:
            return true
        }
    }
}

enum OpenClickyAgentPanelSelection: String, Equatable {
    case sessions
    case specialists
}

enum OpenClickyNotchTab: String, CaseIterable, Identifiable {
    case home
    case agents
    case connections
    case settings

    static let primaryTabs: [OpenClickyNotchTab] = [.home, .agents, .connections]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .agents: return "Agents"
        case .connections: return "Connect"
        case .settings: return "Settings"
        }
    }

    var systemImageName: String {
        switch self {
        case .home: return "house.fill"
        case .agents: return "terminal.fill"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .settings: return "slider.horizontal.3"
        }
    }
}

enum OpenClickyQuickActionPrompts {
    static let screen = """
    OpenClicky, look at the current screen context. First say what is on the screen, then give a few useful suggestions for what I could do next. End by asking: “Would you like me to do anything else?”
    """

    static let skills = """
    OpenClicky, suggest relevant skills or connections for the active app and current workflow. Explain why they fit, keep it practical, and end by asking: “Would you like me to find some skills?” or “Would you like me to do anything else?”
    """
}

enum OpenClickyQuickPromptMode: Equatable {
    case ask
    case agent
    case chat

    var title: String {
        switch self {
        case .ask: return "Ask OpenClicky"
        case .agent: return "Task an agent"
        case .chat: return "Chat inside OpenClicky"
        }
    }

    var subtitle: String {
        switch self {
        case .ask:
            return "Menu-bar notch surface, existing fast voice stack, and quick local answers."
        case .agent:
            return "Write the task here, then press Return to launch an OpenClicky background agent."
        case .chat:
            return "Send here to expand the panel into the active OpenClicky chat."
        }
    }

    var systemImageName: String {
        switch self {
        case .ask: return "sparkles"
        case .agent: return "terminal.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        }
    }

    var fieldSystemImageName: String {
        switch self {
        case .ask: return "text.bubble.fill"
        case .agent: return "terminal.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        }
    }

    var placeholder: String {
        switch self {
        case .ask: return "Ask OpenClicky…"
        case .agent: return "Task an agent…"
        case .chat: return "Chat with OpenClicky…"
        }
    }

    var buttonTitle: String {
        switch self {
        case .ask: return "Ask"
        case .agent: return "Agent"
        case .chat: return "Chat"
        }
    }

    var buttonSystemImageName: String {
        switch self {
        case .ask: return "paperplane.fill"
        case .agent: return "terminal.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        }
    }
}

struct OpenClickyNotchConnectionRow: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let state: OpenClickyNotchConnectionState
    let systemImageName: String
}

enum OpenClickyNotchConnectionState: Equatable {
    case ready
    case available
    case needsAttention

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .available: return "Local"
        case .needsAttention: return "Needs setup"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .available: return DS.Colors.accentText
        case .needsAttention: return .orange
        }
    }
}

struct OpenClickyPanelTypography {
    let fontRawValue: String
    let boldTextEnabled: Bool
    let titleFontSize: CGFloat
    let bodyFontSize: CGFloat
    let subtextFontSize: CGFloat

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(fontRawValue)
    }

    func font(size baseSize: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: scaledSize(baseSize), weight: resolvedWeight(weight))
    }

    private func scaledSize(_ baseSize: CGFloat) -> CGFloat {
        let scale: CGFloat
        if baseSize >= 15 {
            scale = titleFontSize / 26.0
        } else if baseSize >= 12 {
            scale = bodyFontSize / 13.0
        } else {
            scale = subtextFontSize / 11.0
        }
        return max(7, baseSize * scale)
    }

    private func resolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        guard boldTextEnabled else { return weight }
        switch weight {
        case .regular, .medium:
            return .semibold
        case .semibold:
            return .bold
        default:
            return weight
        }
    }
}

