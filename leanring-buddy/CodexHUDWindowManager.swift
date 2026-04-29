import AppKit
import SwiftUI

private enum OpenClickyHUDLayout {
    static let width: CGFloat = 594
    static let height: CGFloat = 440
    static let minimumWidth: CGFloat = 594
    static let minimumHeight: CGFloat = 420
}

@MainActor
final class CodexHUDWindowManager {
    private var panel: NSPanel?

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
        } else if let hostingView = panel?.contentView as? NSHostingView<CodexHUDView> {
            hostingView.rootView = CodexHUDView(
                companionManager: companionManager,
                openMemory: openMemory,
                prepareVoiceFollowUp: prepareVoiceFollowUp
            ) { [weak self] in
                self?.hide()
            }
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
        panel?.close()
        panel = nil
    }

    private func makePanel(
        companionManager: CompanionManager,
        openMemory: @escaping () -> Void,
        prepareVoiceFollowUp: @escaping () -> Void
    ) -> NSPanel {
        let hostingView = NSHostingView(
            rootView: CodexHUDView(
                companionManager: companionManager,
                openMemory: openMemory,
                prepareVoiceFollowUp: prepareVoiceFollowUp
            ) { [weak self] in
                self?.hide()
            }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: OpenClickyHUDLayout.width, height: OpenClickyHUDLayout.height),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenClicky"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: OpenClickyHUDLayout.minimumWidth, height: OpenClickyHUDLayout.minimumHeight)
        panel.contentMinSize = NSSize(width: OpenClickyHUDLayout.minimumWidth, height: OpenClickyHUDLayout.minimumHeight)
        panel.contentView = hostingView
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

private struct CodexHUDView: View {
    @ObservedObject var companionManager: CompanionManager
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(OpenClickyAgentPreferences.followUpAttachScreenKey) private var agentFollowUpAttachScreen = true
    var openMemory: () -> Void
    var prepareVoiceFollowUp: () -> Void
    var close: () -> Void
    @State private var prompt = ""

    private var session: CodexAgentSession {
        companionManager.codexAgentSession
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            agentTeamStrip
            if companionManager.agentVoiceFollowUpCapturePhase != .idle {
                AgentVoiceFollowUpCaptureBanner(
                    phase: companionManager.agentVoiceFollowUpCapturePhase,
                    audioLevel: companionManager.currentAudioPowerLevel,
                    onCancel: { companionManager.cancelAgentVoiceFollowUpCapture() }
                )
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.7))
                .frame(height: 0.5)

            AgentSessionOutputsStrip(
                workspaceDirectoryPath: session.sessionWorkspaceDirectoryURL.path,
                fileURLs: session.sessionArtifactFileURLs,
                showWorkspaceLink: session.hasVisibleActivity
            )
            .padding(.horizontal, 12)

            transcript
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.7))
                .frame(height: 0.5)
            if let card = session.latestResponseCard {
                ClickyResponseCardCompactView(
                    card: card,
                    presentation: .inlineHUD,
                    actionHandlers: ClickyResponseCardActionHandlers(
                        dismiss: { companionManager.dismissLatestResponseCard() },
                        runSuggestedNextAction: { actionTitle in
                            session.dismissLatestResponseCard()
                            companionManager.submitAgentPromptFromUI(actionTitle)
                        },
                        openTextFollowUp: nil,
                        openVoiceFollowUp: {
                            session.dismissLatestResponseCard()
                            close()
                            prepareVoiceFollowUp()
                        }
                    )
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            composer
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
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface1)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .animation(.none, value: selectedAccentThemeID)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(session.model)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AgentStatusPill(
                title: session.status.label,
                subtitle: nil,
                indicatorColor: statusColor
            )

            HStack(spacing: 4) {
                iconButton(systemName: "books.vertical", helpText: "Memory", action: openMemory)
                iconButton(systemName: "bolt.fill", helpText: "Warm up", action: { session.warmUp() })
                iconButton(
                    systemName: "xmark.circle.fill",
                    helpText: "Close this agent tab",
                    action: { companionManager.closeCodexAgentSession(session.id) },
                    isDestructiveOnHover: true
                )
                iconButton(systemName: "xmark", helpText: "Close dashboard", action: close)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(DS.Colors.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("Add agent")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var transcript: some View {
        let entries = hudTranscriptEntries
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if entries.isEmpty {
                        Text(hudEmptyChatHint)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 2)
                    } else {
                        ForEach(entries) { entry in
                            AgentChatBubble(entry: entry, density: .hud)
                                .id(entry.id)
                        }
                    }
                }
                .padding(6)
            }
            .background(DS.Colors.background)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity)
            .onChange(of: session.entries.count) {
                if let id = session.entries.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var hudTranscriptEntries: [CodexTranscriptEntry] {
        session.entries.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var hudEmptyChatHint: String {
        switch session.status {
        case .starting:
            return "Starting…"
        case .running:
            return "Running…"
        case .failed:
            return "Something went wrong. Check Memory or warm up, then try again."
        case .ready:
            return "Describe a task or paste context. Output streams here as the agent runs."
        case .stopped:
            return "Agent is offline."
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .ready: return DS.Colors.success
        case .running, .starting: return DS.Colors.warning
        case .failed: return DS.Colors.destructiveText
        case .stopped: return DS.Colors.textTertiary
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Write a message…", text: $prompt, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(DS.Colors.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
                    .onSubmit(send)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            return .ignored
                        }
                        guard canSend else { return .ignored }
                        send()
                        return .handled
                    }

                HUDRunButton(canSend: canSend, action: send)
            }

            if session.hasPriorUserTurnInTranscript {
                Toggle(isOn: $agentFollowUpAttachScreen) {
                    Text("Attach screen on follow-ups")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .toggleStyle(.checkbox)
                .help("Turn off to send text only so the agent stays focused on the thread and current desktop context does not override the conversation.")
            }
        }
        .padding(10)
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let submitted = prompt
        prompt = ""
        companionManager.submitAgentPromptFromUI(submitted)
    }

    private func iconButton(
        systemName: String,
        helpText: String,
        action: @escaping () -> Void,
        isDestructiveOnHover: Bool? = nil
    ) -> some View {
        let destructive = isDestructiveOnHover ?? (systemName == "xmark")
        return Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(
            DSIconButtonStyle(
                size: 28,
                isDestructiveOnHover: destructive,
                tooltipText: helpText,
                tooltipAlignment: .trailing
            )
        )
    }

}

private struct HUDFloatingAgentButton: View {
    @ObservedObject var session: CodexAgentSession
    var isSelected: Bool
    var select: () -> Void
    var close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Select agent \(session.title)")

            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.trailing, 8)
            .help("Close this agent")
            .accessibilityLabel("Close agent \(session.title)")
        }
        .background(isSelected ? DS.Colors.surface3 : DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1)
        )
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
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Send")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(canSend ? DS.Colors.textOnAccent : DS.Colors.disabledText)
                .frame(width: 72, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .pointerCursor(isEnabled: canSend)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        guard canSend else {
            return DS.Colors.disabledBackground
        }

        return isHovered ? DS.Colors.accentHover : DS.Colors.accent
    }

    private var borderColor: Color {
        guard canSend else {
            return DS.Colors.borderSubtle.opacity(0.45)
        }

        return DS.Colors.borderStrong.opacity(isHovered ? 0.9 : 0.5)
    }
}
