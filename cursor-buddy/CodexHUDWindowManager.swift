import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

enum OpenClickyHUDLayout {
    static let width: CGFloat = 980
    static let height: CGFloat = 560
    static let minimumWidth: CGFloat = 720
    static let minimumHeight: CGFloat = 452
    static let cornerRadius: CGFloat = 24
    static let screenEdgePadding: CGFloat = 20
    static let preferredBottomMargin: CGFloat = 24
    static let fallbackMinimumDimension: CGFloat = 240
}

private final class OpenClickyHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class CodexHUDWindowManager: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var themeObserver: NSObjectProtocol?

    override init() {
        super.init()
        themeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshThemeAppearance()
            }
        }
    }

    deinit {
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Route the red traffic-light close through hide() so the panel
        // and its SwiftUI hosting view stay alive for the next show().
        Task { @MainActor in self.hide() }
        return false
    }

    func show(
        companionManager: CompanionManager,
        openMemory: @escaping () -> Void,
        prepareVoiceFollowUp: @escaping () -> Void
    ) {
        if panel == nil {
            panel = makePanel(
                companionManager: companionManager,
                openMemory: openMemory,
                prepareVoiceFollowUp: prepareVoiceFollowUp
            )
        } else if let panel, let hostingView = hudHostingView(in: panel) {
            hostingView.rootView = ChatWorkspaceView(
                companionManager: companionManager,
                openMemory: openMemory,
                prepareVoiceFollowUp: prepareVoiceFollowUp,
                dismiss: { [weak self] in self?.hide() }
            )
        }
        enforceMinimumSize()
        positionPanel()
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func destroy() {
        MiniChatPanelManager.shared.destroyAll()
        panel?.close()
        panel = nil
    }

    private func makePanel(
        companionManager: CompanionManager,
        openMemory: @escaping () -> Void,
        prepareVoiceFollowUp: @escaping () -> Void
    ) -> NSPanel {
        let hostingView = NSHostingView(
            rootView: ChatWorkspaceView(
                companionManager: companionManager,
                openMemory: openMemory,
                prepareVoiceFollowUp: prepareVoiceFollowUp,
                dismiss: { [weak self] in self?.hide() }
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = OpenClickyHUDLayout.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.autoresizingMask = [.width, .height]
        // Keep the HUD as an OpenClicky surface, not a standard app window:
        // the SwiftUI header owns close/actions, while the panel stays keyable
        // for typing without showing a titlebar or traffic lights.
        let panel = OpenClickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: OpenClickyHUDLayout.width, height: OpenClickyHUDLayout.height),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenClicky"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.hasShadow = true
        panel.minSize = NSSize(width: OpenClickyHUDLayout.minimumWidth, height: OpenClickyHUDLayout.minimumHeight)
        panel.contentMinSize = NSSize(width: OpenClickyHUDLayout.minimumWidth, height: OpenClickyHUDLayout.minimumHeight)
        let resizeContainer = OpenClickyHUDResizeContainerView(frame: NSRect(x: 0, y: 0, width: OpenClickyHUDLayout.width, height: OpenClickyHUDLayout.height))
        resizeContainer.autoresizingMask = [.width, .height]
        let glassBackdrop = OpenClickyLiquidGlassBackdropView(cornerRadius: OpenClickyHUDLayout.cornerRadius)
        glassBackdrop.frame = resizeContainer.bounds
        glassBackdrop.autoresizingMask = [.width, .height]
        glassBackdrop.configure(
            cornerRadius: OpenClickyHUDLayout.cornerRadius,
            roundsTopCorners: true,
            accentColor: OpenClickyNotchCaptureWindowManager.nsAccentColor(for: nil),
            strength: .expanded
        )
        resizeContainer.addSubview(glassBackdrop)
        resizeContainer.addSubview(hostingView)
        panel.contentView = resizeContainer
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let result = panel
        self.panel = result
        refreshThemeAppearance()
        return result
    }

    private func refreshThemeAppearance() {
        let theme = ClickyTheme.current
        let appearanceName: NSAppearance.Name?
        switch theme {
        case .system:
            appearanceName = nil
        case .light:
            appearanceName = .aqua
        case .dark:
            appearanceName = .darkAqua
        }
        
        if let appearanceName = appearanceName {
            panel?.appearance = NSAppearance(named: appearanceName)
        } else {
            panel?.appearance = nil
        }
    }

    private func enforceMinimumSize() {
        guard let panel else { return }
        guard let visibleFrame = visibleScreenFrame(for: panel) else { return }

        let availableWidth = availableDimension(for: visibleFrame.width)
        let availableHeight = availableDimension(for: visibleFrame.height)
        let minimumWidth = min(OpenClickyHUDLayout.minimumWidth, availableWidth)
        let minimumHeight = min(OpenClickyHUDLayout.minimumHeight, availableHeight)

        panel.minSize = NSSize(width: minimumWidth, height: minimumHeight)
        panel.contentMinSize = NSSize(width: minimumWidth, height: minimumHeight)

        let currentFrame = panel.frame
        let constrainedWidth = min(max(currentFrame.width, minimumWidth), availableWidth)
        let constrainedHeight = min(max(currentFrame.height, minimumHeight), availableHeight)

        guard constrainedWidth != currentFrame.width || constrainedHeight != currentFrame.height else { return }

        panel.setFrame(
            NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.maxY - constrainedHeight,
                width: constrainedWidth,
                height: constrainedHeight
            ),
            display: true
        )
    }

    private func positionPanel() {
        guard let panel else { return }
        guard let frame = visibleScreenFrame(for: panel) else { return }

        let edgePadding = OpenClickyHUDLayout.screenEdgePadding
        let size = panel.frame.size
        let minX = frame.minX + edgePadding
        let maxX = constrainedMaximumOrigin(maximumBoundary: frame.maxX, contentDimension: size.width, minimumOrigin: minX, edgePadding: edgePadding)
        let minY = frame.minY + edgePadding
        let maxY = constrainedMaximumOrigin(maximumBoundary: frame.maxY, contentDimension: size.height, minimumOrigin: minY, edgePadding: edgePadding)
        let preferredX = frame.midX - size.width / 2
        let preferredY = frame.minY + OpenClickyHUDLayout.preferredBottomMargin
        let x = min(max(preferredX, minX), maxX)
        let y = min(max(preferredY, minY), maxY)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func visibleScreenFrame(for fallbackPanel: NSPanel) -> NSRect? {
        let screen = NSScreen.screen(containingOrNearestTo: NSEvent.mouseLocation) ?? fallbackPanel.screen
        return screen?.visibleFrame
    }

    private func availableDimension(for visibleDimension: CGFloat) -> CGFloat {
        max(
            OpenClickyHUDLayout.fallbackMinimumDimension,
            visibleDimension - (OpenClickyHUDLayout.screenEdgePadding * 2)
        )
    }

    private func constrainedMaximumOrigin(
        maximumBoundary: CGFloat,
        contentDimension: CGFloat,
        minimumOrigin: CGFloat,
        edgePadding: CGFloat
    ) -> CGFloat {
        max(minimumOrigin, maximumBoundary - contentDimension - edgePadding)
    }

    private func hudHostingView(in panel: NSPanel) -> NSHostingView<ChatWorkspaceView>? {
        OpenClickyLiquidGlassWindowSurface.hostingView(in: panel)
    }
}

struct CodexHUDView: View {
    private struct HUDDraftAttachment: Identifiable, Equatable {
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

        var subtitle: String {
            url.deletingLastPathComponent().path
        }

        var systemImage: String {
            switch kind {
            case .image: return "photo"
            case .document: return "doc.text"
            }
        }
    }

    private struct TranscriptDisplayItem: Identifiable {
        enum Payload {
            case entry(CodexTranscriptEntry)
            case commandSummary(chips: [(label: String, count: Int)], entries: [CodexTranscriptEntry])
        }

        let id: String
        let payload: Payload
    }

    enum ChromeMode { case standalone, embedded }
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var agentStore = OpenClickyAgentStore.shared
    @ObservedObject private var skillDiscoveryStore = OpenClickySkillDiscoveryStore.shared
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.userAppLineSpacingDefaultsKey) private var appLineSpacing = 2.0
    @AppStorage(AppBundleConfiguration.userAppTitleFontSizeDefaultsKey) private var appTitleFontSize = 26.0
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    var openMemory: () -> Void
    var prepareVoiceFollowUp: () -> Void
    var close: () -> Void
    var chromeMode: ChromeMode = .standalone
    @State private var prompt = ""
    @State private var expandedCommandGroupIDs: Set<String> = []
    @State private var droppedAttachments: [HUDDraftAttachment] = []
    @State private var isDropTargeted = false
    @State private var timestampNow = Date()
    @State private var pendingStopAgentSessionID: UUID?

    private var session: CodexAgentSession {
        companionManager.codexAgentSession
    }

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private var titleFontSize: CGFloat { CGFloat(appTitleFontSize) }
    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }
    private var appTextLineSpacing: CGFloat { CGFloat(appLineSpacing) }

    private var promptAutocompleteOptions: [OpenClickyPromptAutocompleteOption] {
        OpenClickyPromptAutocomplete.options(
            for: prompt,
            agents: agentStore.agents,
            skillSuggestions: skillDiscoveryStore.suggestions
        )
    }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        guard appBoldTextEnabled else { return weight }
        switch weight {
        case .regular, .medium:
            return .semibold
        case .semibold:
            return .bold
        default:
            return weight
        }
    }

    private var activeDockItem: ClickyAgentDockItem? {
        companionManager.agentDockItems.last { $0.sessionID == session.id }
    }

    private var activeAgentSessions: [CodexAgentSession] {
        companionManager.codexAgentSessions.filter { agentSession in
            !companionManager.archivedSessionIDs.contains(agentSession.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if chromeMode == .standalone {
                header
                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.horizontal, 14)
            }
            agentTeamStrip
                .padding(.top, chromeMode == .standalone ? 10 : 0)
            if !session.queuedFollowUpPrompts.isEmpty {
                queuedFollowUpDrawer
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }
            transcript
                .padding(.horizontal, chromeMode == .standalone ? 14 : 0)
                .padding(.top, chromeMode == .standalone ? 10 : 6)
                .padding(.bottom, chromeMode == .standalone ? 10 : 14)
            if chromeMode == .standalone {
                composer
            }
        }
        .frame(
            minWidth: OpenClickyHUDLayout.minimumWidth,
            idealWidth: OpenClickyHUDLayout.width,
            maxWidth: .infinity,
            minHeight: OpenClickyHUDLayout.minimumHeight,
            idealHeight: OpenClickyHUDLayout.height,
            maxHeight: .infinity
        )
        .background(
            Group {
                if chromeMode == .standalone {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(DS.Colors.background)
                } else {
                    DS.Colors.background
                }
            }
        )
        .overlay(
            Group {
                if chromeMode == .standalone {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isDropTargeted ? DS.Colors.accentText.opacity(0.55) : DS.Colors.borderSubtle, lineWidth: isDropTargeted ? 1.4 : 1)
                }
            }
        )
        .overlay(alignment: .center) {
            if isDropTargeted {
                dropTargetOverlay
                    .padding(18)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier],
            isTargeted: $isDropTargeted,
            perform: { providers in
                chromeMode == .standalone ? handleDrop(providers) : false
            }
        )
        .confirmationDialog(
            "Stop this running OpenClicky task?",
            isPresented: Binding(
                get: { pendingStopAgentSessionID != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingStopAgentSessionID = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop task", role: .destructive) {
                confirmStopPendingAgentSession()
            }
            Button("Keep running", role: .cancel) {
                pendingStopAgentSessionID = nil
            }
        } message: {
            Text("Running tasks stay active until you stop them, so OpenClicky will not archive or close this task while it is still working.")
        }
        .animation(.none, value: selectedAccentThemeID)
        .animation(.easeOut(duration: DS.Animation.fast), value: isDropTargeted)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            timestampNow = now
        }
    }

    private func isAgentSessionRunning(_ agentSession: CodexAgentSession) -> Bool {
        switch agentSession.status {
        case .starting, .running:
            return true
        case .stopped, .ready, .failed:
            return agentSession.isTurnActiveForChatQueue
        }
    }

    private func confirmStopPendingAgentSession() {
        guard let sessionID = pendingStopAgentSessionID else { return }
        pendingStopAgentSessionID = nil
        companionManager.selectCodexAgentSession(sessionID)
        companionManager.stopCodexAgentSession(sessionID, reason: "agent_hud_stop")
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("OpenClicky")
                    .font(appUIFont(size: max(14, titleFontSize * 0.54), weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Circle()
                    .fill(sessionStatusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: sessionStatusColor.opacity(0.55), radius: 3.5)
            }

            Spacer()

            Text(headerSubtitle)
                .font(appUIFont(size: max(11, subtextFontSize), weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)

            HUDHeaderPill(
                title: sessionStatusLabel,
                systemImageName: session.isTurnActiveForChatQueue ? "sparkles" : "terminal.fill",
                color: session.isTurnActiveForChatQueue ? DS.Colors.accentText : sessionStatusColor
            )
            HUDHeaderPill(
                title: "\(activeAgentSessions.count) active",
                systemImageName: "rectangle.stack.fill",
                color: DS.Colors.textSecondary
            )
            iconButton(systemName: "books.vertical", helpText: "Memory", action: openMemory)
            iconButton(systemName: "bolt.fill", helpText: "Warm up", action: { session.warmUp() })
            closeDialogButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var closeDialogButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(appUIFont(size: max(13, subtextFontSize + 2), weight: .bold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(DS.Colors.surface2.opacity(0.92)))
        .overlay(Circle().stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .fixedSize()
        .layoutPriority(3)
        .help("Close OpenClicky HUD")
        .accessibilityLabel("Close OpenClicky HUD")
    }

    private var headerSubtitle: String {
        if session.isTurnActiveForChatQueue {
            return session.latestActivityDisplaySummary ?? session.latestActivitySummary ?? "Working on the current task"
        }
        if session.canResumeAfterRelaunch {
            return "Needs resuming after relaunch"
        }
        return "Agent HUD and task chat"
    }

    private var sessionStatusLabel: String {
        session.canResumeAfterRelaunch ? "Resume" : session.status.label
    }

    private var sessionStatusColor: Color {
        if session.canResumeAfterRelaunch {
            return DS.Colors.warning
        }
        switch session.status {
        case .starting, .running: return DS.Colors.accentText
        case .ready: return DS.Colors.success
        case .failed: return DS.Colors.destructiveText
        case .stopped: return DS.Colors.textTertiary
        }
    }

    private var agentTeamStrip: some View {
        HStack(spacing: 9) {
            Label("Active", systemImage: "rectangle.stack.fill")
                .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .bold))
                .foregroundColor(DS.Colors.textTertiary)
                .labelStyle(.titleAndIcon)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(activeAgentSessions) { agentSession in
                        HUDFloatingAgentButton(
                            session: agentSession,
                            isSelected: agentSession.id == companionManager.activeCodexAgentSessionID,
                            select: {
                                companionManager.selectCodexAgentSession(agentSession.id)
                            },
                            close: {
                                if isAgentSessionRunning(agentSession) {
                                    pendingStopAgentSessionID = agentSession.id
                                } else if agentSession.canResumeAfterRelaunch {
                                    companionManager.selectCodexAgentSession(agentSession.id)
                                    agentSession.resumeInterruptedTaskAfterRelaunch()
                                } else {
                                    companionManager.archiveSession(agentSession.id)
                                }
                            }
                        )
                    }

                    Button(action: {
                        companionManager.createAndSelectNewCodexAgentSession()
                    }) {
                        Label("New", systemImage: "plus.message.fill")
                            .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, max(11, subtextFontSize))
                            .padding(.vertical, max(8, subtextFontSize * 0.64))
                            .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .accessibilityLabel("Add agent")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
        )
        .padding(.horizontal, 14)
    }

    private var transcript: some View {
        let items = transcriptDisplayItems
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty {
                        emptyState
                    } else {
                        ForEach(items) { item in
                            transcriptRow(item)
                                .id(item.id)
                        }
                        if session.isTurnActiveForChatQueue {
                            reasoningStatusRow
                                .id("reasoning-status-\(session.id.uuidString)")
                        }
                    }
                }
                .padding(chromeMode == .standalone
                    ? EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
                    : EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
            }
            .background(
                Group {
                    if chromeMode == .standalone {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(DS.Colors.surface1)
                    }
                }
            )
            .overlay(
                Group {
                    if chromeMode == .standalone {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    }
                }
            )
            .onChange(of: session.entries.count) {
                if let id = session.entries.last?.id {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(appUIFont(size: max(14, subtextFontSize + 2), weight: .bold))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DS.Colors.accentSubtle))
            VStack(alignment: .leading, spacing: 3) {
                Text("Ask OpenClicky to inspect, edit, explain, or automate something.")
                    .font(appUIFont(size: max(13, bodyFontSize), weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Agent tasks use the bundled Codex runtime and the coding/actions model selected in settings.")
                    .font(appUIFont(size: max(11, subtextFontSize), weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func transcriptRow(_ entry: CodexTranscriptEntry) -> some View {
        transcriptRow(
            TranscriptDisplayItem(
                id: entry.id,
                payload: .entry(entry)
            )
        )
    }

    @ViewBuilder
    private func transcriptRow(_ item: TranscriptDisplayItem) -> some View {
        switch item.payload {
        case .entry(let entry):
            entryTranscriptRow(entry)
        case .commandSummary(let chips, let entries):
            commandSummaryRow(id: item.id, chips: chips, entries: entries)
        }
    }

    private func entryTranscriptRow(_ entry: CodexTranscriptEntry) -> some View {
        let isUser = entry.role == .user

        return HStack(alignment: .top, spacing: 0) {
            if isUser {
                Spacer(minLength: 42)
            }

            transcriptBubble(entry, isUser: isUser)
                .frame(maxWidth: 430, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 42)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func transcriptBubble(_ entry: CodexTranscriptEntry, isUser: Bool) -> some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label(for: entry.role))
                    .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .bold))
                    .foregroundColor(color(for: entry.role))
                Text(Self.relativeTimeString(from: entry.createdAt, now: timestampNow))
                    .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text(entry.text)
                .font(entry.role == .command
                    ? .system(size: max(10, bodyFontSize - 2), weight: .medium, design: .monospaced)
                    : appUIFont(size: max(12, bodyFontSize), weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .lineSpacing(appTextLineSpacing)
                .fixedSize(horizontal: false, vertical: true)

            let openableLinks = OpenClickyOpenableLinkExtractor.links(in: entry.text, limit: 2)
            if !openableLinks.isEmpty {
                HStack(spacing: 6) {
                    ForEach(openableLinks) { link in
                        Button {
                            NSWorkspace.shared.open(link.url)
                        } label: {
                            Label(link.buttonTitle, systemImage: link.systemImageName)
                                .font(appUIFont(size: max(10, subtextFontSize), weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, max(8, subtextFontSize * 0.72))
                        .padding(.vertical, max(5, subtextFontSize * 0.44))
                        .background(Capsule().fill(DS.Colors.surface3))
                        .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
                        .pointerCursor()
                    }
                }
            }

            HStack(spacing: 6) {
                Button {
                    prompt = Self.replyDraft(for: entry)
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                        .font(appUIFont(size: max(9, subtextFontSize - 1), weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, max(7, subtextFontSize * 0.64))
                .padding(.vertical, max(4, subtextFontSize * 0.38))
                .background(Capsule(style: .continuous).fill(DS.Colors.surface3))
                .overlay(Capsule(style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
                .pointerCursor()
                .accessibilityLabel("Reply to \(label(for: entry.role).lowercased()) message")
            }
        }
        .padding(.horizontal, max(10, bodyFontSize * 0.86))
        .padding(.vertical, max(10, bodyFontSize * 0.72))
        .frame(maxWidth: 430, alignment: isUser ? .trailing : .leading)
        .background(
            RoundedRectangle(cornerRadius: max(13, bodyFontSize + 2), style: .continuous)
                .fill(background(for: entry.role))
        )
        .overlay(
            RoundedRectangle(cornerRadius: max(13, bodyFontSize + 2), style: .continuous)
                .stroke(isUser ? DS.Colors.accentText.opacity(0.24) : DS.Colors.borderSubtle, lineWidth: 0.8)
        )
    }

    private var reasoningStatusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            ClickyThinkingDots(tint: DS.Colors.accentText)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(reasoningStatusTitle)
                        .font(appUIFont(size: max(11, subtextFontSize), weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(Self.relativeTimeString(from: session.entries.last?.createdAt ?? Date(), now: timestampNow))
                        .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                if let latest = session.latestActivityDisplaySummary ?? session.latestActivitySummary {
                    Text(latest)
                        .font(appUIFont(size: max(11, subtextFontSize), weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reasoningStatusTitle: String {
        switch session.progressStage {
        case .planning:
            return "Reasoning"
        case .executing:
            return "Working"
        case .composing:
            return "Writing reply"
        case .starting:
            return "Starting"
        case .completed:
            return "Finishing"
        case .failed:
            return "Stopped"
        case .idle:
            return "Thinking"
        }
    }

    private func commandSummaryRow(
        id: String,
        chips: [(label: String, count: Int)],
        entries: [CodexTranscriptEntry]
    ) -> some View {
        let isExpanded = expandedCommandGroupIDs.contains(id)

        return VStack(alignment: .leading, spacing: 7) {
            toolChipRow(chips, isExpanded: isExpanded) {
                withAnimation(.easeOut(duration: 0.16)) {
                    if expandedCommandGroupIDs.contains(id) {
                        expandedCommandGroupIDs.remove(id)
                    } else {
                        expandedCommandGroupIDs.insert(id)
                    }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(entries) { entry in
                        Text(entry.text)
                            .font(.system(size: max(10, bodyFontSize - 3), weight: .medium, design: .monospaced))
                            .foregroundColor(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                            .lineSpacing(appTextLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(DS.Colors.surface2)
                            )
                    }
                }
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolChipRow(
        _ chips: [(label: String, count: Int)],
        isExpanded: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { pair in
                let chip = pair.element
                Button(action: toggle) {
                    HStack(spacing: 5) {
                        Text("\(chip.count)x \(chip.label)")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(appUIFont(size: max(8, subtextFontSize - 3), weight: .semibold))
                    }
                    .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, max(8, subtextFontSize * 0.72))
                    .padding(.vertical, max(4, subtextFontSize * 0.40))
                    .background(
                        Capsule(style: .continuous)
                            .fill(isExpanded ? DS.Colors.surface3 : DS.Colors.surface2)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(isExpanded ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(isExpanded ? "Collapse tool output" : "Expand tool output")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var queuedFollowUpDrawer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                Text("Queued follow-ups")
                    .font(appUIFont(size: max(11, subtextFontSize), weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("\(session.queuedFollowUpPrompts.count)")
                    .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, max(6, subtextFontSize * 0.58))
                    .padding(.vertical, max(3, subtextFontSize * 0.28))
                    .background(Capsule().fill(DS.Colors.surface2))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(session.queuedFollowUpPrompts.enumerated()), id: \.offset) { _, queuedPrompt in
                        HStack(spacing: 6) {
                            Text(queuedPrompt)
                                .font(appUIFont(size: max(11, bodyFontSize - 2), weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Button(action: { session.removeQueuedFollowUp(queuedPrompt) }) {
                                Image(systemName: "xmark")
                                    .font(appUIFont(size: max(8, subtextFontSize - 3), weight: .semibold))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .accessibilityLabel("Remove queued follow-up")
                        }
                        .padding(.horizontal, max(8, subtextFontSize * 0.72))
                        .padding(.vertical, max(5, subtextFontSize * 0.44))
                        .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
                        .overlay(Capsule(style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !droppedAttachments.isEmpty {
                attachmentChipRow
            }

            OpenClickyPromptAutocompletePanel(options: promptAutocompleteOptions) { option in
                OpenClickyPromptAutocomplete.apply(option, to: &prompt)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(droppedAttachments.isEmpty ? "Ask Chat..." : "Ask Chat about the attachment...", text: $prompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(appUIFont(size: max(12, bodyFontSize - 1), weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isDropTargeted ? DS.Colors.accentText.opacity(0.55) : DS.Colors.borderSubtle, lineWidth: isDropTargeted ? 1 : 0.8)
                    )
                    .onSubmit(send)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            return .ignored
                        }
                        send()
                        return .handled
                    }
                    .onKeyPress(.tab, phases: .down) { _ in
                        OpenClickyPromptAutocomplete.acceptFirstOption(
                            in: &prompt,
                            agents: agentStore.agents,
                            skillSuggestions: skillDiscoveryStore.suggestions
                        ) ? .handled : .ignored
                    }

                HUDRunButton(
                    canSend: canSend,
                    isRunning: session.isTurnActiveForChatQueue,
                    send: send,
                    stop: stopCurrentSession
                )
            }
        }
        .padding(10)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var attachmentChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(droppedAttachments) { attachment in
                    HStack(spacing: 7) {
                        Image(systemName: attachment.systemImage)
                            .font(appUIFont(size: max(10, subtextFontSize), weight: .bold))
                            .foregroundColor(attachment.kind == .image ? DS.Colors.accentText : DS.Colors.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.chipTitle)
                                .font(appUIFont(size: max(10, subtextFontSize), weight: .bold))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(attachment.displayName)
                                .font(appUIFont(size: max(8, subtextFontSize - 3), weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                        }
                        Button(action: { removeAttachment(attachment) }) {
                            Image(systemName: "xmark")
                                .font(appUIFont(size: max(8, subtextFontSize - 3), weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .accessibilityLabel("Remove attachment")
                    }
                    .padding(.leading, max(8, subtextFontSize * 0.72))
                    .padding(.trailing, max(7, subtextFontSize * 0.64))
                    .padding(.vertical, max(6, subtextFontSize * 0.50))
                    .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
                    .overlay(Capsule(style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.6))
                }
            }
        }
    }

    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(DS.Colors.background.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(DS.Colors.accentText.opacity(0.50), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
            )
            .overlay(
                VStack(spacing: 7) {
                    Image(systemName: "plus.rectangle.on.folder")
                        .font(appUIFont(size: max(22, bodyFontSize + 9), weight: .bold))
                        .foregroundColor(DS.Colors.accentText)
                    Text("Drop images or docs into OpenClicky")
                        .font(appUIFont(size: max(12, bodyFontSize - 1), weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("They’ll attach as chips before sending")
                        .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            )
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !droppedAttachments.isEmpty
    }

    private func send() {
        guard canSend else { return }
        let submitted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = droppedAttachments
        prompt = ""
        droppedAttachments.removeAll()
        companionManager.submitNewAgentTaskFromUI(
            promptWithAttachments(submitted, attachments: attachments),
            source: "chat_panel_prompt"
        )
    }


    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var acceptedDrop = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                acceptedDrop = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = Self.fileURL(from: item) else { return }
                    Task { @MainActor in
                        addAttachment(url)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                acceptedDrop = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let url = Self.persistDroppedImage(data) else { return }
                    Task { @MainActor in
                        addAttachment(url, forcedKind: .image)
                    }
                }
            }
        }

        return acceptedDrop
    }

    private func addAttachment(_ url: URL, forcedKind: HUDDraftAttachment.AttachmentKind? = nil) {
        let standardizedURL = url.standardizedFileURL
        guard droppedAttachments.contains(where: { $0.url.standardizedFileURL == standardizedURL }) == false else { return }
        let kind = forcedKind ?? Self.attachmentKind(for: standardizedURL)
        droppedAttachments.append(HUDDraftAttachment(url: standardizedURL, kind: kind))
    }

    private func removeAttachment(_ attachment: HUDDraftAttachment) {
        droppedAttachments.removeAll { $0.id == attachment.id }
    }

    private func promptWithAttachments(_ prompt: String, attachments: [HUDDraftAttachment]) -> String {
        guard !attachments.isEmpty else { return prompt }

        let request = prompt.isEmpty ? "Please review the attached file(s)." : prompt
        let attachmentLines = attachments.enumerated().map { index, attachment in
            "\(index + 1). \(attachment.kind == .image ? "Image" : "Document"): \(attachment.url.path)"
        }.joined(separator: "\n")

        return """
        \(request)

        OpenClicky chat attachments:
        \(attachmentLines)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fileURL(from item: Any?) -> URL? {
        if let url = item as? URL {
            return url.isFileURL ? url : nil
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

    private static func attachmentKind(for url: URL) -> HUDDraftAttachment.AttachmentKind {
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
            let url = directory.appendingPathComponent("chat-image-\(UUID().uuidString).png", isDirectory: false)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func stopCurrentSession() {
        if let item = activeDockItem {
            companionManager.stopAgentDockItem(item.id)
        } else {
            session.stop(reason: "chat_stop")
        }
    }

    private func iconButton(systemName: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(
            DSIconButtonStyle(
                size: 28,
                isDestructiveOnHover: systemName == "xmark",
                tooltipText: helpText,
                tooltipAlignment: .trailing
            )
        )
    }

    private func label(for role: CodexTranscriptEntry.Role) -> String {
        switch role {
        case .user: return "YOU"
        case .assistant: return "CLICKY"
        case .system: return "SYSTEM"
        case .command: return "COMMAND"
        case .plan: return "PLAN"
        }
    }

    private func color(for role: CodexTranscriptEntry.Role) -> Color {
        switch role {
        case .user: return DS.Colors.accentText
        case .assistant: return DS.Colors.textSecondary
        case .system: return DS.Colors.destructiveText
        case .command: return DS.Colors.warningText
        case .plan: return DS.Colors.info
        }
    }

    private func background(for role: CodexTranscriptEntry.Role) -> Color {
        switch role {
        case .user: return DS.Colors.accentSubtle
        case .assistant: return DS.Colors.surface2
        case .system: return DS.Colors.destructive.opacity(0.12)
        case .command: return DS.Colors.warning.opacity(0.12)
        case .plan: return DS.Colors.info.opacity(0.12)
        }
    }

    private func background(for item: TranscriptDisplayItem) -> Color {
        switch item.payload {
        case .entry(let entry):
            return background(for: entry.role)
        case .commandSummary:
            return DS.Colors.warning.opacity(0.12)
        }
    }

    private var transcriptDisplayItems: [TranscriptDisplayItem] {
        var items: [TranscriptDisplayItem] = []
        var currentCommandCounts: [String: Int] = [:]
        var currentCommandOrder: [String] = []
        var currentCommandEntries: [CodexTranscriptEntry] = []
        var currentCommandStartID: String?

        func flushCommandGroup() {
            guard let startID = currentCommandStartID, !currentCommandOrder.isEmpty else { return }
            let chips = currentCommandOrder.map { label in
                (label: label, count: currentCommandCounts[label] ?? 0)
            }
            items.append(
                TranscriptDisplayItem(
                    id: "command-group-\(startID)",
                    payload: .commandSummary(chips: chips, entries: currentCommandEntries)
                )
            )
            currentCommandCounts.removeAll(keepingCapacity: true)
            currentCommandOrder.removeAll(keepingCapacity: true)
            currentCommandEntries.removeAll(keepingCapacity: true)
            currentCommandStartID = nil
        }

        for entry in session.entries {
            if entry.role == .command {
                if currentCommandStartID == nil {
                    currentCommandStartID = entry.id
                }
                currentCommandEntries.append(entry)
                let label = toolLabel(for: entry.text)
                if currentCommandCounts[label] == nil {
                    currentCommandOrder.append(label)
                }
                currentCommandCounts[label, default: 0] += 1
            } else {
                flushCommandGroup()
                var displayEntry = entry
                displayEntry.text = Self.messageDisplayText(from: entry.text)
                if !displayEntry.text.isEmpty {
                    items.append(TranscriptDisplayItem(id: entry.id, payload: .entry(displayEntry)))
                }
            }
        }

        flushCommandGroup()
        return items
    }

    private static func messageDisplayText(from rawText: String) -> String {
        var text = rawText
        text = text.replacingOccurrences(
            of: #"(?s)<NEXT_ACTIONS>.*?</NEXT_ACTIONS>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?im)^\s*TASK_TITLE\s*:\s*.*$"#,
            with: " ",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replyDraft(for entry: CodexTranscriptEntry) -> String {
        let text = messageDisplayText(from: entry.text)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(text.prefix(120))
        guard !snippet.isEmpty else { return "Replying to the \(entry.role.rawValue) message: " }
        return "Replying to “\(snippet)\(text.count > snippet.count ? "…" : "")”: "
    }

    private static func relativeTimeString(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func toolLabel(for commandText: String) -> String {
        let text = commandText.lowercased()
        if text.contains("searching web") || text.contains("web search") {
            return "Web"
        }
        if text.contains("editing file") || text.contains("updated file") {
            return "Files"
        }
        if text.contains("command") || text.contains("running:") {
            return "Bash"
        }
        return "Tools"
    }
}

private struct HUDHeaderPill: View {
    let title: String
    let systemImageName: String
    let color: Color
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        guard appBoldTextEnabled else { return weight }
        switch weight {
        case .regular, .medium:
            return .semibold
        case .semibold:
            return .bold
        default:
            return weight
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImageName)
                .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .bold))
            Text(title)
                .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, max(9, subtextFontSize * 0.82))
        .padding(.vertical, max(6, subtextFontSize * 0.54))
        .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
        .overlay(Capsule(style: .continuous).stroke(color.opacity(0.32), lineWidth: 0.8))
    }
}

private struct HUDFloatingAgentButton: View {
    @ObservedObject var session: CodexAgentSession
    var isSelected: Bool
    var select: () -> Void
    var close: () -> Void
    @State private var isHovered = false
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        guard appBoldTextEnabled else { return weight }
        switch weight {
        case .regular, .medium:
            return .semibold
        case .semibold:
            return .bold
        default:
            return weight
        }
    }

    private var isRunning: Bool {
        switch session.status {
        case .starting, .running:
            return true
        case .stopped, .ready, .failed:
            return session.isTurnActiveForChatQueue
        }
    }

    private var closeTitle: String {
        if isRunning { return "Stop running task" }
        if session.canResumeAfterRelaunch { return "Resume task" }
        return "Archive agent session"
    }

    private var closeIcon: String {
        if isRunning { return "stop.circle.fill" }
        if session.canResumeAfterRelaunch { return "play.circle.fill" }
        return "archivebox"
    }

    private var closeAccessibilityLabel: String {
        if isRunning { return "Stop running task \(session.title)" }
        if session.canResumeAfterRelaunch { return "Resume task \(session.title)" }
        return "Archive \(session.title)"
    }

    private var hoverControlIcon: String {
        if isRunning { return "stop.fill" }
        if session.canResumeAfterRelaunch { return "play.fill" }
        return "archivebox.fill"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                HStack(spacing: 7) {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? session.accentTheme.accentSubtle : DS.Colors.surface3)
                            .frame(width: max(28, bodyFontSize + 15), height: max(28, bodyFontSize + 15))

                        Image(systemName: "cursorarrow")
                            .font(appUIFont(size: max(12, subtextFontSize + 1), weight: .bold))
                            .foregroundColor(session.accentTheme.cursorColor)
                            .rotationEffect(.degrees(-18))
                            .offset(x: -1, y: 1)

                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 1))
                            .offset(x: 1, y: 1)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title)
                            .font(appUIFont(size: max(11, bodyFontSize - 2), weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if isRunning {
                                HUDRunningAgentIndicator(color: statusColor)
                            } else {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 4.5, height: 4.5)
                            }
                            Text(statusLabel)
                                .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .textCase(.uppercase)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.leading, max(7, subtextFontSize * 0.64))
                .padding(.trailing, max(10, subtextFontSize * 0.90))
                .padding(.vertical, max(6, subtextFontSize * 0.54))
                .frame(maxWidth: 220, alignment: .leading)
                .background(
                    Capsule(style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(borderColor, lineWidth: isSelected ? 1.2 : 0.8)
                )
                .shadow(color: isSelected ? session.accentTheme.cursorColor.opacity(0.22) : Color.clear, radius: 9, y: 3)
                .scaleEffect(isHovered ? 1.015 : 1)
                .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Open \(session.title)")
            .help(session.title)
            .contextMenu {
                Button(action: close) {
                    Label(closeTitle, systemImage: closeIcon)
                }
            }

            if isHovered {
                Button(action: close) {
                    Image(systemName: hoverControlIcon)
                        .font(appUIFont(size: max(8, subtextFontSize - 3), weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(width: 15, height: 15)
                        .background(DS.Colors.surface3, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(closeTitle)
                .accessibilityLabel(closeAccessibilityLabel)
                .offset(x: 2, y: -2)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(height: 42)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }

    private var backgroundColor: Color {
        if isSelected {
            return session.accentTheme.accentSubtle
        }
        return isHovered ? DS.Colors.surface3 : DS.Colors.surface2
    }

    private var borderColor: Color {
        if isSelected {
            return session.accentTheme.cursorColor.opacity(0.82)
        }
        return isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle
    }

    private var statusColor: Color {
        if session.canResumeAfterRelaunch {
            return DS.Colors.warning
        }
        switch session.status {
        case .starting, .running:
            return DS.Colors.warning
        case .ready:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructiveText
        case .stopped:
            return DS.Colors.textTertiary
        }
    }

    private var statusLabel: String {
        session.canResumeAfterRelaunch ? "Resume" : session.status.label
    }
}

private struct HUDRunningAgentIndicator: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 3.8, height: 3.8)
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
        .frame(width: 15, height: 6)
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
        .accessibilityLabel("Running")
    }
}

private struct HUDRunButton: View {
    var canSend: Bool
    var isRunning: Bool
    var send: () -> Void
    var stop: () -> Void
    @State private var isHovered = false
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        guard appBoldTextEnabled else { return weight }
        switch weight {
        case .regular, .medium:
            return .semibold
        case .semibold:
            return .bold
        default:
            return weight
        }
    }

    private var showsStop: Bool {
        isRunning && !canSend
    }

    private var isEnabled: Bool {
        canSend || showsStop
    }

    var body: some View {
        Button(action: showsStop ? stop : send) {
            Image(systemName: showsStop ? "stop.fill" : "paperplane.fill")
                .font(appUIFont(size: max(12, bodyFontSize - 1), weight: .bold))
                .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.disabledText)
                .frame(width: 36, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .scaleEffect(isHovered && isEnabled ? 1.025 : 1)
                .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
        .help(showsStop ? "Stop agent" : (isRunning ? "Queue follow-up" : "Send"))
        .accessibilityLabel(showsStop ? "Stop agent" : (isRunning ? "Queue follow-up" : "Send"))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return DS.Colors.disabledBackground
        }

        if showsStop {
            return isHovered ? DS.Colors.surface3 : DS.Colors.surface2
        }

        return isHovered ? DS.Colors.surface3 : DS.Colors.surface2
    }

    private var borderColor: Color {
        guard isEnabled else {
            return DS.Colors.borderSubtle.opacity(0.45)
        }

        if showsStop {
            return isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle
        }

        return isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle
    }
}

private final class OpenClickyHUDResizeContainerView: NSView {
    private struct ResizeEdges: OptionSet {
        let rawValue: Int

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    private let edgeHitWidth: CGFloat = 16
    private let cornerHitLength: CGFloat = 30
    private var activeEdges: ResizeEdges = []
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartFrame: NSRect = .zero
    private var windowWasMovableByBackground = false

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !resizeEdges(at: point).isEmpty else {
            return super.hitTest(point)
        }
        return self
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: edgeHitWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.maxX - edgeHitWidth, y: 0, width: edgeHitWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: edgeHitWidth), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.maxY - edgeHitWidth, width: bounds.width, height: edgeHitWidth), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        activeEdges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        guard !activeEdges.isEmpty, let window else {
            super.mouseDown(with: event)
            return
        }
        windowWasMovableByBackground = window.isMovableByWindowBackground
        window.isMovableByWindowBackground = false
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeEdges.isEmpty, let window else {
            super.mouseDragged(with: event)
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let deltaX = mouseLocation.x - dragStartMouseLocation.x
        let deltaY = mouseLocation.y - dragStartMouseLocation.y
        let minSize = window.minSize
        let maxSize = window.maxSize
        let maxWidth = maxSize.width > 0 ? maxSize.width : CGFloat.greatestFiniteMagnitude
        let maxHeight = maxSize.height > 0 ? maxSize.height : CGFloat.greatestFiniteMagnitude

        var frame = dragStartFrame
        if activeEdges.contains(.right) {
            frame.size.width = min(max(dragStartFrame.width + deltaX, minSize.width), maxWidth)
        }
        if activeEdges.contains(.left) {
            let width = min(max(dragStartFrame.width - deltaX, minSize.width), maxWidth)
            frame.origin.x = dragStartFrame.maxX - width
            frame.size.width = width
        }
        if activeEdges.contains(.top) {
            frame.size.height = min(max(dragStartFrame.height + deltaY, minSize.height), maxHeight)
        }
        if activeEdges.contains(.bottom) {
            let height = min(max(dragStartFrame.height - deltaY, minSize.height), maxHeight)
            frame.origin.y = dragStartFrame.maxY - height
            frame.size.height = height
        }

        applyResizeFrame(frame, to: window)
    }

    override func mouseUp(with event: NSEvent) {
        window?.isMovableByWindowBackground = windowWasMovableByBackground
        activeEdges = []
        needsLayout = true
    }

    private func applyResizeFrame(_ frame: NSRect, to window: NSWindow) {
        let scale = window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let alignedFrame = NSRect(
            x: (frame.origin.x * scale).rounded() / scale,
            y: (frame.origin.y * scale).rounded() / scale,
            width: (frame.size.width * scale).rounded() / scale,
            height: (frame.size.height * scale).rounded() / scale
        )
        guard alignedFrame != window.frame else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(alignedFrame, display: true, animate: false)
        CATransaction.commit()
        window.invalidateCursorRects(for: self)
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        guard bounds.contains(point) else { return [] }

        var edges: ResizeEdges = []
        let nearLeft = point.x <= edgeHitWidth
        let nearRight = point.x >= bounds.maxX - edgeHitWidth
        let nearBottom = point.y <= edgeHitWidth
        let nearTop = point.y >= bounds.maxY - edgeHitWidth
        let inLowerCornerBand = point.y <= cornerHitLength
        let inUpperCornerBand = point.y >= bounds.maxY - cornerHitLength
        let inLeftCornerBand = point.x <= cornerHitLength
        let inRightCornerBand = point.x >= bounds.maxX - cornerHitLength

        if nearLeft || (inLeftCornerBand && (nearTop || nearBottom)) { edges.insert(.left) }
        if nearRight || (inRightCornerBand && (nearTop || nearBottom)) { edges.insert(.right) }
        if nearBottom || (inLowerCornerBand && (nearLeft || nearRight)) { edges.insert(.bottom) }
        if nearTop || (inUpperCornerBand && (nearLeft || nearRight)) { edges.insert(.top) }
        return edges
    }
}
