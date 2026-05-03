import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum OpenClickyHUDLayout {
    static let width: CGFloat = 594
    static let height: CGFloat = 452
    static let minimumWidth: CGFloat = 594
    static let minimumHeight: CGFloat = 452
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
        panel.hasShadow = false
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

    @ObservedObject var companionManager: CompanionManager
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    var openMemory: () -> Void
    var prepareVoiceFollowUp: () -> Void
    var close: () -> Void
    @State private var prompt = ""
    @State private var hiddenOverlayDockItemID: UUID?
    @State private var expandedCommandGroupIDs: Set<String> = []
    @State private var droppedAttachments: [HUDDraftAttachment] = []
    @State private var isDropTargeted = false

    private var session: CodexAgentSession {
        companionManager.codexAgentSession
    }

    private var activeDockItem: ClickyAgentDockItem? {
        companionManager.agentDockItems
            .reversed()
            .first {
                $0.sessionID == session.id &&
                $0.id != hiddenOverlayDockItemID
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            agentTeamStrip
            if let item = activeDockItem {
                ClickyAgentDockHoverCard(
                    item: item,
                    canOpenDashboard: false,
                    chat: {},
                    text: {
                        companionManager.showTextFollowUpForAgentDockItem(item.id)
                    },
                    voice: {
                        companionManager.prepareVoiceFollowUpForAgentDockItem(item.id)
                    },
                    close: {
                        hiddenOverlayDockItemID = item.id
                    },
                    stop: {
                        companionManager.stopAgentDockItem(item.id)
                    },
                    dismiss: {
                        companionManager.dismissAgentDockItem(item.id)
                    },
                    runSuggestedAction: { actionTitle in
                        companionManager.runSuggestedNextAction(actionTitle)
                    }
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            if !session.queuedFollowUpPrompts.isEmpty {
                queuedFollowUpDrawer
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.7))
                .frame(height: 0.5)
            transcript
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.7))
                .frame(height: 0.5)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.067, green: 0.075, blue: 0.071).opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isDropTargeted ? DS.Colors.accentText.opacity(0.55) : Color.white.opacity(0.10), lineWidth: isDropTargeted ? 1.4 : 1)
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
        .onChange(of: session.id) {
            hiddenOverlayDockItemID = nil
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "cursorarrow.motionlines.click")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DS.Colors.accentText.opacity(0.12)))

            Text("OpenClicky")
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            iconButton(systemName: "books.vertical", helpText: "Memory", action: openMemory)
            iconButton(systemName: "bolt.fill", helpText: "Warm up", action: { session.warmUp() })
            iconButton(systemName: "xmark", helpText: "Close", action: close)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .overlay(
                            Circle()
                                .stroke(DS.Colors.borderSubtle.opacity(0.8), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("Add agent")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 7)
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
                    }
                }
                .padding(10)
            }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask OpenClicky to inspect, edit, explain, or automate something.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Agent tasks use the bundled Codex runtime and the coding/actions model selected in settings.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.5)
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
                Spacer(minLength: 62)
            }

            transcriptBubble(entry, isUser: isUser)
                .frame(maxWidth: 430, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 62)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func transcriptBubble(_ entry: CodexTranscriptEntry, isUser: Bool) -> some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
            Text(label(for: entry.role))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color(for: entry.role))
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            Text(entry.text)
                .font(.system(size: 11, design: entry.role == .command ? .monospaced : .default))
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(isUser ? .trailing : .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(background(for: entry.role))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(isUser ? 0.085 : 0.055), lineWidth: 0.5)
        )
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
                                    .fill(Color.white.opacity(0.045))
                            )
                    }
                }
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.yellow.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.055), lineWidth: 0.5)
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
                            .font(.system(size: 8, weight: .heavy))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isExpanded ? 0.14 : 0.10))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(isExpanded ? 0.20 : 0.12), lineWidth: 0.5)
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
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.accentText)
                Text("Queued follow-ups")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("\(session.queuedFollowUpPrompts.count)")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(session.queuedFollowUpPrompts.enumerated()), id: \.offset) { _, queuedPrompt in
                        HStack(spacing: 6) {
                            Text(queuedPrompt)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Button(action: { session.removeQueuedFollowUp(queuedPrompt) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .heavy))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .accessibilityLabel("Remove queued follow-up")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.085)))
                        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.11), lineWidth: 0.5))
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.88)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Colors.accentText.opacity(0.18), lineWidth: 0.7)
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isDropTargeted ? DS.Colors.accentText.opacity(0.55) : DS.Colors.borderSubtle.opacity(0.75), lineWidth: isDropTargeted ? 1 : 0.5)
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
    }

    private var attachmentChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(droppedAttachments) { attachment in
                    HStack(spacing: 7) {
                        Image(systemName: attachment.systemImage)
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(attachment.kind == .image ? DS.Colors.accentText : DS.Colors.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.displayName)
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(attachment.kind == .image ? "Image" : "Document")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                        }
                        Button(action: { removeAttachment(attachment) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
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

    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.30))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(DS.Colors.accentText.opacity(0.50), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
            )
            .overlay(
                VStack(spacing: 7) {
                    Image(systemName: "plus.rectangle.on.folder")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(DS.Colors.accentText)
                    Text("Drop images or docs into OpenClicky")
                        .font(.system(size: 12, weight: .heavy))
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
        companionManager.submitAgentPromptFromUI(promptWithAttachments(submitted, attachments: attachments))
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
        case .command: return Color.yellow.opacity(0.9)
        case .plan: return Color.purple.opacity(0.9)
        }
    }

    private func background(for role: CodexTranscriptEntry.Role) -> Color {
        switch role {
        case .user: return DS.Colors.accentSubtle
        case .assistant: return Color.white.opacity(0.05)
        case .system: return DS.Colors.destructive.opacity(0.12)
        case .command: return Color.yellow.opacity(0.08)
        case .plan: return Color.purple.opacity(0.10)
        }
    }

    private func background(for item: TranscriptDisplayItem) -> Color {
        switch item.payload {
        case .entry(let entry):
            return background(for: entry.role)
        case .commandSummary:
            return Color.yellow.opacity(0.08)
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

private struct HUDFloatingAgentButton: View {
    @ObservedObject var session: CodexAgentSession
    var isSelected: Bool
    var select: () -> Void
    var close: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(backgroundColor)
                        .frame(width: 30, height: 30)
                        .overlay(
                            Circle()
                                .stroke(borderColor, lineWidth: isSelected ? 1.4 : 0.8)
                        )
                        .shadow(
                            color: session.accentTheme.cursorColor.opacity(isSelected ? 0.34 : 0.10),
                            radius: isSelected ? 7 : 3,
                            x: 0,
                            y: 0
                        )

                    Image(systemName: "cursorarrow")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(session.accentTheme.cursorColor)
                        .rotationEffect(.degrees(-18))
                        .offset(x: -1, y: 1)

                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 1))
                        .offset(x: 1, y: -1)
                }
                .frame(width: 34, height: 34)
                .scaleEffect(isHovered ? 1.04 : 1)
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
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(width: 15, height: 15)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Close agent session")
                .accessibilityLabel("Close \(session.title)")
                .offset(x: 2, y: -2)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 36, height: 36)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }

    private var backgroundColor: Color {
        if isSelected {
            return session.accentTheme.cursorColor.opacity(0.18)
        }
        return Color.white.opacity(isHovered ? 0.09 : 0.06)
    }

    private var borderColor: Color {
        if isSelected {
            return session.accentTheme.cursorColor.opacity(0.82)
        }
        return DS.Colors.borderSubtle.opacity(isHovered ? 0.9 : 0.55)
    }

    private var statusColor: Color {
        switch session.status {
        case .starting, .running:
            return Color.yellow
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
                .font(.system(size: 12, weight: .heavy))
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
            return Color.white.opacity(isHovered ? 0.13 : 0.09)
        }

        return Color.white.opacity(isHovered ? 0.15 : 0.10)
    }

    private var borderColor: Color {
        guard isEnabled else {
            return DS.Colors.borderSubtle.opacity(0.45)
        }

        if showsStop {
            return Color.white.opacity(isHovered ? 0.22 : 0.12)
        }

        return Color.white.opacity(isHovered ? 0.24 : 0.14)
    }
}
