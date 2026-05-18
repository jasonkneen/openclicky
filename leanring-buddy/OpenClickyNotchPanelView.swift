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
    @ObservedObject private var petLibrary = ClickyBuddyPetLibrary.shared
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(ClickyCursorAvatarStyle.userDefaultsKey) private var avatarStyleRawValue = ClickyCursorAvatarStyle.default.storageValue
    @AppStorage(ClickyCursorAvatarSizePreference.userDefaultsKey) private var cursorAvatarSizeScale = ClickyCursorAvatarSizePreference.defaultScale
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
    @State private var isCompactChatExpanded = false
    @State private var expandedAgentSessionID: UUID?
    @State private var expandedAgentPrompt: String = ""
    @State private var lastKeyboardSubmitAt: Date = .distantPast
    @State private var agentPanelSelection: OpenClickyAgentPanelSelection = .sessions
    @State private var agentSessionFilter: OpenClickyAgentSessionFilter = .active
    @State private var expandedAgentAttachments: [PanelDraftAttachment] = []
    @State private var isExpandedAgentDropTargeted = false
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
            agentSessionFilter.includes(session: session, archivedSessionIDs: companionManager.archivedSessionIDs)
        }.sorted { leftSession, rightSession in
            if leftSession.latestActivityDate != rightSession.latestActivityDate {
                return leftSession.latestActivityDate > rightSession.latestActivityDate
            }
            return leftSession.title.localizedStandardCompare(rightSession.title) == .orderedAscending
        }
    }

    private var compactChatEntries: [CodexTranscriptEntry] {
        let visibleEntries = companionManager.codexAgentSession.entries.compactMap { entry -> CodexTranscriptEntry? in
            guard entry.role != .command else { return nil }
            var displayEntry = entry
            displayEntry.text = compactChatDisplayText(from: entry.text)
            return displayEntry.text.isEmpty ? nil : displayEntry
        }
        return Array(visibleEntries.suffix(6))
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
                detail: "\(companionManager.codexAgentSessions.count) sessions · \(agentStore.agents.count) specialist agents · model \(companionManager.codexAgentSession.model)",
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
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            mainSurface
        }
        .frame(minWidth: 356, maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.clear)
        .sheet(isPresented: $isShowingHatchSheet) {
            hatchPetSheet
        }
        .onAppear {
            focusQuickPromptIfHome()
            focusExpandedAgentPromptIfNeeded()
        }
        .task {
            await refreshGogStatus()
            focusQuickPromptIfHome()
            focusExpandedAgentPromptIfNeeded()
        }
        .onChange(of: selectedTab) { _ in
            focusQuickPromptIfHome()
            focusExpandedAgentPromptIfNeeded()
            notifyPanelSizeChanged()
        }
        .onChange(of: quickPromptMode) { _ in
            notifyPanelSizeChanged()
        }
        .onChange(of: quickPromptAttachments.count) { _ in
            notifyPanelSizeChanged()
        }
        .onChange(of: expandedAgentAttachments.count) { _ in
            notifyPanelSizeChanged()
        }
        .onChange(of: companionManager.codexAgentSession.entries.count) { _ in
            guard quickPromptMode == .chat else { return }
            notifyPanelSizeChanged()
        }
        .onChange(of: companionManager.codexAgentSession.isTurnActiveForChatQueue) { _ in
            guard quickPromptMode == .chat else { return }
            notifyPanelSizeChanged()
        }
        .onChange(of: expandedAgentSessionID) { _ in
            focusExpandedAgentPromptIfNeeded()
            notifyPanelSizeChanged()
        }
        .onChange(of: agentSessionFilter) { _ in
            expandedAgentSessionID = nil
            notifyPanelSizeChanged()
        }
        .onChange(of: gogStatus) { _ in
            notifyPanelSizeChanged()
        }
    }

    private var mainSurface: some View {
        VStack(spacing: 12) {
            tabStrip

            tabContent
                .id(selectedTab)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.spring(response: 0.24, dampingFraction: 0.90), value: selectedTab)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DS.Colors.surface1.opacity(0.98), Color.black.opacity(0.96)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                )
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 28)
                .padding(.top, 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.55), radius: 30, x: 0, y: 22)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: quickPromptMode)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isCompactChatExpanded)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: companionManager.codexAgentSession.entries.count)
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
        HStack(spacing: 8) {
            statusPill(
                title: activeVoiceLabel,
                systemImageName: activeVoiceIcon,
                color: activeVoiceAccent
            )
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
            statusPill(
                title: companionManager.allPermissionsGranted ? "Perms OK" : "Needs perms",
                systemImageName: companionManager.allPermissionsGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                color: companionManager.allPermissionsGranted ? .green : .orange
            )
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(OpenClickyNotchTab.primaryTabs) { tab in
                Button {
                    selectPrimaryTab(tab)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImageName)
                            .font(.system(size: 10, weight: .heavy))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .foregroundColor(selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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
                }
                .buttonStyle(.plain)
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
        .frame(height: 28)
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
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 28, height: 28)
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
    }

    private var homeTab: some View {
        VStack(spacing: 12) {
            OpenClickyNotchHeroCard(
                title: quickPromptMode.title,
                subtitle: quickPromptMode.subtitle,
                systemImageName: quickPromptMode.systemImageName,
                accent: DS.Colors.accentText
            ) {
                VStack(spacing: 9) {
                    quickPromptField
                    if quickPromptMode == .chat && isCompactChatExpanded {
                        compactChatPane
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    HStack(spacing: 8) {
                        quickPromptModeButton(.ask)
                        quickPromptModeButton(.agent)
                        quickPromptModeButton(.chat)
                    }
                }
            }

            topStatusRail
        }
    }

    private var agentsTab: some View {
        VStack(spacing: 8) {
            agentPanelSelector

            switch agentPanelSelection {
            case .sessions:
                agentSessionsPanel
            case .specialists:
                specialistAgentGrid
            }
        }
    }

    private var agentPanelSelector: some View {
        HStack(spacing: 8) {
            agentPanelSelectorButton(
                selection: .sessions,
                title: "Sessions",
                value: "\(companionManager.codexAgentSessions.count)",
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
        VStack(spacing: 8) {
            if visibleAgentSessions.isEmpty {
                OpenClickyNotchEmptyState(
                    systemImageName: agentSessionFilter.emptyStateSystemImageName,
                    title: agentSessionFilter.emptyStateTitle,
                    subtitle: agentSessionFilter.emptyStateSubtitle
                )
            } else {
                agentSessionScrollView
            }

            agentsFooter
        }
    }

    private var agentSessionScrollView: some View {
        let maxHeight: CGFloat = expandedAgentSessionID == nil ? 224 : 430

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                agentSessionRows
            }
            .frame(maxHeight: maxHeight, alignment: .top)
            .onChange(of: expandedAgentSessionID) { sessionID in
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
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(.purple.opacity(0.9))
                Text("Specialist agents")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 0)
                Text("Tap to start")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if agentStore.agents.isEmpty {
                Text("No specialist agents are installed yet.")
                    .font(.system(size: 10, weight: .semibold))
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
                        .font(.system(size: 12, weight: .black))
                        .foregroundColor(accent)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.metadata.displayName)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(agent.metadata.description.isEmpty ? agent.slug : agent.metadata.description)
                        .font(.system(size: 9, weight: .medium))
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
            filter.includes(session: session, archivedSessionIDs: companionManager.archivedSessionIDs)
        }.count

        return Button {
            agentSessionFilter = filter
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.systemImageName)
                    .font(.system(size: 10, weight: .black))
                Text("\(count)")
                    .font(.system(size: 9, weight: .heavy))
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

    private func agentUtilityIconButton(systemImageName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: 11, weight: .black))
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
        VStack(spacing: 10) {
            OpenClickyNotchEmptyState(
                systemImageName: "point.3.connected.trianglepath.dotted",
                title: "Connections stay local",
                subtitle: "Use Agent Mode skills for Notion, GitHub, mail, browser, files, and app workflows. No hosted sync required."
            )
            primaryActionButton(title: "Open settings", systemImageName: "gearshape.fill") {
                companionManager.showSettingsWindow()
            }
        }
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                TextField(quickPromptAttachments.isEmpty ? quickPromptMode.placeholder : "Ask about the attachment…", text: $quickPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isQuickPromptFocused)
                    .submitLabel(.send)
                    .onSubmit { submitQuickPromptFromKeyboard() }
                    .onKeyPress(.return) {
                        submitQuickPromptFromKeyboard()
                        return .handled
                    }
                Button(action: submitQuickPrompt) {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 10, weight: .black))
                        Text("Send")
                            .font(.system(size: 11, weight: .heavy))
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
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Type a message and Send; this panel expands into the active OpenClicky chat without opening the separate HUD.")
                                .font(.system(size: 10, weight: .semibold))
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

                    if companionManager.codexAgentSession.isTurnActiveForChatQueue {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.72)
                            Text(companionManager.codexAgentSession.progressStage.label)
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
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
            .onChange(of: companionManager.codexAgentSession.entries.count) { _ in
                let targetID = compactChatEntries.last?.id ?? (companionManager.codexAgentSession.isTurnActiveForChatQueue ? "compact-chat-status" : nil)
                guard let targetID else { return }
                withAnimation(.easeOut(duration: 0.18)) {
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
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(compactChatRoleColor(for: entry.role))
                Text(entry.text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(compactChatBubbleColor(for: entry.role)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
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
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button(action: { presentHatchSheet() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Hatch new")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
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
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(Int((cursorAvatarSizeScale * 100).rounded()))%")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
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
                .font(.system(size: 12, weight: .heavy))
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Hatch")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(width: 62, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.Colors.borderSubtle, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])))
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 14, weight: .semibold))
            Text("Launches an Agent Mode hatch-pet session.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
            TextField("Name", text: $hatchPetName)
                .textFieldStyle(.roundedBorder)
            TextField("Description optional", text: $hatchPetDescription)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isShowingHatchSheet = false }
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
                        .font(.system(size: 9, weight: .heavy))
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
        return VStack(spacing: 0) {
            Button {
                companionManager.selectCodexAgentSession(session.id)
                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                    expandedAgentSessionID = isExpanded ? nil : session.id
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(agentStatusColor(session.status))
                        .frame(width: 8, height: 8)
                        .shadow(color: agentStatusColor(session.status).opacity(0.7), radius: 5, x: 0, y: 0)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.title)
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(session.status.label)
                                .font(.system(size: 8, weight: .black))
                                .foregroundColor(agentStatusColor(session.status))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule(style: .continuous).fill(agentStatusColor(session.status).opacity(0.14)))
                        }

                        Text(session.latestActivityDisplaySummary ?? session.statusSummaryLine)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(isExpanded ? DS.Colors.accentText : DS.Colors.textTertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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

    private func expandedAgentConversation(for session: CodexAgentSession) -> some View {
        let entries = agentConversationEntries(for: session)
        return VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if entries.isEmpty {
                            Text("No conversation yet. Send a follow-up to talk to this OpenClicky task.")
                                .font(.system(size: 10, weight: .semibold))
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

                        if session.isTurnActiveForChatQueue {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.72)
                                Text(session.progressStage.label)
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.055)))
                            .id("\(session.id.uuidString)-agent-status")
                        }
                    }
                    .padding(9)
                }
                .frame(maxHeight: 170)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.22)))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .onChange(of: session.entries.count) { _ in
                    let targetID = entries.last?.id ?? (session.isTurnActiveForChatQueue ? "\(session.id.uuidString)-agent-status" : nil)
                    guard let targetID else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(targetID, anchor: .bottom)
                    }
                    notifyPanelSizeChanged()
                }
                .onChange(of: session.isTurnActiveForChatQueue) { _ in
                    notifyPanelSizeChanged()
                }
            }

            agentReplyField(for: session)
        }
    }

    private func agentReplyField(for session: CodexAgentSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !expandedAgentAttachments.isEmpty {
                attachmentChipRow(attachments: expandedAgentAttachments, remove: removeExpandedAgentAttachment)
            }

            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                TextField(expandedAgentAttachments.isEmpty ? "Talk to this task…" : "Talk to this task about the attachment…", text: $expandedAgentPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isExpandedAgentPromptFocused)
                    .submitLabel(.send)
                    .onSubmit { submitExpandedAgentPromptFromKeyboard(to: session) }
                    .onKeyPress(.return) {
                        submitExpandedAgentPromptFromKeyboard(to: session)
                        return .handled
                    }
                Button {
                    submitExpandedAgentPrompt(to: session)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 10, weight: .black))
                        Text("Send")
                            .font(.system(size: 11, weight: .heavy))
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

    private func agentConversationEntries(for session: CodexAgentSession) -> [CodexTranscriptEntry] {
        let visibleEntries = session.entries.compactMap { entry -> CodexTranscriptEntry? in
            guard entry.role != .command else { return nil }
            var displayEntry = entry
            displayEntry.text = compactChatDisplayText(from: entry.text)
            return displayEntry.text.isEmpty ? nil : displayEntry
        }
        return Array(visibleEntries.suffix(6))
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
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(row.state.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(row.state.color.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(row.state.title)
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(row.state.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(row.state.color.opacity(0.14)))
                }
                Text(row.detail)
                    .font(.system(size: 10, weight: .medium))
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
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DS.Colors.accentText.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(detail)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.052)))
    }

    private func statusPill(title: String, systemImageName: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImageName)
                .font(.system(size: 9, weight: .heavy))
            Text(title)
                .font(.system(size: 9, weight: .heavy))
        }
        .foregroundColor(color)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(color.opacity(0.105)))
        .overlay(Capsule(style: .continuous).stroke(color.opacity(0.18), lineWidth: 1))
    }

    private func primaryActionButton(title: String, systemImageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImageName)
                    .font(.system(size: 10, weight: .black))
                Text(title)
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [DS.Colors.accent, DS.Colors.accentHover], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
        }
        .buttonStyle(.plain)
    }

    private func secondaryActionButton(title: String, systemImageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImageName)
                    .font(.system(size: 10, weight: .black))
                Text(title)
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func submitQuickAskPrompt() {
        let trimmedPrompt = quickPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = quickPromptAttachments
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else {
            companionManager.showQuickTextInputFromMenuBar()
            return
        }

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
        companionManager.submitNewAgentTaskFromUI(
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
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(DS.Colors.accentText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Drop images or docs")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("OpenClicky will attach them before sending")
                            .font(.system(size: 9, weight: .semibold))
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
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(attachment.kind == .image ? DS.Colors.accentText : DS.Colors.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.displayName)
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(attachment.kindLabel)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                        }
                        Button(action: { remove(attachment) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 7)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.085)))
                    .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.13), lineWidth: 0.6))
                }
            }
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

    private static func fileURL(from item: Any?) -> URL? {
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

    private static func persistDroppedImage(_ data: Data) -> URL? {
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
        NotificationCenter.default.post(name: .clickyPanelContentSizeDidChange, object: nil)
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

    func includes(session: CodexAgentSession, archivedSessionIDs: Set<UUID>) -> Bool {
        let isArchived = archivedSessionIDs.contains(session.id)
        switch self {
        case .active:
            return !isArchived
        case .running:
            return !isArchived && session.isTurnActiveForChatQueue
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

private struct OpenClickyNotchHeroCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImageName: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImageName)
                    .font(.system(size: 15, weight: .black))
                    .foregroundColor(accent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(accent.opacity(0.15)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            content
        }
        .padding(12)
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
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(isSelected ? .white : color)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(color.opacity(isSelected ? 0.92 : 0.13)))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value)
                            .font(.system(size: 16, weight: .black))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(title)
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(DS.Colors.textTertiary)
                            .textCase(.uppercase)
                            .lineLimit(1)
                    }
                    Text(detail)
                        .font(.system(size: 9, weight: .semibold))
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

private struct OpenClickyNotchEmptyState: View {
    let systemImageName: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImageName)
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(DS.Colors.textSecondary)
            Text(title)
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(DS.Colors.textPrimary)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
