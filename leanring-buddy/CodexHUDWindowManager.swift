import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

enum OpenClickyHUDLayout {
    static let width: CGFloat = 980
    static let height: CGFloat = 560
    static let minimumWidth: CGFloat = 720
    static let minimumHeight: CGFloat = 452
}

@MainActor
final class CodexHUDWindowManager: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

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
        } else if let hostingView = panel?.contentView as? NSHostingView<ChatWorkspaceView> {
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
        // Standard macOS window chrome: title bar + traffic lights (close /
        // minimize / zoom). We keep NSPanel for the menu-bar app context but
        // drop every borderless / floating attribute so the OS draws normal
        // chrome. No transparency, no hidden title, no floating level.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: OpenClickyHUDLayout.width, height: OpenClickyHUDLayout.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenClicky"
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.hasShadow = true
        panel.minSize = NSSize(width: OpenClickyHUDLayout.minimumWidth, height: OpenClickyHUDLayout.minimumHeight)
        panel.contentMinSize = NSSize(width: OpenClickyHUDLayout.minimumWidth, height: OpenClickyHUDLayout.minimumHeight)
        panel.contentView = hostingView
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func enforceMinimumSize() {
        guard let panel else { return }
        let currentFrame = panel.frame
        let constrainedWidth = max(currentFrame.width, OpenClickyHUDLayout.minimumWidth)
        let constrainedHeight = max(currentFrame.height, OpenClickyHUDLayout.minimumHeight)

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
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    var openMemory: () -> Void
    var prepareVoiceFollowUp: () -> Void
    var close: () -> Void
    var chromeMode: ChromeMode = .standalone
    @State private var prompt = ""
    @State private var expandedCommandGroupIDs: Set<String> = []
    @State private var droppedAttachments: [HUDDraftAttachment] = []
    @State private var isDropTargeted = false
    @State private var timestampNow = Date()

    private var session: CodexAgentSession {
        companionManager.codexAgentSession
    }

    private var activeDockItem: ClickyAgentDockItem? {
        companionManager.agentDockItems.last { $0.sessionID == session.id }
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
                .padding(.horizontal, 14)
                .padding(.top, 10)
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
            perform: handleDrop
        )
        .animation(.none, value: selectedAccentThemeID)
        .animation(.easeOut(duration: DS.Animation.fast), value: isDropTargeted)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            timestampNow = now
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("OpenClicky")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Circle()
                    .fill(sessionStatusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: sessionStatusColor.opacity(0.55), radius: 3.5)
            }

            Spacer()

            Text(headerSubtitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)

            HUDHeaderPill(
                title: session.status.label,
                systemImageName: session.isTurnActiveForChatQueue ? "sparkles" : "terminal.fill",
                color: session.isTurnActiveForChatQueue ? DS.Colors.accentText : sessionStatusColor
            )
            HUDHeaderPill(
                title: "\(companionManager.codexAgentSessions.count) sessions",
                systemImageName: "rectangle.stack.fill",
                color: DS.Colors.textSecondary
            )
            iconButton(systemName: "books.vertical", helpText: "Memory", action: openMemory)
            iconButton(systemName: "bolt.fill", helpText: "Warm up", action: { session.warmUp() })
            iconButton(systemName: "xmark", helpText: "Close", action: close)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerSubtitle: String {
        if session.isTurnActiveForChatQueue {
            return session.latestActivityDisplaySummary ?? session.latestActivitySummary ?? "Working on the current task"
        }
        return "Agent HUD and task chat"
    }

    private var sessionStatusColor: Color {
        switch session.status {
        case .starting, .running: return DS.Colors.accentText
        case .ready: return DS.Colors.success
        case .failed: return DS.Colors.destructiveText
        case .stopped: return DS.Colors.textTertiary
        }
    }

    private var agentTeamStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(companionManager.codexAgentSessions) { agentSession in
                    HUDFloatingAgentButton(
                        session: agentSession,
                        isSelected: agentSession.id == companionManager.activeCodexAgentSessionID,
                        select: {
                            companionManager.selectCodexAgentSession(agentSession.id)
                        },
                        close: {
                            companionManager.closeCodexAgentSession(agentSession.id)
                        }
                    )
                }

                Button(action: {
                    companionManager.createAndSelectNewCodexAgentSession()
                }) {
                    Label("New", systemImage: "plus.message.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
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
            .padding(.horizontal, 14)
        }
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
                .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .onChange(of: session.entries.count) {
                if let id = session.entries.last?.id {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DS.Colors.accentSubtle))
            VStack(alignment: .leading, spacing: 3) {
                Text("Ask OpenClicky to inspect, edit, explain, or automate something.")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Agent tasks use the bundled Codex runtime and the coding/actions model selected in settings.")
                    .font(.system(size: 11, weight: .medium))
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
                if isUser { Spacer(minLength: 0) }
                Text(label(for: entry.role))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color(for: entry.role))
                Text(Self.relativeTimeString(from: entry.createdAt, now: timestampNow))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                if !isUser { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            Text(entry.text)
                .font(.system(size: entry.role == .command ? 10 : 12, weight: .medium, design: entry.role == .command ? .monospaced : .default))
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            let openableLinks = OpenClickyOpenableLinkExtractor.links(in: entry.text, limit: 2)
            if !openableLinks.isEmpty {
                HStack(spacing: 6) {
                    ForEach(openableLinks) { link in
                        Button {
                            NSWorkspace.shared.open(link.url)
                        } label: {
                            Label(link.buttonTitle, systemImage: link.systemImageName)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.surface3))
                        .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
                        .pointerCursor()
                    }
                    if isUser { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }

            HStack(spacing: 6) {
                if isUser { Spacer(minLength: 0) }
                Button {
                    prompt = Self.replyDraft(for: entry)
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(DS.Colors.surface3))
                .overlay(Capsule(style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
                .pointerCursor()
                .accessibilityLabel("Reply to \(label(for: entry.role).lowercased()) message")
                if !isUser { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(background(for: entry.role))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
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
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(Self.relativeTimeString(from: session.entries.last?.createdAt ?? Date(), now: timestampNow))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                if let latest = session.latestActivityDisplaySummary ?? session.latestActivitySummary {
                    Text(latest)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
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
        .frame(maxWidth: 430, alignment: .leading)
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
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(DS.Colors.textSecondary)
                            .textSelection(.enabled)
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
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
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
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                Text("Queued follow-ups")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("\(session.queuedFollowUpPrompts.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.surface2))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(session.queuedFollowUpPrompts.enumerated()), id: \.offset) { _, queuedPrompt in
                        HStack(spacing: 6) {
                            Text(queuedPrompt)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Button(action: { session.removeQueuedFollowUp(queuedPrompt) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .accessibilityLabel("Remove queued follow-up")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
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

            HStack(alignment: .bottom, spacing: 8) {
                TextField(droppedAttachments.isEmpty ? "Ask Chat..." : "Ask Chat about the attachment...", text: $prompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isDropTargeted ? DS.Colors.accentText.opacity(0.55) : DS.Colors.borderSubtle, lineWidth: isDropTargeted ? 1 : 0.8)
                    )
                    .onSubmit(send)

                HUDRunButton(
                    canSend: canSend,
                    isRunning: session.isTurnActiveForChatQueue,
                    send: send,
                    stop: stopCurrentSession
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var attachmentChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(droppedAttachments) { attachment in
                    HStack(spacing: 7) {
                        Image(systemName: attachment.systemImage)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(attachment.kind == .image ? DS.Colors.accentText : DS.Colors.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.displayName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(attachment.kind == .image ? "Image" : "Document")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                        }
                        Button(action: { removeAttachment(attachment) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .accessibilityLabel("Remove attachment")
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 7)
                    .padding(.vertical, 6)
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
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(DS.Colors.accentText)
                    Text("Drop images or docs into OpenClicky")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("They’ll attach as chips before sending")
                        .font(.system(size: 10, weight: .semibold))
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

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImageName)
                .font(.system(size: 9, weight: .bold))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                HStack(spacing: 7) {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? session.accentTheme.accentSubtle : DS.Colors.surface3)
                            .frame(width: 28, height: 28)

                        Image(systemName: "cursorarrow")
                            .font(.system(size: 12, weight: .bold))
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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(session.status.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .textCase(.uppercase)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 7)
                .padding(.trailing, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(borderColor, lineWidth: isSelected ? 1.2 : 0.8)
                )
                .scaleEffect(isHovered ? 1.015 : 1)
                .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Open \(session.title)")
            .help(session.title)
            .contextMenu {
                Button(role: .destructive, action: close) {
                    Label("Close agent session", systemImage: "xmark.circle")
                }
            }

            if isHovered {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
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
                .help("Close agent session")
                .accessibilityLabel("Close \(session.title)")
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
}


private struct HUDRunButton: View {
    var canSend: Bool
    var isRunning: Bool
    var send: () -> Void
    var stop: () -> Void
    @State private var isHovered = false

    private var showsStop: Bool {
        isRunning && !canSend
    }

    private var isEnabled: Bool {
        canSend || showsStop
    }

    var body: some View {
        Button(action: showsStop ? stop : send) {
            Image(systemName: showsStop ? "stop.fill" : "paperplane.fill")
                .font(.system(size: 12, weight: .bold))
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
