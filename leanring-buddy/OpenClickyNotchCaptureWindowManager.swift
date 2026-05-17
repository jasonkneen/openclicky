//
//  OpenClickyNotchCaptureWindowManager.swift
//  leanring-buddy
//
//  Top-of-screen capture surface for OpenClicky. It anchors beneath the
//  MacBook Pro notch when the built-in display is present, otherwise beneath
//  the active main display while docked. This replaces the old cursor-local
//  Ctrl+Ctrl text interface and mirrors Clicky's top listening affordance.
//

import AppKit

private final class OpenClickyNotchCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum OpenClickyNotchCaptureAction: String, CaseIterable {
    case ask
    case aiText
    case agent

    var title: String {
        switch self {
        case .ask: return "Ask"
        case .aiText: return "AI Text"
        case .agent: return "Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .ask: return "paperplane.fill"
        case .aiText: return "textformat"
        case .agent: return "terminal.fill"
        }
    }
}

private struct OpenClickyNotchCaptureSuggestion {
    enum Kind {
        case slashCommand
        case mention

        init?(trigger: Character) {
            switch trigger {
            case "/": self = .slashCommand
            case "@": self = .mention
            default: return nil
            }
        }
    }

    let token: String
    let title: String
    let systemImage: String

    static func candidates(for kind: Kind) -> [OpenClickyNotchCaptureSuggestion] {
        switch kind {
        case .slashCommand:
            return [
                OpenClickyNotchCaptureSuggestion(token: "/agent", title: "start background work", systemImage: "shippingbox"),
                OpenClickyNotchCaptureSuggestion(token: "/voice", title: "use shared voice context", systemImage: "waveform"),
                OpenClickyNotchCaptureSuggestion(token: "/screen", title: "include screen context", systemImage: "rectangle.dashed"),
                OpenClickyNotchCaptureSuggestion(token: "/workspace", title: "current workspace", systemImage: "folder"),
                OpenClickyNotchCaptureSuggestion(token: "/skills", title: "available skills", systemImage: "sparkles"),
                OpenClickyNotchCaptureSuggestion(token: "/tools", title: "available tools", systemImage: "wrench.and.screwdriver")
            ]
        case .mention:
            return [
                OpenClickyNotchCaptureSuggestion(token: "@agent", title: "background agent", systemImage: "shippingbox"),
                OpenClickyNotchCaptureSuggestion(token: "@voice", title: "main voice thread", systemImage: "waveform"),
                OpenClickyNotchCaptureSuggestion(token: "@screen", title: "visible screen", systemImage: "rectangle.dashed"),
                OpenClickyNotchCaptureSuggestion(token: "@workspace", title: "current workspace", systemImage: "folder"),
                OpenClickyNotchCaptureSuggestion(token: "@skills", title: "skills", systemImage: "sparkles"),
                OpenClickyNotchCaptureSuggestion(token: "@tools", title: "tools", systemImage: "wrench.and.screwdriver")
            ]
        }
    }
}

@MainActor
final class OpenClickyNotchCaptureWindowManager {
    private enum ActiveMode {
        case collapsedText
        case text
        case voice
    }

    private var panel: OpenClickyNotchCapturePanel?
    private var contentView: OpenClickyNotchCaptureRootView?
    private var activeMode: ActiveMode?
    private var persistentAccentColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
    private var persistentSubmitText: ((String) -> Void)?

    // AppKit window frames are in points, not pixels. Keep these as real
    // point sizes; do not divide by backingScaleFactor or the content clips on
    // Retina displays.
    private static let expandedPanelWidth: CGFloat = 520
    private static let collapsedPanelWidth: CGFloat = 188
    private static let collapsedPanelHeight: CGFloat = 18
    private static let textPanelHeight: CGFloat = 226
    private static let voicePanelHeight: CGFloat = 64
    private static let topGap: CGFloat = 0
    private static let screenEdgePadding: CGFloat = 12

    func showPersistentPill(accentTheme: ClickyAccentTheme? = nil, submitText: @escaping (String) -> Void) {
        activeMode = .collapsedText
        ensurePanel()
        let accentColor = Self.nsAccentColor(for: accentTheme)
        persistentAccentColor = accentColor
        persistentSubmitText = submitText
        contentView?.configureCollapsed(
            accentColor: accentColor,
            expand: { [weak self] in
                self?.expandTextInput(accentColor: accentColor, submitText: submitText)
            },
            dismiss: { [weak self] in self?.collapseToPill(accentColor: accentColor, submitText: submitText) }
        )
        showPanel(activating: false, width: Self.collapsedPanelWidth, height: Self.collapsedPanelHeight)
    }

    func showTextInput(accentTheme: ClickyAccentTheme? = nil, submitText: @escaping (String) -> Void) {
        let accentColor = Self.nsAccentColor(for: accentTheme)
        expandTextInput(accentColor: accentColor, submitText: submitText)
    }

    func updateVoiceState(_ voiceState: CompanionVoiceState, audioPowerLevel: CGFloat) {
        switch voiceState {
        case .idle:
            if activeMode == .voice {
                if let persistentSubmitText {
                    collapseToPill(accentColor: persistentAccentColor, submitText: persistentSubmitText)
                } else {
                    hide()
                }
            }
        case .listening, .processing, .responding:
            guard activeMode != .text else { return }
            activeMode = .voice
            ensurePanel()
            contentView?.configureVoice(
                state: voiceState,
                audioPowerLevel: audioPowerLevel,
                accentColor: Self.nsAccentColor(for: nil)
            )
            showPanel(activating: false, width: Self.voicePanelWidth(for: Self.preferredAnchorScreen()), height: Self.voicePanelHeight)
        }
    }

    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {
        guard activeMode == .voice else { return }
        contentView?.updateAudioPowerLevel(audioPowerLevel)
    }

    func hide() {
        panel?.orderOut(nil)
        activeMode = nil
    }

    private func collapseToPill(accentColor: NSColor, submitText: @escaping (String) -> Void) {
        activeMode = .collapsedText
        contentView?.configureCollapsed(
            accentColor: accentColor,
            expand: { [weak self] in
                self?.expandTextInput(accentColor: accentColor, submitText: submitText)
            },
            dismiss: { [weak self] in self?.collapseToPill(accentColor: accentColor, submitText: submitText) }
        )
        showPanel(activating: false, width: Self.collapsedPanelWidth, height: Self.collapsedPanelHeight)
    }

    private func expandTextInput(accentColor: NSColor, submitText: @escaping (String) -> Void) {
        activeMode = .text
        persistentAccentColor = accentColor
        persistentSubmitText = submitText
        contentView?.configureText(
            accentColor: accentColor,
            submitText: submitText,
            dismiss: { [weak self] in self?.collapseToPill(accentColor: accentColor, submitText: submitText) }
        )
        showPanel(activating: true, width: Self.expandedPanelWidth, height: Self.textPanelHeight)
        contentView?.focusTextField()
    }

    private func showPanel(activating: Bool, width: CGFloat, height: CGFloat) {
        resizeAndReposition(width: width, height: height)
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        } else {
            panel?.orderFrontRegardless()
        }
        panel?.orderFrontRegardless()
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let capturePanel = OpenClickyNotchCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.expandedPanelWidth, height: Self.textPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        capturePanel.isFloatingPanel = true
        capturePanel.level = .statusBar
        capturePanel.isOpaque = false
        capturePanel.backgroundColor = .clear
        capturePanel.hasShadow = true
        capturePanel.hidesOnDeactivate = false
        capturePanel.isReleasedWhenClosed = false
        capturePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        capturePanel.isMovableByWindowBackground = false
        capturePanel.titleVisibility = .hidden
        capturePanel.titlebarAppearsTransparent = true

        let rootView = OpenClickyNotchCaptureRootView(frame: NSRect(x: 0, y: 0, width: Self.expandedPanelWidth, height: Self.textPanelHeight))
        rootView.autoresizingMask = [.width, .height]
        capturePanel.contentView = rootView
        panel = capturePanel
        contentView = rootView
    }

    private func resizeAndReposition(width: CGFloat, height: CGFloat) {
        guard let panel else { return }
        let size = NSSize(width: width, height: height)
        panel.setFrame(
            NSRect(origin: panel.frame.origin, size: size),
            display: true,
            animate: false
        )
        contentView?.setCanvas(size: size)
        positionPanel(size: size)
    }

    private func positionPanel(size: NSSize) {
        guard let panel, let screen = Self.preferredAnchorScreen() else { return }
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let topEdge = fullFrame.maxY
        let usableFrame = visibleFrame.isEmpty ? fullFrame : visibleFrame
        let unclampedX = fullFrame.midX - size.width / 2
        let maxX = usableFrame.maxX - size.width - Self.screenEdgePadding
        let x = min(max(unclampedX, usableFrame.minX + Self.screenEdgePadding), maxX)
        let y = topEdge - size.height - Self.topGap
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func voicePanelWidth(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 620 }
        let available = max(320, screen.visibleFrame.width - 160)
        return min(max(available * 0.72, 520), 920)
    }

    private static func preferredAnchorScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if screens.count > 1, let main = NSScreen.main {
            return main
        }
        if let main = NSScreen.main {
            return main
        }
        return screens.first(where: isLikelyBuiltInNotchScreen) ?? screens.first
    }

    private static func isLikelyBuiltInNotchScreen(_ screen: NSScreen) -> Bool {
        let name = screen.localizedName.lowercased()
        let looksBuiltIn = name.contains("built-in")
            || name.contains("liquid retina")
            || name.contains("macbook")
        let visibleTopInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let safeTopInset: CGFloat
        if #available(macOS 12.0, *) {
            safeTopInset = screen.safeAreaInsets.top
        } else {
            safeTopInset = 0
        }
        return looksBuiltIn && (safeTopInset > 0 || visibleTopInset > 0)
    }

    private static func nsAccentColor(for theme: ClickyAccentTheme?) -> NSColor {
        switch theme ?? ClickyAccentTheme.current {
        case .blue:
            return NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
        case .mint:
            return NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1.0)
        case .amber:
            return NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 1.0)
        case .rose:
            return NSColor(calibratedRed: 1.00, green: 0.31, blue: 0.37, alpha: 1.0)
        case .white:
            return NSColor(calibratedWhite: 0.97, alpha: 1.0)
        }
    }
}

private final class OpenClickyNotchCaptureRootView: NSView, NSTextFieldDelegate {
    private enum Mode {
        case collapsed
        case text
        case voice
    }

    private let notchHandle = OpenClickyRoundedView(cornerRadius: 5)
    private let shellView = OpenClickyRoundedView(cornerRadius: 24)
    private let textStack = NSStackView()
    private let voiceStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Ask from anywhere")
    private let subtitleLabel = NSTextField(labelWithString: "Menu-bar notch surface, existing fast voice stack, local agent handoff.")
    private let inputShell = OpenClickyRoundedView(cornerRadius: 21)
    private let textField = NSTextField()
    private let suggestionStack = NSStackView()
    private let actionStack = NSStackView()
    private let voiceTitleLabel = NSTextField(labelWithString: "Listening")
    private let voiceSubtitleLabel = NSTextField(labelWithString: "Release the shortcut to send this turn.")
    private let waveformView = OpenClickyNotchWaveformNSView()
    private var mode: Mode = .voice
    private var submitText: ((String) -> Void)?
    private var dismiss: (() -> Void)?
    private var expand: (() -> Void)?
    private var accentColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildViewHierarchy()
        configureText(accentColor: accentColor, submitText: { _ in }, dismiss: {})
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildViewHierarchy()
        configureText(accentColor: accentColor, submitText: { _ in }, dismiss: {})
    }

    func configureCollapsed(accentColor: NSColor, expand: @escaping () -> Void, dismiss: @escaping () -> Void) {
        mode = .collapsed
        self.accentColor = accentColor
        self.expand = expand
        self.dismiss = dismiss
        textStack.isHidden = true
        voiceStack.isHidden = true
        shellView.isHidden = true
        notchHandle.isHidden = false
        notchHandle.fillColor = NSColor.black.withAlphaComponent(0.94)
        notchHandle.borderColor = accentColor.withAlphaComponent(0.32)
        needsDisplay = true
    }

    func configureText(accentColor: NSColor, submitText: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
        mode = .text
        self.accentColor = accentColor
        self.submitText = submitText
        self.dismiss = dismiss
        self.expand = nil
        shellView.isHidden = false
        textStack.isHidden = false
        voiceStack.isHidden = true
        shellView.cornerRadius = 24
        shellView.borderColor = NSColor.white.withAlphaComponent(0.085)
        updateAccentColors()
        updateSuggestions()
        textField.stringValue = ""
        window?.makeFirstResponder(textField)
    }

    func configureVoice(state: CompanionVoiceState, audioPowerLevel: CGFloat, accentColor: NSColor) {
        mode = .voice
        self.accentColor = accentColor
        expand = nil
        shellView.isHidden = false
        textStack.isHidden = true
        voiceStack.isHidden = false
        shellView.cornerRadius = 22
        shellView.borderColor = accentColor.withAlphaComponent(0.28)
        updateAccentColors()
        updateVoiceLabels(for: state)
        waveformView.audioPowerLevel = audioPowerLevel
        waveformView.accentColor = accentColor
    }

    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {
        waveformView.audioPowerLevel = audioPowerLevel
    }

    func focusTextField() {
        window?.makeFirstResponder(textField)
    }

    func setCanvas(size: NSSize) {
        frame = NSRect(origin: .zero, size: size)
        bounds = NSRect(origin: .zero, size: size)
        needsLayout = true
        needsDisplay = true
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        notchHandle.translatesAutoresizingMaskIntoConstraints = false
        notchHandle.fillColor = NSColor.black.withAlphaComponent(0.92)
        notchHandle.borderColor = NSColor.white.withAlphaComponent(0.045)
        addSubview(notchHandle)
        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleCollapsedClick(_:)))
        notchHandle.addGestureRecognizer(clickRecognizer)

        shellView.translatesAutoresizingMaskIntoConstraints = false
        shellView.fillColor = NSColor(calibratedRed: 0.025, green: 0.036, blue: 0.032, alpha: 0.96)
        shellView.borderColor = NSColor.white.withAlphaComponent(0.085)
        shellView.shadow = NSShadow()
        shellView.shadow?.shadowBlurRadius = 16
        shellView.shadow?.shadowOffset = NSSize(width: 0, height: -8)
        shellView.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.46)
        addSubview(shellView)

        configureTextStack()
        configureVoiceStack()

        NSLayoutConstraint.activate([
            notchHandle.topAnchor.constraint(equalTo: topAnchor),
            notchHandle.centerXAnchor.constraint(equalTo: centerXAnchor),
            notchHandle.widthAnchor.constraint(equalToConstant: 96),
            notchHandle.heightAnchor.constraint(equalToConstant: 10),

            shellView.topAnchor.constraint(equalTo: notchHandle.bottomAnchor, constant: -1),
            shellView.leadingAnchor.constraint(equalTo: leadingAnchor),
            shellView.trailingAnchor.constraint(equalTo: trailingAnchor),
            shellView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func handleCollapsedClick(_ recognizer: NSClickGestureRecognizer) {
        guard mode == .collapsed else { return }
        expand?()
    }

    private func configureTextStack() {
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 10
        textStack.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(textStack)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addArrangedSubview(makeIconOrb(systemName: "sparkles"))

        let copyStack = NSStackView()
        copyStack.orientation = .vertical
        copyStack.alignment = .leading
        copyStack.spacing = 2
        titleLabel.font = .systemFont(ofSize: 17, weight: .heavy)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.64)
        subtitleLabel.maximumNumberOfLines = 2
        copyStack.addArrangedSubview(titleLabel)
        copyStack.addArrangedSubview(subtitleLabel)
        header.addArrangedSubview(copyStack)
        textStack.addArrangedSubview(header)

        configureInputRow()
        textStack.addArrangedSubview(inputShell)

        suggestionStack.orientation = .horizontal
        suggestionStack.alignment = .centerY
        suggestionStack.spacing = 5
        suggestionStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(suggestionStack)
        suggestionStack.heightAnchor.constraint(equalToConstant: 18).isActive = true

        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.distribution = .fillEqually
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        for action in OpenClickyNotchCaptureAction.allCases {
            actionStack.addArrangedSubview(makeActionButton(action))
        }
        textStack.addArrangedSubview(actionStack)
        actionStack.heightAnchor.constraint(equalToConstant: 40).isActive = true

        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: shellView.topAnchor, constant: 16),
            textStack.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: -16),
            inputShell.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            actionStack.widthAnchor.constraint(equalTo: textStack.widthAnchor)
        ])
    }

    private func configureInputRow() {
        inputShell.translatesAutoresizingMaskIntoConstraints = false
        inputShell.fillColor = NSColor.black.withAlphaComponent(0.22)
        inputShell.borderColor = NSColor.white.withAlphaComponent(0.10)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        inputShell.addSubview(row)

        let bubbleIcon = makeSmallIcon(systemName: "text.bubble.fill")
        row.addArrangedSubview(bubbleIcon)

        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13, weight: .semibold)
        textField.textColor = NSColor.white.withAlphaComponent(0.95)
        textField.placeholderString = "Ask OpenClicky…"
        textField.delegate = self
        row.addArrangedSubview(textField)

        row.addArrangedSubview(makeGlyphButton(systemName: "arrow.up.circle.fill", action: { [weak self] in self?.submit(.ask) }))
        row.addArrangedSubview(makeGlyphButton(systemName: "xmark.circle.fill", action: { [weak self] in self?.dismiss?() }))

        NSLayoutConstraint.activate([
            inputShell.heightAnchor.constraint(equalToConstant: 42),
            row.leadingAnchor.constraint(equalTo: inputShell.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: inputShell.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: inputShell.centerYAnchor),
            bubbleIcon.widthAnchor.constraint(equalToConstant: 24),
            bubbleIcon.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func configureVoiceStack() {
        voiceStack.orientation = .horizontal
        voiceStack.alignment = .centerY
        voiceStack.spacing = 10
        voiceStack.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(voiceStack)

        let copyStack = NSStackView()
        copyStack.orientation = .vertical
        copyStack.alignment = .leading
        copyStack.spacing = 3
        voiceTitleLabel.font = .systemFont(ofSize: 15, weight: .heavy)
        voiceTitleLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        voiceSubtitleLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        voiceSubtitleLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        copyStack.addArrangedSubview(voiceTitleLabel)
        copyStack.addArrangedSubview(voiceSubtitleLabel)
        copyStack.addArrangedSubview(waveformView)
        voiceStack.addArrangedSubview(copyStack)
        waveformView.widthAnchor.constraint(equalToConstant: 210).isActive = true
        waveformView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        NSLayoutConstraint.activate([
            voiceStack.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 12),
            voiceStack.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: -12),
            voiceStack.centerYAnchor.constraint(equalTo: shellView.centerYAnchor)
        ])
        voiceStack.isHidden = true
    }

    private func makeIconOrb(systemName: String) -> NSView {
        let container = OpenClickyRoundedView(cornerRadius: 17)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.fillColor = accentColor.withAlphaComponent(0.16)
        container.borderColor = accentColor.withAlphaComponent(0.12)
        let imageView = NSImageView(image: NSImage(systemSymbolName: systemName, accessibilityDescription: nil) ?? NSImage())
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .heavy)
        imageView.contentTintColor = accentColor
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 34),
            container.heightAnchor.constraint(equalToConstant: 34),
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18)
        ])
        return container
    }

    private func makeSmallIcon(systemName: String) -> NSView {
        let container = OpenClickyRoundedView(cornerRadius: 12)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.fillColor = accentColor.withAlphaComponent(0.13)
        let imageView = NSImageView(image: NSImage(systemSymbolName: systemName, accessibilityDescription: nil) ?? NSImage())
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .heavy)
        imageView.contentTintColor = accentColor
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 13),
            imageView.heightAnchor.constraint(equalToConstant: 13)
        ])
        return container
    }

    private func makeGlyphButton(systemName: String, action: @escaping () -> Void) -> NSButton {
        let button = OpenClickyClosureButton(systemName: systemName, title: nil, action: action)
        button.symbolPointSize = 16
        button.contentTintColor = NSColor.white.withAlphaComponent(0.66)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }

    private func makeActionButton(_ action: OpenClickyNotchCaptureAction) -> NSView {
        let button = OpenClickyActionPillButton(
            title: action.title,
            systemName: action.systemImage,
            isPrimary: action == .ask,
            action: { [weak self] in self?.submit(action) }
        )
        button.accentColor = accentColor
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func makeSuggestionButton(_ suggestion: OpenClickyNotchCaptureSuggestion) -> NSButton {
        let button = OpenClickyClosureButton(systemName: suggestion.systemImage, title: "\(suggestion.token)  \(suggestion.title)", action: { [weak self] in
            self?.applySuggestion(suggestion)
        })
        button.symbolPointSize = 10
        button.font = .systemFont(ofSize: 9, weight: .semibold)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.88)
        button.cornerRadius = 8
        button.fillColor = NSColor.white.withAlphaComponent(0.105)
        button.borderColor = NSColor.white.withAlphaComponent(0.10)
        return button
    }

    private func updateAccentColors() {
        waveformView.accentColor = accentColor
        updateButtons(in: actionStack)
        shellView.needsDisplay = true
    }

    private func updateButtons(in stack: NSStackView) {
        for case let button as OpenClickyActionPillButton in stack.arrangedSubviews {
            button.accentColor = accentColor
        }
    }

    private func updateVoiceLabels(for state: CompanionVoiceState) {
        switch state {
        case .listening:
            voiceTitleLabel.stringValue = "Listening"
            voiceSubtitleLabel.stringValue = "Release the shortcut to send this turn."
            waveformView.isActive = true
        case .processing:
            voiceTitleLabel.stringValue = "Thinking"
            voiceSubtitleLabel.stringValue = "Transcribing and routing the request."
            waveformView.isActive = false
        case .responding:
            voiceTitleLabel.stringValue = "Speaking"
            voiceSubtitleLabel.stringValue = "Answering through the existing fast voice stack."
            waveformView.isActive = false
        case .idle:
            voiceTitleLabel.stringValue = "Ready"
            voiceSubtitleLabel.stringValue = "OpenClicky is ready."
            waveformView.isActive = false
        }
    }

    private func updateSuggestions() {
        suggestionStack.arrangedSubviews.forEach { view in
            suggestionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let trigger = currentTrigger() else {
            let label = NSTextField(labelWithString: "Type / or @ for context")
            label.font = .systemFont(ofSize: 9, weight: .semibold)
            label.textColor = NSColor.white.withAlphaComponent(0.44)
            suggestionStack.addArrangedSubview(label)
            return
        }

        let candidates = OpenClickyNotchCaptureSuggestion.candidates(for: trigger.kind)
        let filtered = trigger.query.isEmpty
            ? candidates
            : candidates.filter {
                $0.token.dropFirst().localizedCaseInsensitiveContains(trigger.query)
                    || $0.title.localizedCaseInsensitiveContains(trigger.query)
            }
        for suggestion in filtered.prefix(5) {
            suggestionStack.addArrangedSubview(makeSuggestionButton(suggestion))
        }
    }

    private func submit(_ action: OpenClickyNotchCaptureAction) {
        let submitted = routedText(for: action)
        guard !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submitText?(submitted)
        textField.stringValue = ""
        updateSuggestions()
        dismiss?()
    }

    private func routedText(for action: OpenClickyNotchCaptureAction) -> String {
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = Self.strippingLeadingAgentToken(from: trimmed)
        if action == .agent || stripped.didStrip {
            let request = stripped.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else { return "" }
            return "ask an agent to \(request)"
        }
        return trimmed
    }

    private static func strippingLeadingAgentToken(from rawText: String) -> (text: String, didStrip: Bool) {
        var value = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = value.lowercased()
        for token in ["/agent", "@agent"] {
            if lowercased == token {
                return ("", true)
            }
            if lowercased.hasPrefix("\(token) ") {
                value.removeFirst(token.count)
                return (value.trimmingCharacters(in: .whitespacesAndNewlines), true)
            }
        }
        return (value, false)
    }

    private func applySuggestion(_ suggestion: OpenClickyNotchCaptureSuggestion) {
        guard let trigger = currentTrigger() else { return }
        var value = textField.stringValue
        value.replaceSubrange(trigger.range, with: "\(suggestion.token) ")
        textField.stringValue = value
        updateSuggestions()
        window?.makeFirstResponder(textField)
    }

    private func currentTrigger() -> (kind: OpenClickyNotchCaptureSuggestion.Kind, query: String, range: Range<String.Index>)? {
        let value = textField.stringValue
        guard let tokenRange = value.range(of: #"(?<!\S)[/@][A-Za-z0-9_-]*$"#, options: .regularExpression) else {
            return nil
        }
        let token = String(value[tokenRange])
        guard let first = token.first,
              let kind = OpenClickyNotchCaptureSuggestion.Kind(trigger: first) else {
            return nil
        }
        return (kind, String(token.dropFirst()), tokenRange)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if mode == .collapsed {
            expand?()
            return
        }
        super.mouseDown(with: event)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit(.ask)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss?()
            return true
        }
        return false
    }
}

private final class OpenClickyRoundedView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderColor: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat { didSet { needsDisplay = true } }

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        self.cornerRadius = 12
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        if borderColor.alphaComponent > 0 {
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

private final class OpenClickyActionPillButton: NSControl {
    private let label: String
    private let systemName: String
    private let isPrimary: Bool
    private let onAction: () -> Void

    var accentColor: NSColor = .systemBlue { didSet { needsDisplay = true } }

    init(title: String, systemName: String, isPrimary: Bool, action: @escaping () -> Void) {
        self.label = title
        self.systemName = systemName
        self.isPrimary = isPrimary
        self.onAction = action
        super.init(frame: .zero)
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        self.label = ""
        self.systemName = "circle"
        self.isPrimary = false
        self.onAction = {}
        super.init(coder: coder)
        wantsLayer = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 96, height: 40)
    }

    override func mouseDown(with event: NSEvent) {
        onAction()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius = rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let fill = isPrimary ? accentColor.withAlphaComponent(0.92) : NSColor.white.withAlphaComponent(0.10)
        fill.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(isPrimary ? 0.16 : 0.13).setStroke()
        path.lineWidth = 1
        path.stroke()

        let iconSize = min(16, rect.height - 14)
        let iconX = rect.minX + 14
        let iconY = rect.midY - iconSize / 2
        if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
            image.isTemplate = true
            let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
            NSGraphicsContext.saveGraphicsState()
            (isPrimary ? NSColor.white : NSColor.white.withAlphaComponent(0.9)).set()
            image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }

        let titleRect = NSRect(x: iconX + iconSize + 8, y: rect.minY + 1, width: max(10, rect.width - iconSize - 30), height: rect.height - 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .heavy),
            .foregroundColor: NSColor.white.withAlphaComponent(isPrimary ? 1.0 : 0.92),
            .paragraphStyle: paragraph
        ]
        (label as NSString).draw(in: titleRect, withAttributes: attributes)
    }
}

private final class OpenClickyClosureButton: NSButton {
    var onAction: (() -> Void)?
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderColor: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 12 { didSet { needsDisplay = true } }
    var symbolPointSize: CGFloat = 14 { didSet { updateImageConfiguration() } }

    init(systemName: String, title: String?, action: @escaping () -> Void) {
        self.onAction = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        imagePosition = title == nil ? .imageOnly : .imageLeading
        self.title = title ?? ""
        target = self
        self.action = #selector(runAction)
        focusRingType = .none
        wantsLayer = true
        updateImageConfiguration()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        if fillColor.alphaComponent > 0 || borderColor.alphaComponent > 0 {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            fillColor.setFill()
            path.fill()
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        super.draw(dirtyRect)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func runAction() {
        onAction?()
    }

    private func updateImageConfiguration() {
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .heavy)
    }
}

private final class OpenClickyNotchWaveformNSView: NSView {
    var audioPowerLevel: CGFloat = 0 { didSet { needsDisplay = true } }
    var accentColor: NSColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0) { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let barCount = 18
        let spacing: CGFloat = 5
        let barWidth: CGFloat = 5
        let normalizedPower = min(max(audioPowerLevel, 0), 1)
        let maxHeight = bounds.height
        let activeAlpha: CGFloat = isActive ? 0.92 : 0.44
        let fill = accentColor.withAlphaComponent(activeAlpha)
        fill.setFill()

        for index in 0..<barCount {
            let wave = CGFloat((sin(Double(index) * 0.86) + 1.0) / 2.0)
            let floor: CGFloat = isActive ? 8 : 5
            let height = min(maxHeight, floor + normalizedPower * 22 + wave * (isActive ? 12 : 5))
            let x = CGFloat(index) * (barWidth + spacing)
            let y = (maxHeight - height) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.fill()
        }
    }
}
