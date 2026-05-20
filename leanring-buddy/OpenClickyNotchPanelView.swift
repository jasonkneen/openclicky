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
    private struct PanelDraftAttachment: Identifiable, Equatable {
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

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var agentStore = OpenClickyAgentStore.shared
    @ObservedObject private var automationStore = OpenClickyAutomationStore.shared
    @ObservedObject private var skillDiscoveryStore = OpenClickySkillDiscoveryStore.shared
    @ObservedObject private var petLibrary = ClickyBuddyPetLibrary.shared
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(ClickyCursorAvatarStyle.userDefaultsKey) private var avatarStyleRawValue = ClickyCursorAvatarStyle.default.storageValue
    @AppStorage(ClickyCursorAvatarSizePreference.userDefaultsKey) private var cursorAvatarSizeScale = ClickyCursorAvatarSizePreference.defaultScale
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.userAppTitleFontSizeDefaultsKey) private var appTitleFontSize = 26.0
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    @AppStorage(AppBundleConfiguration.userAppLineSpacingDefaultsKey) private var appLineSpacing = 2.0
    @AppStorage(AppBundleConfiguration.userThemeDefaultsKey) private var clickyTheme = ClickyTheme.system.rawValue
    @State private var isShowingHatchSheet = false
    @State private var hatchPetName = ""
    @State private var hatchPetDescription = ""
    @State private var isPanelPinned: Bool

    let setPanelPinned: (Bool) -> Void
    let closePanel: @MainActor () -> Void

    @State private var selectedTab: OpenClickyNotchTab = .home
    @State private var quickPromptMode: OpenClickyQuickPromptMode = .ask
    @State private var quickPrompt: String = ""
    @State private var quickPromptAttachments: [PanelDraftAttachment] = []
    @State private var isQuickPromptDropTargeted = false
    @State private var isPanelDropTargeted = false
    @State private var isPanelUserResizing = false
    @State private var suppressNextHomeSuggestionResize = false

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private var titleFontSize: CGFloat { CGFloat(appTitleFontSize) }
    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }
    private var appTextLineSpacing: CGFloat { CGFloat(appLineSpacing) }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func panelUIFont(size baseSize: CGFloat, weight: Font.Weight = .medium) -> Font {
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
    @State private var isCompactChatExpanded = false
    @State private var expandedAgentSessionID: UUID?
    @State private var expandedAgentPrompt: String = ""
    @State private var lastKeyboardSubmitAt: Date = .distantPast
    @State private var agentPanelSelection: OpenClickyAgentPanelSelection = .sessions
    @State private var agentSessionFilter: OpenClickyAgentSessionFilter = .active
    @State private var expandedAgentAttachments: [PanelDraftAttachment] = []
    @State private var isExpandedAgentDropTargeted = false
    @State private var pendingStopAgentSessionID: UUID?
    @State private var gogStatus: OpenClickyGogCLIStatus = .unknown
    @State private var hasLoadedGogStatus = false
    @FocusState private var isQuickPromptFocused: Bool
    @FocusState private var isExpandedAgentPromptFocused: Bool

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

    private var activeVoiceLabel: String {
        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        }
    }

    private var activeVoiceIcon: String {
        switch companionManager.voiceState {
        case .idle: return "bolt.fill"
        case .listening: return "waveform"
        case .processing: return "sparkles"
        case .responding: return "speaker.wave.2.fill"
        }
    }

    private var activeVoiceAccent: Color {
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

    private var visibleAgentSessions: [CodexAgentSession] {
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

    private var visibleAgentSessionCount: Int {
        companionManager.codexAgentSessions.filter(shouldShowAgentSessionInPanel).count
    }

    private func shouldShowAgentSessionInPanel(_ session: CodexAgentSession) -> Bool {
        session.hasVisibleActivity
    }

    private var completedUnarchivedAgentSessions: [CodexAgentSession] {
        companionManager.codexAgentSessions.filter { session in
            session.progressStage == .completed && !companionManager.archivedSessionIDs.contains(session.id)
        }
    }

    private var compactChatEntries: [CodexTranscriptEntry] {
        let visibleEntries = companionManager.codexAgentSession.entries.compactMap { entry -> CodexTranscriptEntry? in
            guard entry.role != .command else { return nil }
            var displayEntry = entry
            displayEntry.text = compactChatDisplayText(from: entry.text)
            return displayEntry.text.isEmpty ? nil : displayEntry
        }
        return Array(visibleEntries.suffix(8))
    }

    private var homeAgentTaskSessions: [CodexAgentSession] {
        companionManager.codexAgentSessions.filter { session in
            !companionManager.archivedSessionIDs.contains(session.id) && session.hasVisibleActivity
        }.sorted { leftSession, rightSession in
            if leftSession.latestActivityDate != rightSession.latestActivityDate {
                return leftSession.latestActivityDate > rightSession.latestActivityDate
            }
            return leftSession.createdAt > rightSession.createdAt
        }
    }

    private var isHomeChatBusy: Bool {
        companionManager.codexAgentSession.isTurnActiveForChatQueue
    }

    private var hasHomeConversationActivity: Bool {
        !compactChatEntries.isEmpty || isHomeChatBusy || !homeAgentTaskSessions.isEmpty
    }

    private var runningAgentCount: Int {
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

    private var connectionRows: [OpenClickyNotchConnectionRow] {
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

    private var panelRoot: some View {
        VStack(spacing: 0) {
            mainSurface
        }
        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
    }

    private var stopTaskDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingStopAgentSessionID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingStopAgentSessionID = nil
                }
            }
        )
    }

    private func panelDialogs<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $isShowingHatchSheet) {
            hatchPetSheet
        }
        .confirmationDialog(
            "Stop this running OpenClicky task?",
            isPresented: stopTaskDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Stop task", role: .destructive) {
                confirmStopPendingAgentSession()
            }
            Button("Keep running", role: .cancel) {
                pendingStopAgentSessionID = nil
            }
        } message: {
            Text("Running tasks cannot be archived. Stop it first if you want to move it out of the active list.")
        }
    }

    private func panelLifecycle<Content: View>(_ content: Content) -> some View {
        content
        .onAppear {
            syncHomeChatMode(source: "panel_appear")
            syncCompactChatVisibility()
            focusQuickPromptIfHome()
            focusExpandedAgentPromptIfNeeded()
            notifyPanelSizeChanged()
        }
        .task {
            await refreshGogStatus()
            focusQuickPromptIfHome()
            focusExpandedAgentPromptIfNeeded()
        }
        .onChange(of: selectedTab) {
            syncHomeChatMode(source: "panel_tab_changed")
            syncCompactChatVisibility()
            focusQuickPromptIfHome()
            focusExpandedAgentPromptIfNeeded()
            notifyPanelSizeChanged()
        }
        .onChange(of: quickPromptMode) {
            syncHomeChatMode(source: "panel_mode_changed")
            syncCompactChatVisibility()
            if suppressNextHomeSuggestionResize && selectedTab == .home {
                suppressNextHomeSuggestionResize = false
                return
            }
            notifyPanelSizeChanged()
        }
        .onChange(of: quickPromptAttachments.count) {
            notifyPanelSizeChanged()
        }
        .onChange(of: expandedAgentAttachments.count) {
            notifyPanelSizeChanged()
        }
        .onChange(of: companionManager.codexAgentSession.entries.count) {
            guard quickPromptMode == .chat else { return }
            syncCompactChatVisibility()
            notifyPanelSizeChanged()
        }
        .onChange(of: companionManager.codexAgentSession.isTurnActiveForChatQueue) {
            guard quickPromptMode == .chat else { return }
            syncCompactChatVisibility()
            notifyPanelSizeChanged()
        }
        .onChange(of: expandedAgentSessionID) {
            focusExpandedAgentPromptIfNeeded()
            notifyPanelSizeChanged()
        }
        .onChange(of: agentSessionFilter) {
            expandedAgentSessionID = nil
            notifyPanelSizeChanged()
        }
        .onChange(of: gogStatus) {
            notifyPanelSizeChanged()
        }
    }

    private func resizeAwarePanel<Content: View>(_ content: Content) -> some View {
        content
        .onReceive(NotificationCenter.default.publisher(for: .clickyMainPanelResizeStateDidChange)) { notification in
            isPanelUserResizing = (notification.userInfo?["isResizing"] as? Bool) ?? false
        }
        .transaction { transaction in
            if isPanelUserResizing {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private var mainSurface: some View {
        VStack(spacing: 12) {
            tabStrip

            tabContent
                .id(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(isPanelUserResizing ? nil : .spring(response: 0.24, dampingFraction: 0.90), value: selectedTab)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    OpenClickyLiquidGlassBackdropView.isLiquidGlassAvailable ?
                        AnyShapeStyle(Color.clear) :
                        AnyShapeStyle(LinearGradient(
                            colors: [DS.Colors.surface1.opacity(0.98), (DS.Colors.isDarkMode ? Color.black : Color.white).opacity(0.96)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            if isPanelDropTargeted && !isQuickPromptDropTargeted && !isExpandedAgentDropTargeted {
                dropTargetOverlay
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: Self.supportedAttachmentDropTypes,
            isTargeted: $isPanelDropTargeted,
            perform: handlePanelAttachmentDrop
        )
        .animation(.easeOut(duration: 0.16), value: isPanelDropTargeted)
        .animation(isPanelUserResizing ? nil : .spring(response: 0.24, dampingFraction: 0.88), value: quickPromptMode)
        .animation(isPanelUserResizing ? nil : .spring(response: 0.24, dampingFraction: 0.88), value: isCompactChatExpanded)
    }

    private var preferredPanelHeightForSelectedTab: CGFloat {
        switch selectedTab {
        case .home:
            if quickPromptMode == .chat && isCompactChatExpanded {
                return homeAgentTaskSessions.isEmpty ? 620 : 680
            }
            if !homeAgentTaskSessions.isEmpty {
                return quickPromptMode == .agent ? 620 : 560
            }
            if !quickPromptAttachments.isEmpty {
                return 430
            }
            if hasHomeConversationActivity {
                return 560
            }
            return 560
        case .agents:
            if expandedAgentSessionID != nil {
                return hasExpandedAgentChatExpansionRoom ? 760 : 700
            }
            return agentPanelSelection == .specialists ? 430 : 500
        case .connections:
            return 710
        case .settings:
            return 520
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home:
            homeTab
        case .agents:
            agentsTab
        case .connections:
            connectionsTab
        case .settings:
            settingsTab
        }
    }

    private var topStatusRail: some View {
        HStack(spacing: 0) {
            statusRailItem {
                statusPill(
                    title: activeVoiceLabel,
                    systemImageName: activeVoiceIcon,
                    color: activeVoiceAccent
                )
            }
            Button {
                selectedTab = .agents
            } label: {
                statusPill(
                    title: runningAgentCount == 0 ? "Agents ready" : "\(runningAgentCount) running",
                    systemImageName: "terminal.fill",
                    color: runningAgentCount == 0 ? DS.Colors.textSecondary : DS.Colors.accentText
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show OpenClicky agents")
            .help("Show OpenClicky agents")
            .frame(maxWidth: .infinity, alignment: .center)
            statusRailItem {
                statusPill(
                    title: companionManager.allPermissionsGranted ? "Permission" : "Needs perms",
                    systemImageName: companionManager.allPermissionsGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                    color: companionManager.allPermissionsGranted ? .green : .orange
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func statusRailItem<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(OpenClickyNotchTab.primaryTabs) { tab in
                Button {
                    selectPrimaryTab(tab)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.systemImageName)
                            .font(panelUIFont(size: 15, weight: .heavy))
                        Text(tab.title)
                            .font(panelUIFont(size: 10, weight: .heavy))
                    }
                    .foregroundColor(selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedTab == tab ? Color.white.opacity(0.12) : Color.white.opacity(0.045))
                            .shadow(
                                color: selectedTab == tab ? DS.Colors.accentText.opacity(0.20) : .clear,
                                radius: selectedTab == tab ? 9 : 0,
                                x: 0,
                                y: 0
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(selectedTab == tab ? Color.white.opacity(0.08) : Color.white.opacity(0.05), lineWidth: 1)
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .contentShape(Capsule(style: .continuous))
                .accessibilityLabel("Show \(tab.title)")
                .help("Show \(tab.title)")
            }

            panelChromeButton(
                systemImageName: selectedTab == .settings ? "gearshape.fill" : "gearshape",
                accessibilityLabel: "Open OpenClicky panel settings"
            ) {
                selectedTab = .settings
            }

            panelChromeButton(
                systemImageName: isPanelPinned ? "pin.slash.fill" : "pin.fill",
                accessibilityLabel: isPanelPinned ? "Unpin OpenClicky panel" : "Pin OpenClicky panel"
            ) {
                let nextValue = !isPanelPinned
                isPanelPinned = nextValue
                setPanelPinned(nextValue)
            }

            panelChromeButton(
                systemImageName: "xmark",
                accessibilityLabel: "Close OpenClicky panel",
                action: closePanel
            )
        }
        .frame(height: 32)
        .transaction { transaction in
            transaction.animation = nil
        }
    }


    private func selectPrimaryTab(_ tab: OpenClickyNotchTab) {
        guard tab == .connections else {
            selectedTab = tab
            return
        }

        selectedTab = .connections
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            notifyPanelSizeChanged()
        }
    }

    private func panelChromeButton(systemImageName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(panelUIFont(size: 13, weight: .heavy))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var homeTab: some View {
        VStack(spacing: 12) {
            OpenClickyNotchHeroCard(
                title: quickPromptMode.title,
                subtitle: quickPromptMode.subtitle,
                systemImageName: quickPromptMode.systemImageName,
                accent: DS.Colors.accentText
            ) {
                VStack(spacing: 10) {
                    if quickPromptMode == .chat && isCompactChatExpanded {
                        compactChatPane
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        homePromptSuggestions
                            .transition(homeContentTransition)
                    }

                    if !homeAgentTaskSessions.isEmpty {
                        homeAgentTaskChipRow
                            .transition(homeContentTransition)
                    }

                    Spacer(minLength: 18)

                    VStack(spacing: 9) {
                        quickPromptField

                        HStack(spacing: 8) {
                            quickPromptModeButton(.ask)
                            quickPromptModeButton(.agent)
                            quickPromptModeButton(.chat)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            topStatusRail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var homeContentTransition: AnyTransition {
        .opacity.combined(with: .move(edge: .bottom))
    }

    private var homeAgentTaskChipRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "terminal.fill")
                    .font(panelUIFont(size: 10, weight: .black))
                    .foregroundColor(DS.Colors.accentText)
                Text("Agent tasks")
                    .font(panelUIFont(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 0)
            }

            FlowLayout(spacing: 7, rowSpacing: 7) {
                ForEach(Array(homeAgentTaskSessions.prefix(4))) { session in
                    homeAgentTaskChip(session)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func homeAgentTaskChip(_ session: CodexAgentSession) -> some View {
        Button {
            openAgentSessionFromHome(session)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(agentStatusColor(session.status))
                    .frame(width: 7, height: 7)
                    .shadow(color: agentStatusColor(session.status).opacity(0.7), radius: 4, x: 0, y: 0)
                Text(session.title)
                    .font(appUIFont(size: max(9, subtextFontSize - 1), weight: .heavy))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(panelUIFont(size: 8, weight: .black))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(Capsule(style: .continuous).stroke(agentStatusColor(session.status).opacity(0.22), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open agent chat for \(session.title)")
        .help("Open \(session.title) in Agents")
    }

    private func openAgentSessionFromHome(_ session: CodexAgentSession) {
        companionManager.selectCodexAgentSession(session.id)
        agentPanelSelection = .sessions
        agentSessionFilter = .active
        expandedAgentSessionID = session.id
        selectedTab = .agents
        notifyPanelSizeChanged()
    }

    private var homePromptSuggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "lightbulb.fill")
                    .font(panelUIFont(size: 11, weight: .black))
                    .foregroundColor(DS.Colors.accentText)
                Text("Suggestions")
                    .font(panelUIFont(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 7)], spacing: 7) {
                ForEach(homeSuggestionItems, id: \.title) { suggestion in
                    homeSuggestionButton(suggestion.title, systemImageName: suggestion.systemImageName)
                        .transition(homeContentTransition)
                }
            }
            .transition(homeContentTransition)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private var homeSuggestionItems: [(title: String, systemImageName: String)] {
        [
            ("Summarise screen", "rectangle.and.text.magnifyingglass"),
            ("Start an agent", "terminal.fill"),
            ("Open settings", "gearshape.fill")
        ]
    }

    private func homeSuggestionButton(_ title: String, systemImageName: String) -> some View {
        Button {
            applyHomeSuggestion(title)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImageName)
                    .font(panelUIFont(size: 10, weight: .black))
                Text(title)
                    .font(panelUIFont(size: 9, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.065)))
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private func applyHomeSuggestion(_ title: String) {
        switch title {
        case "Summarise screen":
            if quickPromptMode != .ask {
                suppressNextHomeSuggestionResize = true
            }
            quickPromptMode = .ask
            quickPrompt = "Summarise what’s on my screen."
        case "Start an agent":
            if quickPromptMode != .agent {
                suppressNextHomeSuggestionResize = true
            }
            quickPromptMode = .agent
            quickPrompt = "Look at the current OpenClicky screen context and fix the visible issue."
        case "Open settings":
            selectedTab = .settings
        default:
            quickPrompt = title
        }
        focusQuickPromptIfHome()
    }

    private var agentsTab: some View {
        VStack(spacing: 8) {
            agentPanelSelector

            switch agentPanelSelection {
            case .sessions:
                agentSessionsPanel
            case .specialists:
                specialistAgentGrid
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var agentPanelSelector: some View {
        HStack(spacing: 8) {
            agentPanelSelectorButton(
                selection: .sessions,
                title: "Sessions",
                value: "\(visibleAgentSessionCount)",
                detail: "\(runningAgentCount) running now",
                color: DS.Colors.accentText,
                systemImageName: "rectangle.stack.fill"
            )
            agentPanelSelectorButton(
                selection: .specialists,
                title: "Specialists",
                value: "\(agentStore.agents.count)",
                detail: "tap a card to launch",
                color: .purple,
                systemImageName: "person.2.badge.gearshape.fill"
            )
        }
    }

    private func agentPanelSelectorButton(
        selection: OpenClickyAgentPanelSelection,
        title: String,
        value: String,
        detail: String,
        color: Color,
        systemImageName: String
    ) -> some View {
        Button {
            agentPanelSelection = selection
            if selection == .specialists {
                expandedAgentSessionID = nil
            }
            notifyPanelSizeChanged()
        } label: {
            OpenClickyNotchMetricCard(
                title: title,
                value: value,
                detail: detail,
                color: color,
                systemImageName: systemImageName,
                isSelected: agentPanelSelection == selection
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show OpenClicky \(title.lowercased())")
        .help("Show \(title)")
    }

    private var agentSessionsPanel: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                agentSessionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: visibleAgentSessions.isEmpty ? .center : .top)

                agentsFooter
                    .frame(maxWidth: .infinity, alignment: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var agentSessionContent: some View {
        if visibleAgentSessions.isEmpty {
            OpenClickyNotchEmptyState(
                systemImageName: agentSessionFilter.emptyStateSystemImageName,
                title: agentSessionFilter.emptyStateTitle,
                subtitle: agentSessionFilter.emptyStateSubtitle
            )
        } else {
            agentSessionScrollView
        }
    }

    private var agentSessionScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                agentSessionRows
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: expandedAgentSessionID) { _, sessionID in
                guard let sessionID else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.20)) {
                        proxy.scrollTo(sessionID, anchor: .top)
                    }
                }
            }
        }
    }

    private var agentSessionRows: some View {
        VStack(spacing: 6) {
            ForEach(visibleAgentSessions) { session in
                agentRow(session)
                    .id(session.id)
            }
        }
        .padding(.trailing, 2)
    }

    private var specialistAgentGrid: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(panelUIFont(size: 12, weight: .black))
                    .foregroundColor(.purple.opacity(0.9))
                Text("Specialist agents")
                    .font(panelUIFont(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 0)
                Text("Tap to start")
                    .font(panelUIFont(size: 9, weight: .heavy))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if agentStore.agents.isEmpty {
                Text("No specialist agents are installed yet.")
                    .font(panelUIFont(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
            } else {
                ScrollView(.vertical, showsIndicators: agentStore.agents.count > 6) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 7),
                            GridItem(.flexible(), spacing: 7)
                        ],
                        spacing: 7
                    ) {
                        ForEach(agentStore.agents) { agent in
                            specialistAgentTile(agent)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.065), lineWidth: 1))
    }

    private func specialistAgentTile(_ agent: OpenClickyAgentDefinition) -> some View {
        let accent = specialistAgentAccentColor(agent)
        return Button {
            let session = companionManager.createAndSelectNewCodexAgentSession(asAgent: agent)
            agentPanelSelection = .sessions
            expandedAgentSessionID = nil
            agentSessionFilter = .active
            companionManager.selectCodexAgentSession(session.id)
            notifyPanelSizeChanged()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(0.16))
                    Image(systemName: agent.isUserDefined ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.badge.gearshape")
                        .font(panelUIFont(size: 15, weight: .black))
                        .foregroundColor(accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.metadata.displayName)
                        .font(panelUIFont(size: 11, weight: .heavy))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(agent.metadata.description.isEmpty ? agent.slug : agent.metadata.description)
                        .font(panelUIFont(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.058)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(accent.opacity(0.20), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start \(agent.metadata.displayName) specialist agent")
        .help("Start \(agent.metadata.displayName)")
    }

    private func specialistAgentAccentColor(_ agent: OpenClickyAgentDefinition) -> Color {
        guard let hex = agent.metadata.accentColorHex?.trimmingCharacters(in: CharacterSet(charactersIn: "# \n\t")),
              hex.count == 6,
              let value = Int(hex, radix: 16) else {
            return agent.isUserDefined ? DS.Colors.accentText : .purple
        }

        return Color(
            red: Double((value >> 16) & 0xff) / 255.0,
            green: Double((value >> 8) & 0xff) / 255.0,
            blue: Double(value & 0xff) / 255.0
        )
    }

    private var agentsFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(OpenClickyAgentSessionFilter.allCases) { filter in
                    agentFilterButton(filter)
                }
            }

            HStack(spacing: 8) {
                secondaryActionButton(title: "New prompt", systemImageName: "plus.message.fill") {
                    selectedTab = .home
                }

                if !completedUnarchivedAgentSessions.isEmpty {
                    secondaryActionButton(title: "Archive done", systemImageName: "archivebox.fill") {
                        archiveCompletedAgentSessions()
                    }
                }

                agentUtilityIconButton(
                    systemImageName: "books.vertical",
                    accessibilityLabel: "Open OpenClicky memory browser"
                ) {
                    companionManager.showMemoryWindow()
                }

                agentUtilityIconButton(
                    systemImageName: "doc.text",
                    accessibilityLabel: "Open OpenClicky memory file"
                ) {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.persistentMemoryFile)
                }

                agentUtilityIconButton(
                    systemImageName: "wand.and.stars",
                    accessibilityLabel: "Open OpenClicky learned skills folder"
                ) {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.learnedSkillsDirectory)
                }
            }
        }
    }

    private func agentFilterButton(_ filter: OpenClickyAgentSessionFilter) -> some View {
        let isSelected = agentSessionFilter == filter
        let count = companionManager.codexAgentSessions.filter { session in
            shouldShowAgentSessionInPanel(session) &&
            filter.includes(session: session, archivedSessionIDs: companionManager.archivedSessionIDs)
        }.count

        return Button {
            agentSessionFilter = filter
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.systemImageName)
                    .font(panelUIFont(size: 13, weight: .black))
                Text("\(count)")
                    .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .heavy))
                    .monospacedDigit()
            }
            .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? DS.Colors.accent.opacity(0.95) : Color.white.opacity(0.065))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accentText.opacity(0.42) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.accessibilityLabel)
        .help(filter.title)
    }

    private func archiveCompletedAgentSessions() {
        let sessionIDs = completedUnarchivedAgentSessions.map(\.id)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            if let expandedAgentSessionID,
               sessionIDs.contains(expandedAgentSessionID) {
                self.expandedAgentSessionID = nil
            }
            sessionIDs.forEach { companionManager.archiveSession($0) }
            if agentSessionFilter == .completed {
                agentSessionFilter = .active
            }
        }
    }

    private func isAgentSessionRunning(_ session: CodexAgentSession) -> Bool {
        switch session.status {
        case .starting, .running:
            return true
        case .stopped, .ready, .failed:
            return session.isTurnActiveForChatQueue
        }
    }

    private func confirmStopPendingAgentSession() {
        guard let sessionID = pendingStopAgentSessionID else { return }
        pendingStopAgentSessionID = nil
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            companionManager.selectCodexAgentSession(sessionID)
            companionManager.stopCodexAgentSession(sessionID, reason: "agent_panel_stop")
        }
    }

    private func agentUtilityIconButton(systemImageName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(panelUIFont(size: 14, weight: .black))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var connectionsTab: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 10) {
                OpenClickyNotchEmptyState(
                    systemImageName: "point.3.connected.trianglepath.dotted",
                    title: "Connections",
                    subtitle: "Use Agent Mode skills for Notion, GitHub, mail, browser, files, and app workflows. No hosted sync required."
                )
                skillDiscoveryPanel
                VStack(spacing: 7) {
                    ForEach(connectionRows) { row in
                        connectionRow(row)
                    }
                }
                primaryActionButton(title: "Open settings", systemImageName: "gearshape.fill") {
                    companionManager.showSettingsWindow()
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxHeight: 590, alignment: .top)
        .onAppear {
            automationStore.ensureSkillDiscoveryAutomationInstalled()
            skillDiscoveryStore.reload()
        }
    }

    private var skillDiscoveryPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(panelUIFont(size: 15, weight: .black))
                    .foregroundColor(DS.Colors.accentText)
                VStack(alignment: .leading, spacing: 1) {
                    Text("App skill discovery")
                        .font(panelUIFont(size: 12, weight: .heavy))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(skillDiscoveryStatusText)
                        .font(panelUIFont(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                secondaryActionButton(title: "Run now", systemImageName: "play.fill") {
                    runSkillDiscoveryNow()
                }
                secondaryActionButton(title: "Open skills", systemImageName: "folder.fill") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.learnedSkillsDirectory)
                }
            }

            if skillDiscoveryStore.suggestions.isEmpty {
                Text("OpenClicky will populate this with local and online skill matches after the scheduled pass runs.")
                    .font(panelUIFont(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.045)))
            } else {
                VStack(spacing: 7) {
                    ForEach(skillDiscoveryStore.suggestions) { suggestion in
                        skillDiscoverySuggestionRow(suggestion)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.Colors.accentText.opacity(0.14), lineWidth: 1))
    }

    private var skillDiscoveryStatusText: String {
        guard let automation = automationStore.skillDiscoveryAutomation else {
            return "Preconfigured schedule will be added automatically."
        }
        let enabled = automation.enabled ? "enabled" : "paused"
        if let appName = skillDiscoveryStore.activeApplicationName, !appName.isEmpty {
            return "\(enabled) · tuned for \(appName)"
        }
        if let next = automation.nextRun, automation.enabled {
            return "\(enabled) · next \(next.formatted(.dateTime.weekday().hour().minute()))"
        }
        return "\(enabled) · \(automation.schedule.displayString)"
    }

    private func skillDiscoverySuggestionRow(_ suggestion: OpenClickySkillDiscoverySuggestion) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: skillDiscoverySuggestionIcon(for: suggestion))
                .font(panelUIFont(size: 13, weight: .black))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(DS.Colors.accentText.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.title)
                        .font(panelUIFont(size: 11, weight: .heavy))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(suggestion.sourceLabel)
                        .font(panelUIFont(size: 8, weight: .black))
                        .foregroundColor(DS.Colors.accentText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(DS.Colors.accentText.opacity(0.12)))
                }
                Text(suggestion.detail)
                    .font(panelUIFont(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Button {
                installSkillSuggestion(suggestion)
            } label: {
                Text(suggestion.actionLabel)
                    .font(panelUIFont(size: 9, weight: .heavy))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(suggestion.actionLabel) \(suggestion.title)")
            .help("Start an OpenClicky agent to \(suggestion.actionLabel.lowercased()) \(suggestion.title)")
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.052)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.065), lineWidth: 1))
    }

    private func skillDiscoverySuggestionIcon(for suggestion: OpenClickySkillDiscoverySuggestion) -> String {
        switch suggestion.source.lowercased() {
        case "online":
            return "globe"
        case "mcp":
            return "point.3.connected.trianglepath.dotted"
        case "app":
            return "app.fill"
        default:
            return "wand.and.stars"
        }
    }

    private func runSkillDiscoveryNow() {
        automationStore.ensureSkillDiscoveryAutomationInstalled()
        if let agent = agentStore.agent(slug: OpenClickyAgentStore.skillDiscoveryAgentSlug) {
            let session = companionManager.createAndSelectNewCodexAgentSession(asAgent: agent)
            session.submitPromptFromUI(OpenClickyAutomationStore.skillDiscoveryAutomationPrompt, screenContext: nil)
        } else {
            companionManager.submitAgentPromptFromUI(OpenClickyAutomationStore.skillDiscoveryAutomationPrompt)
        }
    }

    private func installSkillSuggestion(_ suggestion: OpenClickySkillDiscoverySuggestion) {
        let prompt = suggestion.installPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        companionManager.submitNewAgentTaskFromUI(
            prompt.isEmpty ? "Install or connect the \(suggestion.title) skill for OpenClicky Agent Mode, preserving local skill and memory rules." : prompt,
            source: "open_clicky_connect_tab"
        )
        notifyPanelSizeChanged()
    }

    private var settingsTab: some View {
        VStack(spacing: 10) {
            cursorBuddySection
            cursorColorSection

            primaryActionButton(title: "Full settings", systemImageName: "gearshape.fill") {
                companionManager.showSettingsWindow()
            }
        }
    }

    private var quickPromptField: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !quickPromptAttachments.isEmpty {
                attachmentChipRow(attachments: quickPromptAttachments, remove: removeQuickPromptAttachment)
            }

            HStack(spacing: 8) {
                Image(systemName: quickPromptMode.fieldSystemImageName)
                    .font(panelUIFont(size: 15, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                TextField(quickPromptAttachments.isEmpty ? quickPromptMode.placeholder : "Ask about the attachment…", text: $quickPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(panelUIFont(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1...5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($isQuickPromptFocused)
                    .submitLabel(.send)
                    .onSubmit { submitQuickPromptFromKeyboard() }
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            return .ignored
                        }
                        submitQuickPromptFromKeyboard()
                        return .handled
                    }
                Button(action: submitQuickPrompt) {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                            .font(panelUIFont(size: 12, weight: .black))
                        Text("Send")
                            .font(panelUIFont(size: 11, weight: .heavy))
                    }
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [DS.Colors.accent, DS.Colors.accentHover], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel("Send OpenClicky prompt")
                .help("Send OpenClicky prompt")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.28)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isQuickPromptDropTargeted ? DS.Colors.accentText.opacity(0.55) : Color.white.opacity(0.08), lineWidth: isQuickPromptDropTargeted ? 1.2 : 1)
        )
        .overlay {
            if isQuickPromptDropTargeted {
                dropTargetOverlay
            }
        }
        .onDrop(
            of: Self.supportedAttachmentDropTypes,
            isTargeted: $isQuickPromptDropTargeted
        ) { providers in
            handleAttachmentDrop(providers) { url, kind in
                addQuickPromptAttachment(url, forcedKind: kind)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isQuickPromptDropTargeted)
    }

    private var compactChatPane: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if compactChatEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Chat stays here")
                                .font(panelUIFont(size: 12, weight: .heavy))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Type or speak while Chat is selected; Home mirrors the active Ask Agent chat.")
                                .font(panelUIFont(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
                    } else {
                        ForEach(compactChatEntries) { entry in
                            compactChatBubble(entry)
                                .id(entry.id)
                        }
                    }

                    if isHomeChatBusy {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.72)
                            Text(activeVoiceLabel)
                                .font(appUIFont(size: max(10, subtextFontSize), weight: .heavy))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        .padding(.horizontal, max(9, bodyFontSize * 0.75))
                        .padding(.vertical, max(7, bodyFontSize * 0.52))
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.055)))
                        .id("compact-chat-status")
                    }
                }
                .padding(9)
            }
            .frame(maxHeight: 238)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.22)))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .onChange(of: companionManager.codexAgentSession.entries.count) {
                let targetID = compactChatEntries.last?.id ?? (isHomeChatBusy ? "compact-chat-status" : nil)
                guard let targetID else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(targetID, anchor: .bottom)
                }
            }
        }
    }

    private func compactChatBubble(_ entry: CodexTranscriptEntry) -> some View {
        let isUser = entry.role == .user
        return HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(compactChatRoleLabel(for: entry.role))
                    .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .black))
                    .foregroundColor(compactChatRoleColor(for: entry.role))
                Text(entry.text)
                    .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, max(9, bodyFontSize * 0.82))
            .padding(.vertical, max(8, bodyFontSize * 0.66))
            .background(RoundedRectangle(cornerRadius: max(13, bodyFontSize + 2), style: .continuous).fill(compactChatBubbleColor(for: entry.role)))
            .overlay(RoundedRectangle(cornerRadius: max(13, bodyFontSize + 2), style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
            if !isUser { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func compactChatDisplayText(from rawText: String) -> String {
        var text = rawText
        text = text.replacingOccurrences(of: #"(?s)<NEXT_ACTIONS>.*?</NEXT_ACTIONS>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^TASK_TITLE:.*$"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactChatRoleLabel(for role: CodexTranscriptEntry.Role) -> String {
        switch role {
        case .user: return "You"
        case .assistant: return "OpenClicky"
        case .system: return "System"
        case .command: return "Tool"
        case .plan: return "Plan"
        }
    }

    private func compactChatRoleColor(for role: CodexTranscriptEntry.Role) -> Color {
        switch role {
        case .user: return DS.Colors.accentText
        case .assistant: return .green
        case .system: return .orange
        case .command: return .yellow
        case .plan: return .purple
        }
    }

    private func compactChatBubbleColor(for role: CodexTranscriptEntry.Role) -> Color {
        switch role {
        case .user: return DS.Colors.accent.opacity(0.16)
        case .assistant: return Color.white.opacity(0.07)
        case .system: return .orange.opacity(0.10)
        case .command: return .yellow.opacity(0.08)
        case .plan: return .purple.opacity(0.10)
        }
    }

    @ViewBuilder
    private func quickPromptModeButton(_ mode: OpenClickyQuickPromptMode) -> some View {
        let action = {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
                quickPromptMode = mode
                if mode != .chat {
                    isCompactChatExpanded = false
                }
            }
        }

        if quickPromptMode == mode {
            primaryActionButton(title: mode.buttonTitle, systemImageName: mode.buttonSystemImageName, action: action)
        } else {
            secondaryActionButton(title: mode.buttonTitle, systemImageName: mode.buttonSystemImageName, action: action)
        }
    }

    private func syncHomeChatMode(source: String) {
        companionManager.setHomeChatModeActive(selectedTab == .home && quickPromptMode == .chat, source: source)
    }

    private func syncCompactChatVisibility() {
        guard quickPromptMode == .chat else { return }
        if !compactChatEntries.isEmpty || isHomeChatBusy {
            isCompactChatExpanded = true
        }
    }

    private var currentCursorAvatarStyle: ClickyCursorAvatarStyle {
        ClickyCursorAvatarStyle(storageValue: avatarStyleRawValue)
    }

    private var shouldShowCursorColorSection: Bool {
        switch currentCursorAvatarStyle {
        case .triangleFilled, .triangleOutline:
            return true
        case .pet:
            return false
        }
    }

    private var cursorBuddySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Cursor buddy")
                    .font(panelUIFont(size: 12, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button(action: { presentHatchSheet() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(panelUIFont(size: 12, weight: .semibold))
                        Text("Hatch new")
                            .font(panelUIFont(size: 10, weight: .heavy))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
                .accessibilityLabel("Hatch a new cursor buddy")
                .help("Hatch a new cursor buddy")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    avatarTile(.triangleFilled, label: "Triangle")
                    avatarTile(.triangleOutline, label: "Outline")
                    ForEach(petLibrary.pets) { pet in
                        avatarTileForPet(pet)
                    }
                    if petLibrary.pets.isEmpty {
                        emptyBuddiesHintTile
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Buddy size")
                        .font(panelUIFont(size: 10, weight: .heavy))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(Int((cursorAvatarSizeScale * 100).rounded()))%")
                        .font(panelUIFont(size: 10, weight: .heavy))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Slider(
                    value: $cursorAvatarSizeScale,
                    in: ClickyCursorAvatarSizePreference.minScale...ClickyCursorAvatarSizePreference.maxScale
                )
                .controlSize(.small)
                .tint((ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor)
            }
        }
    }

    private var cursorColorSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Cursor color")
                .font(panelUIFont(size: 12, weight: .heavy))
                .foregroundColor(DS.Colors.textSecondary)

            LazyVGrid(columns: cursorColorGridColumns, spacing: 6) {
                ForEach(cursorColorThemeOrder) { accentTheme in
                    cursorColorButton(accentTheme)
                }
            }
        }
    }

    private var emptyBuddiesHintTile: some View {
        Button(action: { presentHatchSheet() }) {
            VStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(panelUIFont(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Hatch")
                    .font(panelUIFont(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(width: 62, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.Colors.borderSubtle, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hatch a new cursor buddy")
        .help("Hatch a new cursor buddy")
    }

    private func avatarTile(_ style: ClickyCursorAvatarStyle, label: String) -> some View {
        let isSelected = currentCursorAvatarStyle == style
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return Button(action: { avatarStyleRawValue = style.storageValue }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.16) : Color.white.opacity(0.055))

                Group {
                    switch style {
                    case .triangleFilled:
                        Triangle()
                            .fill(accent)
                            .frame(width: 18, height: 18)
                            .rotationEffect(.degrees(-25))
                            .shadow(color: accent.opacity(0.72), radius: 8)
                    case .triangleOutline:
                        Triangle()
                            .stroke(accent, lineWidth: 2.5)
                            .frame(width: 18, height: 18)
                            .rotationEffect(.degrees(-25))
                    case .pet:
                        EmptyView()
                    }
                }
            }
            .frame(width: 62, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? accent : DS.Colors.borderSubtle, lineWidth: isSelected ? 1.7 : 0.7))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func avatarTileForPet(_ pet: ClickyBuddyPet) -> some View {
        let style = ClickyCursorAvatarStyle.pet(id: pet.id)
        let isSelected = currentCursorAvatarStyle == style
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return Button(action: { avatarStyleRawValue = style.storageValue }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.16) : Color.white.opacity(0.055))
                ClickyPetThumbnailView(pet: pet)
                    .frame(width: 34, height: 36)
            }
            .frame(width: 62, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? accent : DS.Colors.borderSubtle, lineWidth: isSelected ? 1.7 : 0.7))
        }
        .buttonStyle(.plain)
        .help(pet.displayName)
    }

    private var cursorColorThemeOrder: [ClickyAccentTheme] {
        [.rose, .orange, .amber, .lime, .mint, .cyan, .blue, .violet, .white]
    }

    private var cursorColorGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 64), spacing: 6)]
    }

    private func cursorColorButton(_ accentTheme: ClickyAccentTheme) -> some View {
        let isSelected = selectedAccentThemeID == accentTheme.rawValue
        return Button(action: { selectedAccentThemeID = accentTheme.rawValue }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accentTheme.cursorColor.opacity(0.16) : Color.white.opacity(0.055))
                Triangle()
                    .fill(accentTheme.cursorColor)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-25))
                    .shadow(color: accentTheme.cursorColor.opacity(0.72), radius: 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? accentTheme.cursorColor : DS.Colors.borderSubtle, lineWidth: isSelected ? 1.7 : 0.7))
        }
        .buttonStyle(.plain)
        .help(accentTheme.title)
    }

    private func presentHatchSheet() {
        hatchPetName = ""
        hatchPetDescription = ""
        isShowingHatchSheet = true
    }

    private var hatchPetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hatch a new buddy")
                .font(panelUIFont(size: 14, weight: .semibold))
            Text("Launches an Agent Mode hatch-pet session.")
                .font(panelUIFont(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
            TextField("Name", text: $hatchPetName)
                .textFieldStyle(.roundedBorder)
            TextField("Description optional", text: $hatchPetDescription)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isShowingHatchSheet = false }
                    .help("Cancel buddy hatch")
                Button("Hatch") {
                    let theme = ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue
                    _ = ClickyPetHatchCoordinator.shared.beginHatch(
                        name: hatchPetName,
                        description: hatchPetDescription,
                        accentTheme: theme,
                        companionManager: companionManager
                    )
                    isShowingHatchSheet = false
                }
                .disabled(hatchPetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Start hatching this buddy")
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var permissionProgressStrip: some View {
        let permissions: [(String, Bool)] = [
            ("AX", companionManager.hasAccessibilityPermission),
            ("Screen", companionManager.hasScreenRecordingPermission),
            ("Mic", companionManager.hasMicrophonePermission),
            ("Content", companionManager.hasScreenContentPermission)
        ]

        return HStack(spacing: 7) {
            ForEach(permissions, id: \.0) { permission in
                HStack(spacing: 5) {
                    Circle()
                        .fill(permission.1 ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(permission.0)
                        .font(panelUIFont(size: 9, weight: .heavy))
                        .foregroundColor(permission.1 ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(permission.1 ? 0.075 : 0.045))
                )
            }
        }
    }

    private func agentRow(_ session: CodexAgentSession) -> some View {
        let isExpanded = expandedAgentSessionID == session.id
        let isArchived = companionManager.archivedSessionIDs.contains(session.id)
        let isRunning = isAgentSessionRunning(session)
        let canStop = !isArchived && isRunning
        let canArchive = !isArchived && !isRunning
        let showsTerminalControl = canStop || canArchive || isArchived
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    companionManager.selectCodexAgentSession(session.id)
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        expandedAgentSessionID = isExpanded ? nil : session.id
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isRunning {
                            OpenClickyRunningAgentIndicator(color: agentStatusColor(session.status))
                                .frame(width: 18, height: 10, alignment: .center)
                        } else {
                            Circle()
                                .fill(agentStatusColor(session.status))
                                .frame(width: 8, height: 8)
                                .shadow(color: agentStatusColor(session.status).opacity(0.7), radius: 5, x: 0, y: 0)
                                .frame(width: 18, height: 10, alignment: .center)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(panelUIFont(size: 12, weight: .heavy))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)

                            Text(session.latestActivityDisplaySummary ?? session.statusSummaryLine)
                                .font(panelUIFont(size: 10, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)
                        Text(session.status.label)
                            .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .black))
                            .foregroundColor(agentStatusColor(session.status))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, max(6, subtextFontSize * 0.58))
                            .padding(.vertical, max(3, subtextFontSize * 0.28))
                            .background(Capsule(style: .continuous).fill(agentStatusColor(session.status).opacity(0.14)))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(panelUIFont(size: 13, weight: .black))
                            .foregroundColor(isExpanded ? DS.Colors.accentText : DS.Colors.textTertiary)
                    }
                    .padding(.vertical, 10)
                    .padding(.leading, 10)
                    .padding(.trailing, showsTerminalControl ? 4 : 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(session.title)" : "Expand \(session.title)")
                .help(isExpanded ? "Collapse \(session.title)" : "Expand \(session.title)")

                if canStop {
                    agentArchiveButton(
                        systemImageName: "stop.circle.fill",
                        accessibilityLabel: "Stop running task \(session.title)",
                        helpText: "Stop this running OpenClicky task",
                        foregroundColor: DS.Colors.destructiveText
                    ) {
                        pendingStopAgentSessionID = session.id
                    }
                } else if isArchived {
                    agentArchiveButton(
                        systemImageName: "tray.and.arrow.up.fill",
                        accessibilityLabel: "Unarchive \(session.title)",
                        helpText: "Unarchive this OpenClicky task"
                    ) {
                        companionManager.unarchiveSession(session.id)
                    }
                } else if canArchive {
                    agentArchiveButton(
                        systemImageName: "archivebox.fill",
                        accessibilityLabel: "Archive task \(session.title)",
                        helpText: "Archive this OpenClicky task"
                    ) {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            if expandedAgentSessionID == session.id {
                                expandedAgentSessionID = nil
                            }
                            companionManager.archiveSession(session.id)
                        }
                    }
                }
            }
            .padding(.trailing, showsTerminalControl ? 8 : 0)

            if isExpanded {
                expandedAgentConversation(for: session)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(isExpanded ? 0.072 : 0.055)))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(session.id == companionManager.activeCodexAgentSessionID ? DS.Colors.accentText.opacity(0.35) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isExpanded)
    }

    private func agentArchiveButton(
        systemImageName: String,
        accessibilityLabel: String,
        helpText: String,
        foregroundColor: Color = DS.Colors.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(panelUIFont(size: 13, weight: .black))
                .foregroundColor(foregroundColor)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.075))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(helpText)
    }

    private func expandedAgentConversation(for session: CodexAgentSession) -> some View {
        let entries = agentConversationEntries(for: session)
        let activityLines = agentLiveActivityLines(for: session)
        return VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if entries.isEmpty {
                            Text("No conversation yet. Send a follow-up to talk to this OpenClicky task.")
                                .font(panelUIFont(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.045)))
                        } else {
                            ForEach(entries) { entry in
                                compactChatBubble(entry)
                                    .id(entry.id)
                            }
                        }

                        ForEach(Array(activityLines.enumerated()), id: \.offset) { index, line in
                            agentLiveActivityRow(line)
                                .id("\(session.id.uuidString)-agent-live-activity-\(index)")
                        }

                        if session.isTurnActiveForChatQueue {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.72)
                                Text(session.progressStage.label)
                                    .font(appUIFont(size: max(10, subtextFontSize), weight: .heavy))
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                            .padding(.horizontal, max(9, bodyFontSize * 0.75))
                            .padding(.vertical, max(7, bodyFontSize * 0.52))
                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.055)))
                            .id("\(session.id.uuidString)-agent-status")
                        }

                        if session.canResumeAfterRelaunch {
                            Button {
                                companionManager.selectCodexAgentSession(session.id)
                                session.resumeInterruptedTaskAfterRelaunch()
                                notifyPanelSizeChanged()
                            } label: {
                                Label("Resume task", systemImage: "arrow.clockwise.circle.fill")
                                    .font(panelUIFont(size: 11, weight: .heavy))
                                    .foregroundColor(DS.Colors.textOnAccent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Capsule(style: .continuous).fill(DS.Colors.accent))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Resume OpenClicky task after relaunch")
                            .help("Resume this unfinished OpenClicky task after relaunch")
                            .id("\(session.id.uuidString)-resume-task")
                        }
                    }
                    .padding(9)
                }
                .frame(minHeight: expandedAgentConversationMinHeight, maxHeight: expandedAgentConversationMaxHeight)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.22)))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .onChange(of: session.entries.count) {
                    let targetID = entries.last?.id ?? (session.isTurnActiveForChatQueue ? "\(session.id.uuidString)-agent-status" : nil)
                    guard let targetID else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(targetID, anchor: .bottom)
                    }
                    notifyPanelSizeChanged()
                }
                .onChange(of: session.isTurnActiveForChatQueue) {
                    notifyPanelSizeChanged()
                }
            }

            agentReplyField(for: session)
        }
    }

    private var hasExpandedAgentChatExpansionRoom: Bool {
        visibleAgentSessions.count <= 2
    }

    private var expandedAgentConversationMinHeight: CGFloat {
        hasExpandedAgentChatExpansionRoom ? 340 : 170
    }

    private var expandedAgentConversationMaxHeight: CGFloat {
        hasExpandedAgentChatExpansionRoom ? 420 : 220
    }

    private func agentReplyField(for session: CodexAgentSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !expandedAgentAttachments.isEmpty {
                attachmentChipRow(attachments: expandedAgentAttachments, remove: removeExpandedAgentAttachment)
            }

            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(panelUIFont(size: 15, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                TextField(expandedAgentAttachments.isEmpty ? "Talk to this task…" : "Talk to this task about the attachment…", text: $expandedAgentPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(panelUIFont(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1...5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($isExpandedAgentPromptFocused)
                    .submitLabel(.send)
                    .onSubmit { submitExpandedAgentPromptFromKeyboard(to: session) }
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            return .ignored
                        }
                        submitExpandedAgentPromptFromKeyboard(to: session)
                        return .handled
                    }
                Button {
                    submitExpandedAgentPrompt(to: session)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                            .font(panelUIFont(size: 12, weight: .black))
                        Text("Send")
                            .font(panelUIFont(size: 11, weight: .heavy))
                    }
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [DS.Colors.accent, DS.Colors.accentHover], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel("Send message to OpenClicky task")
                .help("Send message to OpenClicky task")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.28)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isExpandedAgentDropTargeted ? DS.Colors.accentText.opacity(0.55) : Color.white.opacity(0.08), lineWidth: isExpandedAgentDropTargeted ? 1.2 : 1)
        )
        .overlay {
            if isExpandedAgentDropTargeted {
                dropTargetOverlay
            }
        }
        .onDrop(
            of: Self.supportedAttachmentDropTypes,
            isTargeted: $isExpandedAgentDropTargeted
        ) { providers in
            handleAttachmentDrop(providers) { url, kind in
                addExpandedAgentAttachment(url, forcedKind: kind)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isExpandedAgentDropTargeted)
    }

    private func agentLiveActivityLines(for session: CodexAgentSession) -> [String] {
        guard session.isTurnActiveForChatQueue else { return [] }
        var seen = Set<String>()
        let lines = session.activityStatusLines.reversed().compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !seen.contains(line) else { return nil }
            seen.insert(line)
            return line
        }
        return Array(lines.prefix(3)).reversed()
    }

    private func agentLiveActivityRow(_ line: String) -> some View {
        HStack(alignment: .center, spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
            Text(line)
                .font(appUIFont(size: max(10, subtextFontSize), weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, max(9, bodyFontSize * 0.75))
        .padding(.vertical, max(7, bodyFontSize * 0.52))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 0.5))
    }

    private func agentConversationEntries(for session: CodexAgentSession) -> [CodexTranscriptEntry] {
        let visibleEntries = session.entries.compactMap { entry -> CodexTranscriptEntry? in
            guard entry.role != .command else { return nil }
            var displayEntry = entry
            displayEntry.text = compactChatDisplayText(from: entry.text)
            return displayEntry.text.isEmpty ? nil : displayEntry
        }
        return Array(visibleEntries.suffix(hasExpandedAgentChatExpansionRoom ? 14 : 6))
    }

    private func submitExpandedAgentPromptFromKeyboard(to session: CodexAgentSession) {
        guard shouldAcceptKeyboardSubmit() else { return }
        submitExpandedAgentPrompt(to: session)
    }

    private func shouldAcceptKeyboardSubmit() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastKeyboardSubmitAt) > 0.18 else { return false }
        lastKeyboardSubmitAt = now
        return true
    }

    private func submitExpandedAgentPrompt(to session: CodexAgentSession) {
        let trimmedPrompt = expandedAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = expandedAgentAttachments
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else { return }

        expandedAgentPrompt = ""
        expandedAgentAttachments.removeAll()
        companionManager.selectCodexAgentSession(session.id)
        companionManager.submitAgentPromptFromUI(promptWithAttachments(trimmedPrompt, attachments: attachments))
        notifyPanelSizeChanged()
    }

    private func connectionRow(_ row: OpenClickyNotchConnectionRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.systemImageName)
                .font(panelUIFont(size: 15, weight: .heavy))
                .foregroundColor(row.state.color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(row.state.color.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(panelUIFont(size: 12, weight: .heavy))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(row.state.title)
                        .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .black))
                        .foregroundColor(row.state.color)
                        .padding(.horizontal, max(6, subtextFontSize * 0.58))
                        .padding(.vertical, max(3, subtextFontSize * 0.28))
                        .background(Capsule(style: .continuous).fill(row.state.color.opacity(0.14)))
                }
                Text(row.detail)
                    .font(panelUIFont(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.052)))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 1)
        )
    }

    private func settingSummaryRow(title: String, detail: String, systemImageName: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImageName)
                .font(panelUIFont(size: 13, weight: .bold))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(DS.Colors.accentText.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(panelUIFont(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(detail)
                    .font(panelUIFont(size: 12, weight: .heavy))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.052)))
    }

    private func statusPill(title: String, systemImageName: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImageName)
                .font(appUIFont(size: max(13, subtextFontSize + 2), weight: .heavy))
            Text(title)
                .font(appUIFont(size: max(11, subtextFontSize), weight: .heavy))
        }
        .foregroundColor(color)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, max(9, subtextFontSize * 0.72))
        .padding(.vertical, max(6, subtextFontSize * 0.50))
        .background(Capsule(style: .continuous).fill(color.opacity(0.105)))
        .overlay(Capsule(style: .continuous).stroke(color.opacity(0.18), lineWidth: 1))
        .help(title)
    }

    private func primaryActionButton(title: String, systemImageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImageName)
                    .font(panelUIFont(size: 13, weight: .black))
                Text(title)
                    .font(panelUIFont(size: 11, weight: .heavy))
            }
            .foregroundColor(DS.Colors.textOnAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [DS.Colors.accent, DS.Colors.accentHover], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private func secondaryActionButton(title: String, systemImageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImageName)
                    .font(panelUIFont(size: 13, weight: .black))
                Text(title)
                    .font(panelUIFont(size: 11, weight: .heavy))
            }
            .foregroundColor(DS.Colors.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private func submitQuickAskPrompt() {
        let trimmedPrompt = quickPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = quickPromptAttachments
        // Empty submit does nothing -- previously this fell back to the legacy
        // expandTextInput dialog ("Ask OpenClicky / Voice / Text / Agent"),
        // which is being retired in favor of this in-panel prompt surface.
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else { return }

        quickPrompt = ""
        quickPromptAttachments.removeAll()
        companionManager.submitNewAgentTaskFromUI(
            promptWithAttachments(trimmedPrompt, attachments: attachments),
            source: "open_clicky_panel_ask"
        )
        selectedTab = .agents
        notifyPanelSizeChanged()
    }

    private func submitQuickPromptFromKeyboard() {
        guard shouldAcceptKeyboardSubmit() else { return }
        submitQuickPrompt()
    }

    private func submitQuickPrompt() {
        switch quickPromptMode {
        case .ask:
            submitQuickAskPrompt()
        case .agent:
            submitQuickAgentPrompt()
        case .chat:
            submitQuickChatPrompt()
        }
    }

    private func submitQuickChatPrompt() {
        let trimmedPrompt = quickPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = quickPromptAttachments
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else {
            notifyPanelSizeChanged()
            return
        }

        quickPrompt = ""
        quickPromptAttachments.removeAll()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            isCompactChatExpanded = true
        }
        companionManager.submitHomeChatPromptFromUI(
            promptWithAttachments(trimmedPrompt, attachments: attachments),
            source: "open_clicky_panel_chat"
        )
        notifyPanelSizeChanged()
    }

    private func submitQuickAgentPrompt() {
        let trimmedPrompt = quickPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = quickPromptAttachments
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else {
            selectedTab = .agents
            notifyPanelSizeChanged()
            return
        }

        quickPrompt = ""
        quickPromptAttachments.removeAll()
        companionManager.submitNewAgentTaskFromUI(
            promptWithAttachments(trimmedPrompt, attachments: attachments),
            source: "open_clicky_panel_agent"
        )
        selectedTab = .agents
        notifyPanelSizeChanged()
    }

    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.black.opacity(0.34))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(DS.Colors.accentText.opacity(0.52), style: StrokeStyle(lineWidth: 1.1, dash: [6, 5]))
            )
            .overlay(
                HStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.folder")
                        .font(panelUIFont(size: 15, weight: .heavy))
                        .foregroundColor(DS.Colors.accentText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Drop images or docs")
                            .font(panelUIFont(size: 11, weight: .heavy))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("OpenClicky will attach them before sending")
                            .font(panelUIFont(size: 9, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .padding(.horizontal, 12)
            )
    }

    private func attachmentChipRow(attachments: [PanelDraftAttachment], remove: @escaping (PanelDraftAttachment) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 7) {
                        Image(systemName: attachment.systemImage)
                            .font(appUIFont(size: max(10, subtextFontSize), weight: .heavy))
                            .foregroundColor(attachment.kind == .image ? DS.Colors.accentText : DS.Colors.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.chipTitle)
                                .font(appUIFont(size: max(10, subtextFontSize), weight: .heavy))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(attachment.displayName)
                                .font(appUIFont(size: max(8, subtextFontSize - 3), weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                        }
                        Button(action: { remove(attachment) }) {
                            Image(systemName: "xmark")
                                .font(panelUIFont(size: 8, weight: .heavy))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
                        .help("Remove attachment")
                    }
                    .padding(.leading, max(8, subtextFontSize * 0.72))
                    .padding(.trailing, max(7, subtextFontSize * 0.64))
                    .padding(.vertical, max(6, subtextFontSize * 0.50))
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.085)))
                    .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.13), lineWidth: 0.6))
                }
            }
        }
    }

    private func handlePanelAttachmentDrop(_ providers: [NSItemProvider]) -> Bool {
        if selectedTab == .agents, expandedAgentSessionID != nil {
            return handleAttachmentDrop(providers) { url, kind in
                addExpandedAgentAttachment(url, forcedKind: kind)
            }
        }

        if selectedTab != .home {
            selectedTab = .home
        }

        return handleAttachmentDrop(providers) { url, kind in
            addQuickPromptAttachment(url, forcedKind: kind)
        }
    }

    private func handleAttachmentDrop(
        _ providers: [NSItemProvider],
        addAttachment: @escaping @MainActor (URL, PanelDraftAttachment.AttachmentKind?) -> Void
    ) -> Bool {
        var acceptedDrop = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                acceptedDrop = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = Self.fileURL(from: item) else { return }
                    Task { @MainActor in
                        addAttachment(url, nil)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                acceptedDrop = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let url = Self.persistDroppedImage(data) else { return }
                    Task { @MainActor in
                        addAttachment(url, .image)
                    }
                }
            }
        }

        return acceptedDrop
    }

    private func addQuickPromptAttachment(_ url: URL, forcedKind: PanelDraftAttachment.AttachmentKind? = nil) {
        let standardizedURL = url.standardizedFileURL
        guard quickPromptAttachments.contains(where: { $0.url.standardizedFileURL == standardizedURL }) == false else { return }
        let kind = forcedKind ?? Self.attachmentKind(for: standardizedURL)
        quickPromptAttachments.append(PanelDraftAttachment(url: standardizedURL, kind: kind))
    }

    private func addExpandedAgentAttachment(_ url: URL, forcedKind: PanelDraftAttachment.AttachmentKind? = nil) {
        let standardizedURL = url.standardizedFileURL
        guard expandedAgentAttachments.contains(where: { $0.url.standardizedFileURL == standardizedURL }) == false else { return }
        let kind = forcedKind ?? Self.attachmentKind(for: standardizedURL)
        expandedAgentAttachments.append(PanelDraftAttachment(url: standardizedURL, kind: kind))
    }

    private func removeQuickPromptAttachment(_ attachment: PanelDraftAttachment) {
        quickPromptAttachments.removeAll { $0.id == attachment.id }
    }

    private func removeExpandedAgentAttachment(_ attachment: PanelDraftAttachment) {
        expandedAgentAttachments.removeAll { $0.id == attachment.id }
    }

    private func promptWithAttachments(_ prompt: String, attachments: [PanelDraftAttachment]) -> String {
        guard !attachments.isEmpty else { return prompt }

        let request = prompt.isEmpty ? "Please review the attached file(s)." : prompt
        let attachmentLines = attachments.enumerated().map { index, attachment in
            "\(index + 1). \(attachment.kindLabel): \(attachment.url.path)"
        }.joined(separator: "\n")

        return """
        \(request)

        OpenClicky panel attachments:
        These attachments are task context/reference material. Use them to understand and complete the request; do not treat them as files the user is asking you to find or show back unless the request explicitly says so.
        \(attachmentLines)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var supportedAttachmentDropTypes: [String] {
        [
            UTType.fileURL.identifier,
            UTType.image.identifier,
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.pdf.identifier
        ]
    }

    nonisolated private static func fileURL(from item: Any?) -> URL? {
        if let url = item as? URL {
            return url.isFileURL ? url.standardizedFileURL : nil
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)?.standardizedFileURL
        }
        if let data = item as? NSData {
            return URL(dataRepresentation: data as Data, relativeTo: nil)?.standardizedFileURL
        }
        if let string = item as? String {
            return URL(string: string)?.standardizedFileURL
        }
        return nil
    }

    private static func attachmentKind(for url: URL) -> PanelDraftAttachment.AttachmentKind {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .image) {
            return .image
        }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            return .image
        }

        return .document
    }

    nonisolated private static func persistDroppedImage(_ data: Data) -> URL? {
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenClicky/AgentMode/DroppedAttachments", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("panel-image-\(UUID().uuidString).png", isDirectory: false)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func refreshGogStatus() async {
        gogStatus = await OpenClickyGogCLIStatusResolver.refresh()
        hasLoadedGogStatus = true
    }

    private func notifyPanelSizeChanged() {
        NotificationCenter.default.post(
            name: .clickyPanelContentSizeDidChange,
            object: nil,
            userInfo: ["preferredPanelHeight": preferredPanelHeightForSelectedTab]
        )
    }

    private func focusQuickPromptIfHome() {
        guard selectedTab == .home else { return }
        DispatchQueue.main.async {
            isQuickPromptFocused = true
        }
    }

    private func focusExpandedAgentPromptIfNeeded() {
        guard selectedTab == .agents, expandedAgentSessionID != nil else { return }
        DispatchQueue.main.async {
            isExpandedAgentPromptFocused = true
        }
    }

    private func agentStatusColor(_ status: CodexAgentSessionStatus) -> Color {
        switch status {
        case .stopped:
            return DS.Colors.textTertiary
        case .starting:
            return .orange
        case .ready:
            return .green
        case .running:
            return DS.Colors.accentText
        case .failed:
            return DS.Colors.destructive
        }
    }
}

private enum OpenClickyAgentSessionFilter: String, CaseIterable, Identifiable {
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
            return !isArchived && session.progressStage == .completed
        case .archived:
            return isArchived
        case .all:
            return true
        }
    }
}

private enum OpenClickyAgentPanelSelection: String, Equatable {
    case sessions
    case specialists
}

private enum OpenClickyNotchTab: String, CaseIterable, Identifiable {
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

private enum OpenClickyQuickPromptMode: Equatable {
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

private struct OpenClickyNotchConnectionRow: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let state: OpenClickyNotchConnectionState
    let systemImageName: String
}

private enum OpenClickyNotchConnectionState: Equatable {
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

private struct OpenClickyPanelTypography {
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


private struct OpenClickyNotchHeroCard<Content: View>: View {
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.userAppTitleFontSizeDefaultsKey) private var appTitleFontSize = 26.0
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0

    private var typography: OpenClickyPanelTypography {
        OpenClickyPanelTypography(
            fontRawValue: appFontRawValue,
            boldTextEnabled: appBoldTextEnabled,
            titleFontSize: CGFloat(appTitleFontSize),
            bodyFontSize: CGFloat(appBodyFontSize),
            subtextFontSize: CGFloat(appSubtextFontSize)
        )
    }

    let title: String
    let subtitle: String
    let systemImageName: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                    Image(systemName: systemImageName)
                        .font(typography.font(size: 18, weight: .black))
                        .foregroundColor(accent)
                        .frame(width: 38, height: 38)
                    .background(Circle().fill(accent.opacity(0.15)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(typography.font(size: 15, weight: .black))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle)
                        .font(typography.font(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.12), Color.white.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct OpenClickyNotchMetricCard: View {
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.userAppTitleFontSizeDefaultsKey) private var appTitleFontSize = 26.0
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0

    private var typography: OpenClickyPanelTypography {
        OpenClickyPanelTypography(
            fontRawValue: appFontRawValue,
            boldTextEnabled: appBoldTextEnabled,
            titleFontSize: CGFloat(appTitleFontSize),
            bodyFontSize: CGFloat(appBodyFontSize),
            subtextFontSize: CGFloat(appSubtextFontSize)
        )
    }

    let title: String
    let value: String
    let detail: String
    let color: Color
    let systemImageName: String
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImageName)
                    .font(typography.font(size: 13, weight: .black))
                    .foregroundColor(isSelected ? .white : color)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(color.opacity(isSelected ? 0.92 : 0.13)))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value)
                            .font(typography.font(size: 16, weight: .black))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(title)
                            .font(typography.font(size: 9, weight: .black))
                            .foregroundColor(DS.Colors.textTertiary)
                            .textCase(.uppercase)
                            .lineLimit(1)
                    }
                    Text(detail)
                        .font(typography.font(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? color.opacity(0.14) : Color.white.opacity(0.052))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? color.opacity(0.50) : color.opacity(0.18), lineWidth: isSelected ? 1.2 : 1)
        )
    }
}

private struct OpenClickyRunningAgentIndicator: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 4.5, height: 4.5)
                    .scaleEffect(isAnimating ? 1.0 : 0.55)
                    .opacity(isAnimating ? 1.0 : 0.45)
                    .animation(
                        .easeInOut(duration: 0.54)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.13),
                        value: isAnimating
                    )
            }
        }
        .frame(width: 18, height: 10)
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
        .accessibilityLabel("Running")
    }
}

private struct OpenClickyNotchEmptyState: View {
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.userAppTitleFontSizeDefaultsKey) private var appTitleFontSize = 26.0
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    @AppStorage(AppBundleConfiguration.userAppLineSpacingDefaultsKey) private var appLineSpacing = 2.0

    private var typography: OpenClickyPanelTypography {
        OpenClickyPanelTypography(
            fontRawValue: appFontRawValue,
            boldTextEnabled: appBoldTextEnabled,
            titleFontSize: CGFloat(appTitleFontSize),
            bodyFontSize: CGFloat(appBodyFontSize),
            subtextFontSize: CGFloat(appSubtextFontSize)
        )
    }

    let systemImageName: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImageName)
                .font(typography.font(size: 22, weight: .heavy))
                .foregroundColor(DS.Colors.textSecondary)
            Text(title)
                .font(typography.font(size: 12, weight: .heavy))
                .foregroundColor(DS.Colors.textPrimary)
            Text(subtitle)
                .font(typography.font(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(CGFloat(appLineSpacing))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
