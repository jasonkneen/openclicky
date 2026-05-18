//
//  OpenClickyNotchCaptureWindowManager.swift
//  leanring-buddy
//
//  Top-of-screen capture surface for OpenClicky. It anchors beneath the
//  MacBook Pro notch when the built-in display is present, otherwise beneath
//  the active main display while docked. This replaces the old cursor-local
//  older floating text interface and mirrors Clicky's top listening affordance.
//

import AppKit
import SwiftUI

private final class OpenClickyNotchCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum OpenClickyNotchVoicePhase {
    case idle
    case listening
    case processing
    case responding
}

private enum OpenClickyNotchCaptureAction: String, CaseIterable {
    case ask
    case aiText
    case agent

    var title: String {
        switch self {
        case .ask: return "Voice"
        case .aiText: return "Text"
        case .agent: return "Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .ask: return "waveform"
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
    private var mainPanel: OpenClickyNotchCapturePanel?
    private var contentView: OpenClickyNotchCaptureRootView?
    private var mirroredStatusPanels: [CGDirectDisplayID: OpenClickyNotchCapturePanel] = [:]
    private var mirroredStatusContentViews: [CGDirectDisplayID: OpenClickyNotchCaptureRootView] = [:]
    private var mainHostingView: NSHostingView<OpenClickyNotchPanelView>?
    private var mainPanelGlobalClickMonitor: Any?
    private var mainPanelLocalClickMonitor: Any?
    private var mainPanelEscapeKeyMonitor: Any?
    private var mainPanelContentSizeObserver: NSObjectProtocol?
    private var isMainPanelPinned = false
    private var activeMode: ActiveMode?
    private var persistentAccentColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
    private var persistentSubmitText: ((String) -> Void)?
    private var persistentShowMainPanel: (() -> Void)?
    private var persistentHasRunningAgentWork = false
    private var anchorScreenOverride: NSScreen?
    private var collapsedHoverProbeTimer: Timer?
    private var foregroundAppActivationObserver: NSObjectProtocol?
    private var foregroundAppIcon: NSImage?
    private var foregroundAppName: String = "Current app"

    // AppKit window frames are in points, not pixels. Keep these as real
    // point sizes; do not divide by backingScaleFactor or the content clips on
    // Retina displays.
    private static let expandedPanelWidth: CGFloat = 520
    private static let mainPanelWidth: CGFloat = 430
    private static let mainPanelHeight: CGFloat = 620
    private static let mainPanelMinimumSize = NSSize(width: 356, height: 300)
    private static let mainPanelMaximumSize = NSSize(width: 760, height: 820)
    private static let statusPanelWidthScale: CGFloat = 0.20
    private static let statusPanelHorizontalNudge: CGFloat = 0
    private static let minimumBuiltInCollapsedPanelWidth: CGFloat = 90
    private static let minimumVoicePanelWidth: CGFloat = 96
    private static let minimumExternalCollapsedPanelWidth: CGFloat = 56
    private static let maximumExternalCollapsedPanelWidth: CGFloat = 68
    private static let maximumExpandedStatusPanelWidth: CGFloat = 128
    private static let statusLozengeHeight: CGFloat = 38
    private static let collapsedPanelHeight: CGFloat = statusLozengeHeight
    private static let expandedHandleWidth: CGFloat = 96
    private static let expandedHandleHeight: CGFloat = 10
    private static let textPanelHeight: CGFloat = 226
    private static let mainPanelMaximumHeight: CGFloat = 720
    private static let voicePanelHeight: CGFloat = statusLozengeHeight
    private static let topGap: CGFloat = 0
    private static let noNotchScreenTopOverlap: CGFloat = 2
    private static let notchClearanceGap: CGFloat = 4
    private static let mainPanelGapBelowCapture: CGFloat = 10
    private static let screenEdgePadding: CGFloat = 12
    private static let escapeKeyCode: UInt16 = 53

    init() {
        mainPanelContentSizeObserver = NotificationCenter.default.addObserver(
            forName: .clickyPanelContentSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resizeVisibleMainPanelToCurrentContent(animated: true)
            }
        }
        let foregroundApp = Self.detectForegroundApp()
        foregroundAppIcon = foregroundApp.icon
        foregroundAppName = foregroundApp.name
        foregroundAppActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let bundleIdentifier = app.bundleIdentifier
            let bundlePath = app.bundleURL?.path
            let appName = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Current app"

            Task { @MainActor [weak self, bundleIdentifier, bundlePath, appName] in
                self?.updateForegroundAppIcon(
                    bundleIdentifier: bundleIdentifier,
                    bundlePath: bundlePath,
                    name: appName
                )
            }
        }
    }

    deinit {
        if let observer = mainPanelContentSizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = foregroundAppActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func showPersistentPill(
        companionManager: CompanionManager,
        accentTheme: ClickyAccentTheme? = nil,
        submitText: @escaping (String) -> Void
    ) {
        activeMode = .collapsedText
        let collapsedWidth = Self.collapsedPanelWidth(for: preferredAnchorScreen())
        ensureCaptureContentView(width: collapsedWidth, height: Self.collapsedPanelHeight)
        let accentColor = Self.nsAccentColor(for: accentTheme)
        persistentHasRunningAgentWork = Self.hasRunningAgentWork(in: companionManager)
        persistentAccentColor = accentColor
        persistentSubmitText = submitText
        persistentShowMainPanel = { [weak self, weak companionManager] in
            guard let companionManager else { return }
            self?.showMainPanel(companionManager: companionManager)
        }
        contentView?.configureCollapsed(
            accentColor: accentColor,
            foregroundAppIcon: foregroundAppIcon,
            foregroundAppName: foregroundAppName,
            hasRunningAgentWork: persistentHasRunningAgentWork,
            expand: { [weak self] in
                self?.pinAnchorScreenToPointerIfNeeded()
                self?.persistentShowMainPanel?()
            },
            dismiss: { [weak self] in self?.collapseToPill(accentColor: accentColor, submitText: submitText) }
        )
        startCollapsedHoverProbe()
        showPanel(activating: false, width: collapsedWidth, height: Self.collapsedPanelHeight)
        syncMirroredStatusPanels(
            width: collapsedWidth,
            height: Self.collapsedPanelHeight,
            widthForScreen: { Self.collapsedPanelWidth(for: $0) }
        ) { [weak self] view, screen in
            view.configureCollapsed(
                accentColor: accentColor,
                foregroundAppIcon: self?.foregroundAppIcon,
                foregroundAppName: self?.foregroundAppName ?? "Current app",
                hasRunningAgentWork: self?.persistentHasRunningAgentWork == true,
                expand: { [weak self, weak screen] in
                    if let screen { self?.anchorScreenOverride = screen }
                    self?.persistentShowMainPanel?()
                },
                dismiss: {}
            )
        }
    }

    func showTextInput(accentTheme: ClickyAccentTheme? = nil, submitText: @escaping (String) -> Void) {
        let accentColor = Self.nsAccentColor(for: accentTheme)
        expandTextInput(accentColor: accentColor, submitText: submitText)
    }

    func updateVoiceState(_ voicePhase: OpenClickyNotchVoicePhase, audioPowerLevel: CGFloat) {
        switch voicePhase {
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
            stopCollapsedHoverProbe()
            activeMode = .voice
            ensureCaptureContentView(width: Self.voicePanelWidth(for: preferredAnchorScreen()), height: Self.voicePanelHeight)
            contentView?.configureVoice(
                phase: voicePhase,
                audioPowerLevel: audioPowerLevel,
                accentColor: Self.nsAccentColor(for: nil),
                foregroundAppIcon: foregroundAppIcon,
                foregroundAppName: foregroundAppName
            )
            let voiceWidth = Self.voicePanelWidth(for: preferredAnchorScreen())
            showPanel(activating: false, width: voiceWidth, height: Self.voicePanelHeight)
            syncMirroredStatusPanels(
                width: voiceWidth,
                height: Self.voicePanelHeight,
                widthForScreen: { Self.voicePanelWidth(for: $0) }
            ) { [weak self] view, _ in
                view.configureVoice(
                    phase: voicePhase,
                    audioPowerLevel: audioPowerLevel,
                    accentColor: Self.nsAccentColor(for: nil),
                    foregroundAppIcon: self?.foregroundAppIcon,
                    foregroundAppName: self?.foregroundAppName ?? "Current app"
                )
            }
        }
    }

    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {
        guard activeMode == .voice else { return }
        contentView?.updateAudioPowerLevel(audioPowerLevel)
        mirroredStatusContentViews.values.forEach { $0.updateAudioPowerLevel(audioPowerLevel) }
    }

    func hide() {
        panel?.orderOut(nil)
        hideMainPanel()
        stopCollapsedHoverProbe()
        hideMirroredStatusPanels()
        activeMode = nil
        anchorScreenOverride = nil
    }

    private func hideMainPanel() {
        mainPanel?.orderOut(nil)
        removeMainPanelClickOutsideMonitors()
        removeMainPanelEscapeKeyMonitor()
        if activeMode == .collapsedText {
            startCollapsedHoverProbe()
        }
    }

    private func collapseToPill(accentColor: NSColor, submitText: @escaping (String) -> Void) {
        activeMode = .collapsedText
        let collapsedWidth = Self.collapsedPanelWidth(for: preferredAnchorScreen())
        ensureCaptureContentView(width: collapsedWidth, height: Self.collapsedPanelHeight)
        contentView?.configureCollapsed(
            accentColor: accentColor,
            foregroundAppIcon: foregroundAppIcon,
            foregroundAppName: foregroundAppName,
            hasRunningAgentWork: persistentHasRunningAgentWork,
            expand: { [weak self] in
                self?.pinAnchorScreenToPointerIfNeeded()
                if let showMainPanel = self?.persistentShowMainPanel {
                    showMainPanel()
                } else {
                    self?.expandTextInput(accentColor: accentColor, submitText: submitText)
                }
            },
            dismiss: { [weak self] in self?.collapseToPill(accentColor: accentColor, submitText: submitText) }
        )
        startCollapsedHoverProbe()
        showPanel(activating: false, width: collapsedWidth, height: Self.collapsedPanelHeight)
        syncMirroredStatusPanels(
            width: collapsedWidth,
            height: Self.collapsedPanelHeight,
            widthForScreen: { Self.collapsedPanelWidth(for: $0) }
        ) { [weak self] view, screen in
            view.configureCollapsed(
                accentColor: accentColor,
                foregroundAppIcon: self?.foregroundAppIcon,
                foregroundAppName: self?.foregroundAppName ?? "Current app",
                hasRunningAgentWork: self?.persistentHasRunningAgentWork == true,
                expand: { [weak self, weak screen] in
                    if let screen { self?.anchorScreenOverride = screen }
                    if let showMainPanel = self?.persistentShowMainPanel {
                        showMainPanel()
                    } else {
                        self?.expandTextInput(accentColor: accentColor, submitText: submitText)
                    }
                },
                dismiss: {}
            )
        }
    }

    private func expandTextInput(accentColor: NSColor, submitText: @escaping (String) -> Void) {
        stopCollapsedHoverProbe()
        hideMirroredStatusPanels()
        activeMode = .text
        persistentAccentColor = accentColor
        persistentSubmitText = submitText
        ensureCaptureContentView(width: Self.expandedPanelWidth, height: Self.textPanelHeight)
        contentView?.configureText(
            accentColor: accentColor,
            submitText: submitText,
            dismiss: { [weak self] in self?.collapseToPill(accentColor: accentColor, submitText: submitText) }
        )
        showPanel(activating: true, width: Self.expandedPanelWidth, height: Self.textPanelHeight)
        contentView?.focusTextField()
    }

    func showMainInterfacePanel(companionManager: CompanionManager, focusedAgentSessionID: UUID? = nil) {
        showMainPanel(companionManager: companionManager, focusedAgentSessionID: focusedAgentSessionID)
    }

    private func showMainPanel(companionManager: CompanionManager, focusedAgentSessionID: UUID? = nil) {
        stopCollapsedHoverProbe()
        pinAnchorScreenToPointerIfNeeded()
        ensureMainPanel()
        let notchPanelView = OpenClickyNotchPanelView(
            companionManager: companionManager,
            isPanelPinned: isMainPanelPinned,
            initialFocusedAgentSessionID: focusedAgentSessionID,
            setPanelPinned: { [weak self] isPinned in
                self?.setMainPanelPinned(isPinned)
            },
            closePanel: { [weak self] in
                self?.hideMainPanel()
            }
        )
        let initialSize = preferredMainPanelSize()
        let hostingView = NSHostingView(rootView: notchPanelView)
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 28
        hostingView.layer?.masksToBounds = true
        if #available(macOS 10.15, *) {
            hostingView.layer?.cornerCurve = .continuous
        }
        let resizeContainer = OpenClickyMainPanelResizeContainerView(frame: NSRect(origin: .zero, size: initialSize))
        resizeContainer.autoresizingMask = [.width, .height]
        resizeContainer.isResizeEnabled = { [weak self] in self?.isMainPanelPinned == true }
        resizeContainer.addSubview(hostingView)
        mainPanel?.contentView = resizeContainer
        mainHostingView = hostingView
        let fittingSize = preferredMainPanelSize()
        showMainPanelWindow(activating: true, width: fittingSize.width, height: fittingSize.height)
    }

    private func syncMirroredStatusPanels(
        width: CGFloat,
        height: CGFloat,
        widthForScreen: ((NSScreen) -> CGFloat)? = nil,
        configure: (OpenClickyNotchCaptureRootView, NSScreen) -> Void
    ) {
        let primaryDisplayID = preferredAnchorScreen()?.displayID
        let screens = NSScreen.screens
        let activeDisplayIDs = Set(screens.map(\.displayID))

        for displayID in Array(mirroredStatusPanels.keys) where !activeDisplayIDs.contains(displayID) || displayID == primaryDisplayID {
            mirroredStatusPanels[displayID]?.orderOut(nil)
            if !activeDisplayIDs.contains(displayID) {
                mirroredStatusPanels[displayID] = nil
                mirroredStatusContentViews[displayID] = nil
            }
        }

        for screen in screens where screen.displayID != primaryDisplayID {
            let screenWidth = widthForScreen?(screen) ?? width
            let statusPanel = mirroredStatusPanel(for: screen, width: screenWidth, height: height)
            guard let statusView = mirroredStatusContentViews[screen.displayID] else { continue }
            let size = NSSize(width: screenWidth, height: height)
            statusPanel.setFrame(NSRect(origin: statusPanel.frame.origin, size: size), display: true, animate: false)
            statusView.setCanvas(size: size)
            configure(statusView, screen)
            let x = Self.centeredX(for: size, on: screen)
            let y = Self.statusLozengeY(for: size, on: screen)
            statusPanel.setFrameOrigin(NSPoint(x: x, y: y))
            statusPanel.orderFrontRegardless()
        }
    }

    private func mirroredStatusPanel(for screen: NSScreen, width: CGFloat, height: CGFloat) -> OpenClickyNotchCapturePanel {
        if let existing = mirroredStatusPanels[screen.displayID] {
            return existing
        }
        let statusPanel = Self.makeStatusPanel(width: width, height: height)
        let rootView = OpenClickyNotchCaptureRootView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        rootView.autoresizingMask = [.width, .height]
        statusPanel.contentView = rootView
        mirroredStatusPanels[screen.displayID] = statusPanel
        mirroredStatusContentViews[screen.displayID] = rootView
        return statusPanel
    }

    private func hideMirroredStatusPanels() {
        mirroredStatusPanels.values.forEach { $0.orderOut(nil) }
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

    private func showMainPanelWindow(activating: Bool, width: CGFloat, height: CGFloat) {
        resizeAndRepositionMainPanel(width: width, height: height)
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            mainPanel?.makeKeyAndOrderFront(nil)
        } else {
            mainPanel?.orderFrontRegardless()
        }
        mainPanel?.orderFrontRegardless()
        installMainPanelEscapeKeyMonitor()
        installMainPanelClickOutsideMonitors()
    }

    private func setMainPanelPinned(_ isPinned: Bool) {
        guard isMainPanelPinned != isPinned else { return }
        isMainPanelPinned = isPinned

        applyMainPanelResizeBehavior()

        if isPinned {
            removeMainPanelClickOutsideMonitors()
            mainPanel?.makeKeyAndOrderFront(nil)
            mainPanel?.orderFrontRegardless()
        } else if mainPanel?.isVisible == true {
            resizeVisibleMainPanelToCurrentContent(animated: true)
            installMainPanelClickOutsideMonitors()
        }
    }

    private func installMainPanelClickOutsideMonitors() {
        removeMainPanelClickOutsideMonitors()
        guard !isMainPanelPinned else { return }

        mainPanelGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissMainPanelIfClickIsOutside()
            }
        }

        mainPanelLocalClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.dismissMainPanelIfClickIsOutside()
            }
            return event
        }
    }

    private func removeMainPanelClickOutsideMonitors() {
        if let monitor = mainPanelGlobalClickMonitor {
            NSEvent.removeMonitor(monitor)
            mainPanelGlobalClickMonitor = nil
        }
        if let monitor = mainPanelLocalClickMonitor {
            NSEvent.removeMonitor(monitor)
            mainPanelLocalClickMonitor = nil
        }
    }

    private func installMainPanelEscapeKeyMonitor() {
        removeMainPanelEscapeKeyMonitor()
        mainPanelEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            Task { @MainActor [weak self] in
                self?.hideMainPanel()
            }
            return nil
        }
    }

    private func removeMainPanelEscapeKeyMonitor() {
        if let monitor = mainPanelEscapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            mainPanelEscapeKeyMonitor = nil
        }
    }

    private func dismissMainPanelIfClickIsOutside() {
        guard !isMainPanelPinned, let mainPanel, mainPanel.isVisible else { return }
        let clickLocation = NSEvent.mouseLocation
        if mainPanel.frame.contains(clickLocation) {
            return
        }
        if let panel, panel.isVisible, panel.frame.contains(clickLocation) {
            return
        }
        hideMainPanel()
    }

    private static func makeStatusPanel(width: CGFloat, height: CGFloat) -> OpenClickyNotchCapturePanel {
        let capturePanel = OpenClickyNotchCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        capturePanel.isFloatingPanel = true
        capturePanel.level = .statusBar
        capturePanel.isOpaque = false
        capturePanel.backgroundColor = .clear
        capturePanel.hasShadow = false
        capturePanel.hidesOnDeactivate = false
        capturePanel.isReleasedWhenClosed = false
        capturePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        capturePanel.isMovableByWindowBackground = false
        capturePanel.titleVisibility = .hidden
        capturePanel.titlebarAppearsTransparent = true
        return capturePanel
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        panel = Self.makeStatusPanel(width: Self.expandedPanelWidth, height: Self.textPanelHeight)
    }

    private func ensureMainPanel() {
        guard mainPanel == nil else { return }

        let interfacePanel = OpenClickyNotchCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.mainPanelWidth, height: Self.mainPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        interfacePanel.isFloatingPanel = true
        interfacePanel.level = .statusBar
        interfacePanel.isOpaque = false
        interfacePanel.backgroundColor = .clear
        // Keep shadows inside the SwiftUI surface. AppKit's window shadow can
        // create a faint rectangular/rounded outline around transparent panels,
        // especially over bright browser content.
        interfacePanel.hasShadow = false
        interfacePanel.hidesOnDeactivate = false
        interfacePanel.isReleasedWhenClosed = false
        interfacePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        interfacePanel.isMovableByWindowBackground = true
        interfacePanel.titleVisibility = .hidden
        interfacePanel.titlebarAppearsTransparent = true
        interfacePanel.minSize = Self.mainPanelMinimumSize
        interfacePanel.contentMinSize = Self.mainPanelMinimumSize
        interfacePanel.maxSize = Self.mainPanelMaximumSize
        interfacePanel.contentMaxSize = Self.mainPanelMaximumSize

        mainPanel = interfacePanel
        applyMainPanelResizeBehavior()
    }

    private func ensureCaptureContentView(width: CGFloat, height: CGFloat) {
        ensurePanel()
        if contentView != nil { return }
        let rootView = OpenClickyNotchCaptureRootView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        rootView.autoresizingMask = [.width, .height]
        panel?.contentView = rootView
        contentView = rootView
        mainHostingView = nil
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
        repositionMainPanelIfVisible()
    }

    private func resizeAndRepositionMainPanel(width: CGFloat, height: CGFloat) {
        guard let mainPanel else { return }
        let size = NSSize(width: width, height: height)
        let origin = isMainPanelPinned ? mainPanel.frame.origin : mainPanelOrigin(for: size)
        mainPanel.setFrame(
            NSRect(origin: origin, size: size),
            display: true,
            animate: false
        )
        mainHostingView?.frame = NSRect(origin: .zero, size: size)
    }

    private func resizeVisibleMainPanelToCurrentContent(animated: Bool) {
        guard let mainPanel, mainPanel.isVisible else { return }
        if isMainPanelPinned {
            let size = constrainedMainPanelSize(mainPanel.frame.size)
            mainPanel.setFrame(
                NSRect(origin: mainPanel.frame.origin, size: size),
                display: true,
                animate: false
            )
            mainHostingView?.frame = NSRect(origin: .zero, size: size)
            mainHostingView?.needsLayout = true
            return
        }

        let size = preferredMainPanelSize()
        let origin: NSPoint
        if animated {
            // Keep the panel anchored where the user is already reading it.
            // Tab/content changes should resize the dialog in place instead of
            // walking the whole window up the screen as the fitted height changes.
            origin = mainPanel.frame.origin
        } else {
            origin = mainPanelOrigin(for: size)
        }
        let targetFrame = NSRect(origin: origin, size: size)

        guard targetFrame.integral != mainPanel.frame.integral else { return }

        let updateHostingFrame = { [weak self] in
            self?.mainHostingView?.frame = NSRect(origin: .zero, size: size)
            self?.mainHostingView?.needsLayout = true
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                mainPanel.animator().setFrame(targetFrame, display: true)
            } completionHandler: {
                updateHostingFrame()
            }
        } else {
            mainPanel.setFrame(targetFrame, display: true, animate: false)
            updateHostingFrame()
        }
    }

    private func preferredMainPanelSize() -> NSSize {
        if isMainPanelPinned, let mainPanel {
            return constrainedMainPanelSize(mainPanel.frame.size)
        }

        guard let fittingHeight = mainHostingView?.fittingSize.height, fittingHeight > 0 else {
            return NSSize(width: Self.mainPanelWidth, height: Self.mainPanelHeight)
        }
        let height = min(max(ceil(fittingHeight), Self.mainPanelMinimumSize.height), Self.mainPanelMaximumHeight)
        return NSSize(width: Self.mainPanelWidth, height: height)
    }

    private func constrainedMainPanelSize(_ size: NSSize) -> NSSize {
        NSSize(
            width: min(max(size.width, Self.mainPanelMinimumSize.width), Self.mainPanelMaximumSize.width),
            height: min(max(size.height, Self.mainPanelMinimumSize.height), Self.mainPanelMaximumSize.height)
        )
    }

    private func applyMainPanelResizeBehavior() {
        guard let mainPanel else { return }
        if isMainPanelPinned {
            // Keep the panel visually custom and chrome-free. A borderless
            // AppKit resize frame only exposes a tiny corner target, so the
            // content container adds its own wider edge/corner resize handles.
            mainPanel.styleMask.formUnion(.resizable)
            mainPanel.styleMask.remove(.fullSizeContentView)
            mainPanel.styleMask.remove(.titled)
        } else {
            mainPanel.styleMask.remove(.resizable)
            mainPanel.styleMask.remove(.fullSizeContentView)
            mainPanel.styleMask.remove(.titled)
        }
        mainPanel.titleVisibility = .hidden
        mainPanel.titlebarAppearsTransparent = true
        hideMainPanelWindowControls()
        mainPanel.minSize = Self.mainPanelMinimumSize
        mainPanel.contentMinSize = Self.mainPanelMinimumSize
        mainPanel.maxSize = Self.mainPanelMaximumSize
        mainPanel.contentMaxSize = Self.mainPanelMaximumSize
        if let contentView = mainPanel.contentView {
            mainPanel.invalidateCursorRects(for: contentView)
        }
    }

    private func hideMainPanelWindowControls() {
        guard let mainPanel else { return }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            mainPanel.standardWindowButton(button)?.isHidden = true
            mainPanel.standardWindowButton(button)?.isEnabled = false
        }
    }

    private func repositionMainPanelIfVisible() {
        guard !isMainPanelPinned, let mainPanel, mainPanel.isVisible else { return }
        // The status/notch bar can resize or move as tasks start, finish, or
        // buttons are pressed. Once the main panel is visible, keep its origin
        // stable so those unrelated bar updates do not make the panel drift up
        // the screen. Fresh opens still use `resizeAndRepositionMainPanel`.
        mainPanel.setFrameOrigin(mainPanel.frame.origin)
    }

    private func positionPanel(size: NSSize) {
        guard let panel, let screen = preferredAnchorScreen() else { return }
        let x = Self.centeredX(for: size, on: screen)
        let y = Self.statusLozengeY(for: size, on: screen)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func positionMainPanel(size: NSSize) {
        guard !isMainPanelPinned, let mainPanel else { return }
        mainPanel.setFrameOrigin(mainPanelOrigin(for: size))
    }

    private func mainPanelOrigin(for size: NSSize) -> NSPoint {
        guard let screen = preferredAnchorScreen() else { return mainPanel?.frame.origin ?? .zero }
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let usableFrame = visibleFrame.isEmpty ? fullFrame : visibleFrame
        let captureHeight = panel?.isVisible == true ? panel?.frame.height ?? Self.collapsedPanelHeight : Self.collapsedPanelHeight
        let x = Self.centeredX(for: size, on: screen)
        let preferredY = screen.frame.maxY - captureHeight - Self.mainPanelGapBelowCapture - size.height
        let minY = usableFrame.minY + Self.screenEdgePadding
        let y = max(preferredY, minY)
        return NSPoint(x: x, y: y)
    }


    private func preferredAnchorScreen() -> NSScreen? {
        if let override = anchorScreenOverride, NSScreen.screens.contains(where: { $0.displayID == override.displayID }) {
            return override
        }
        anchorScreenOverride = nil
        return Self.preferredAnchorScreen()
    }

    private func pinAnchorScreenToPointerIfNeeded() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
        anchorScreenOverride = screen
    }

    private func startCollapsedHoverProbe() {
        guard collapsedHoverProbeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeCollapsedNotchHover()
            }
        }
        collapsedHoverProbeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopCollapsedHoverProbe() {
        collapsedHoverProbeTimer?.invalidate()
        collapsedHoverProbeTimer = nil
    }

    private func probeCollapsedNotchHover() {
        guard activeMode == .collapsedText, mainPanel?.isVisible != true else {
            stopCollapsedHoverProbe()
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        guard let hoveredScreen = NSScreen.screens.first(where: { Self.notchHoverRegion(on: $0).contains(mouseLocation) }) else { return }

        if anchorScreenOverride?.displayID != hoveredScreen.displayID {
            anchorScreenOverride = hoveredScreen
            resizeAndReposition(width: Self.collapsedPanelWidth(for: hoveredScreen), height: Self.collapsedPanelHeight)
        }
        persistentShowMainPanel?()
    }

    private static func notchHoverRegion(on screen: NSScreen) -> NSRect {
        let width = max(collapsedPanelWidth(for: screen) + 28, 104)
        let height = max(collapsedPanelHeight + 24, 36)
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: statusLozengeY(for: NSSize(width: width, height: height), on: screen) - 12,
            width: width,
            height: height
        )
    }

    private static func statusLozengeY(for size: NSSize, on screen: NSScreen) -> CGFloat {
        if notchReservedTopInset(on: screen) != nil {
            // On a MacBook notch screen the status bar should hug the physical
            // notch at the top edge, not sit below the menu/notch safe area.
            // Clipping a couple of points at the top also hides the top seam,
            // matching the no-notch external-display treatment.
            return screen.frame.maxY - size.height + Self.noNotchScreenTopOverlap
        }
        return screen.frame.maxY - size.height - Self.topGap + Self.noNotchScreenTopOverlap
    }

    private static func centeredX(for size: NSSize, on screen: NSScreen) -> CGFloat {
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let usableFrame = visibleFrame.isEmpty ? fullFrame : visibleFrame
        let centeredX = fullFrame.midX - size.width / 2 + Self.statusPanelHorizontalNudge

        guard size.width + (Self.screenEdgePadding * 2) > usableFrame.width else {
            return centeredX
        }

        let minX = usableFrame.minX + Self.screenEdgePadding
        let maxX = usableFrame.maxX - size.width - Self.screenEdgePadding
        return min(max(centeredX, minX), maxX)
    }

    private static func voicePanelWidth(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return Self.minimumBuiltInCollapsedPanelWidth }

        if isLikelyBuiltInNotchScreen(screen) {
            // Voice should not fall back to the older tiny listening notch. The
            // built-in notch display keeps the same notch-surrounding bar.
            return max(Self.minimumVoicePanelWidth, collapsedPanelWidth(for: screen))
        }

        // External displays normally keep a compact centered bar. Voice states
        // get the wider status canvas so the surface expands evenly left/right
        // only when OpenClicky has labels and waveform content to show.
        return expandedStatusPanelWidth(for: screen)
    }

    private static func collapsedPanelWidth(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return Self.minimumBuiltInCollapsedPanelWidth }

        if isLikelyBuiltInNotchScreen(screen) {
            let maximumSurroundingNotchWidth = max(Self.minimumBuiltInCollapsedPanelWidth, screen.visibleFrame.width - 48)
            let notchSurroundWidth = (physicalNotchWidth(on: screen).map { $0 + 32 } ?? 220) * Self.statusPanelWidthScale
            return min(
                Self.maximumExpandedStatusPanelWidth,
                max(Self.minimumBuiltInCollapsedPanelWidth, min(round(notchSurroundWidth), maximumSurroundingNotchWidth))
            )
        }

        let visibleWidth = screen.visibleFrame.isEmpty ? screen.frame.width : screen.visibleFrame.width
        let proportionalWidth = round(visibleWidth * 0.14 * Self.statusPanelWidthScale)
        return min(
            Self.maximumExternalCollapsedPanelWidth,
            max(Self.minimumExternalCollapsedPanelWidth, proportionalWidth)
        )
    }

    private static func expandedStatusPanelWidth(for screen: NSScreen) -> CGFloat {
        let visibleWidth = screen.visibleFrame.isEmpty ? screen.frame.width : screen.visibleFrame.width
        let oneThirdWidth = round((visibleWidth / 3) * Self.statusPanelWidthScale)
        return min(
            Self.maximumExpandedStatusPanelWidth,
            max(Self.minimumVoicePanelWidth, oneThirdWidth)
        )
    }

    private static func hasRunningAgentWork(in companionManager: CompanionManager) -> Bool {
        companionManager.codexAgentSessions.contains { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }
    }

    private static func preferredAnchorScreen() -> NSScreen? {
        let screens = NSScreen.screens

        if let keyWindow = NSApp.keyWindow,
           !(keyWindow is OpenClickyNotchCapturePanel),
           let keyWindowScreen = keyWindow.screen {
            return keyWindowScreen
        }
        if let mainWindow = NSApp.mainWindow,
           !(mainWindow is OpenClickyNotchCapturePanel),
           let mainWindowScreen = mainWindow.screen {
            return mainWindowScreen
        }
        let mouseLocation = NSEvent.mouseLocation
        if let screenUnderPointer = screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screenUnderPointer
        }
        if let main = NSScreen.main {
            return main
        }
        if let builtInNotchScreen = screens.first(where: isLikelyBuiltInNotchScreen) {
            return builtInNotchScreen
        }
        return screens.first
    }

    private static func isLikelyBuiltInNotchScreen(_ screen: NSScreen) -> Bool {
        let name = screen.localizedName.lowercased()
        let looksBuiltIn = name.contains("built-in")
            || name.contains("liquid retina")
            || name.contains("macbook")
        return looksBuiltIn && notchReservedTopInset(on: screen) != nil
    }

    private static func notchReservedTopInset(on screen: NSScreen) -> CGFloat? {
        let safeTopInset: CGFloat
        let auxiliaryTopInset: CGFloat
        if #available(macOS 12.0, *) {
            safeTopInset = screen.safeAreaInsets.top
            let auxiliaryTopAreas = [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            auxiliaryTopInset = auxiliaryTopAreas
                .map { max(0, screen.frame.maxY - $0.minY) }
                .max() ?? 0
        } else {
            safeTopInset = 0
            auxiliaryTopInset = 0
        }
        let visibleTopInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let notchInset = max(safeTopInset, auxiliaryTopInset)

        if notchInset > visibleTopInset + 2 {
            return notchInset
        }
        if auxiliaryTopInset > 0 {
            return auxiliaryTopInset
        }
        // Fallback: many MacBook notch screens report safeAreaInsets.top >= 32
        if #available(macOS 12.0, *), safeTopInset > 30 {
            return safeTopInset
        }
        return nil
    }

    private static func physicalNotchWidth(on screen: NSScreen) -> CGFloat? {
        guard #available(macOS 12.0, *),
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              !leftArea.isEmpty,
              !rightArea.isEmpty else {
            return nil
        }

        let gap = rightArea.minX - leftArea.maxX
        return gap > 0 ? gap : nil
    }

    private func updateForegroundAppIcon(bundleIdentifier: String?, bundlePath: String?, name: String) {
        guard bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        foregroundAppIcon = NSWorkspace.shared.icon(forFile: bundlePath ?? "")
        foregroundAppName = name
        contentView?.updateForegroundApp(icon: foregroundAppIcon, name: foregroundAppName)
        mirroredStatusContentViews.values.forEach { $0.updateForegroundApp(icon: foregroundAppIcon, name: foregroundAppName) }
    }

    private static func detectForegroundApp() -> (icon: NSImage?, name: String) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return (nil, "Current app")
        }
        let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "")
        let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Current app"
        return (icon, name)
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

        case .cyan:
            return NSColor(calibratedWhite: 0.97, alpha: 1.0)
        case .lime:
            return NSColor(calibratedWhite: 0.97, alpha: 1.0)
        case .orange:
            return NSColor(calibratedWhite: 0.97, alpha: 1.0)
        case .violet:
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
    private let shellGlassView = OpenClickyLiquidGlassBackdropView(cornerRadius: 24)
    private let shellView = OpenClickyRoundedView(cornerRadius: 24)
    private let rightEdgeGradientView = OpenClickyNotchRightEdgeGradientView()
    private let textStack = NSStackView()
    private let voiceStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Ask OpenClicky")
    private let subtitleLabel = NSTextField(labelWithString: "Menu-bar notch surface, existing fast voice stack, local agent handoff.")
    private let inputShell = OpenClickyRoundedView(cornerRadius: 21)
    private let textField = NSTextField()
    private let suggestionStack = NSStackView()
    private let actionStack = NSStackView()
    private let voiceTitleLabel = NSTextField(labelWithString: "Listening")
    private let voiceSubtitleLabel = NSTextField(labelWithString: "Release the shortcut to send this turn.")
    private let voiceNotchSpacer = NSView()
    private let waveformView = OpenClickyNotchWaveformNSView()
    private let collapsedAppIconView = NSImageView()
    private let collapsedPlayIconView = NSImageView()
    private let collapsedAgentDotsView = OpenClickyNotchDotsNSView()
    private let voiceAppIconView = NSImageView()
    private let collapsedAppNameLabel = NSTextField(labelWithString: "Current app")
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

    func configureCollapsed(accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, hasRunningAgentWork: Bool, expand: @escaping () -> Void, dismiss: @escaping () -> Void) {
        mode = .collapsed
        self.accentColor = accentColor
        self.expand = expand
        self.dismiss = dismiss
        textStack.isHidden = true
        voiceStack.isHidden = true
        collapsedAppIconView.isHidden = foregroundAppIcon == nil
        collapsedAppNameLabel.isHidden = false
        collapsedPlayIconView.isHidden = hasRunningAgentWork
        collapsedPlayIconView.contentTintColor = accentColor
        collapsedAgentDotsView.isHidden = !hasRunningAgentWork
        collapsedAgentDotsView.accentColor = accentColor
        collapsedAgentDotsView.isActive = hasRunningAgentWork
        notchHandle.isHidden = true
        shellView.isHidden = false
        shellGlassView.isHidden = false
        shellGlassView.configure(cornerRadius: 17, roundsTopCorners: false, accentColor: accentColor, strength: .compact)
        shellView.roundsTopCorners = false
        shellView.cornerRadius = 17
        shellView.fillColor = OpenClickyLiquidGlassBackdropView.isLiquidGlassAvailable ? NSColor.black.withAlphaComponent(0.34) : NSColor.black.withAlphaComponent(0.93)
        shellView.borderColor = .clear
        shellView.roundedShadowColor = nil
        shellView.roundedShadowBlurRadius = 0
        shellView.roundedShadowOffset = .zero
        configureRightEdgeGradient(isVisible: true, intensity: hasRunningAgentWork ? 0.42 : 0.34)
        updateForegroundApp(icon: foregroundAppIcon, name: foregroundAppName)
        collapsedAppIconView.isHidden = foregroundAppIcon == nil
        collapsedAppNameLabel.isHidden = false
        collapsedPlayIconView.isHidden = hasRunningAgentWork
        collapsedAgentDotsView.isHidden = !hasRunningAgentWork
        needsDisplay = true
    }

    func configureText(accentColor: NSColor, submitText: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
        mode = .text
        self.accentColor = accentColor
        self.submitText = submitText
        self.dismiss = dismiss
        self.expand = nil
        notchHandle.isHidden = true
        shellView.isHidden = false
        shellGlassView.isHidden = false
        shellGlassView.configure(cornerRadius: 24, roundsTopCorners: true, accentColor: accentColor, strength: .expanded)
        shellView.roundsTopCorners = true
        textStack.isHidden = false
        voiceStack.isHidden = true
        collapsedAppIconView.isHidden = true
        collapsedAppNameLabel.isHidden = true
        collapsedPlayIconView.isHidden = true
        collapsedAgentDotsView.isHidden = true
        shellView.cornerRadius = 24
        shellView.fillColor = OpenClickyLiquidGlassBackdropView.isLiquidGlassAvailable ? NSColor.black.withAlphaComponent(0.44) : NSColor(calibratedRed: 0.025, green: 0.036, blue: 0.032, alpha: 0.96)
        shellView.borderColor = NSColor.white.withAlphaComponent(0.085)
        shellView.roundedShadowColor = NSColor.black.withAlphaComponent(0.46)
        shellView.roundedShadowBlurRadius = 16
        shellView.roundedShadowOffset = NSSize(width: 0, height: -8)
        configureRightEdgeGradient(isVisible: false, intensity: 0)
        updateAccentColors()
        updateSuggestions()
        textField.stringValue = ""
        window?.makeFirstResponder(textField)
    }

    func configureVoice(phase: OpenClickyNotchVoicePhase, audioPowerLevel: CGFloat, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String) {
        mode = .voice
        self.accentColor = accentColor
        expand = nil
        notchHandle.isHidden = true
        shellView.isHidden = false
        shellGlassView.isHidden = false
        shellGlassView.configure(cornerRadius: 17, roundsTopCorners: false, accentColor: accentColor, strength: .compact)
        shellView.roundsTopCorners = false
        textStack.isHidden = true
        voiceStack.isHidden = false
        collapsedAppIconView.isHidden = true
        collapsedAppNameLabel.isHidden = true
        collapsedPlayIconView.isHidden = true
        collapsedAgentDotsView.isHidden = true
        shellView.cornerRadius = 17
        shellView.fillColor = OpenClickyLiquidGlassBackdropView.isLiquidGlassAvailable ? NSColor.black.withAlphaComponent(0.30) : NSColor.black.withAlphaComponent(0.91)
        shellView.borderColor = .clear
        shellView.roundedShadowColor = nil
        shellView.roundedShadowBlurRadius = 0
        shellView.roundedShadowOffset = .zero
        configureRightEdgeGradient(isVisible: true, intensity: phase == .idle ? 0.22 : 0.34)
        updateAccentColors()
        updateForegroundApp(icon: foregroundAppIcon, name: foregroundAppName)
        updateVoiceLabels(for: phase, foregroundAppName: foregroundAppName)
        waveformView.audioPowerLevel = audioPowerLevel
        waveformView.accentColor = accentColor
    }

    func updateForegroundApp(icon: NSImage?, name: String) {
        collapsedAppIconView.image = icon
        voiceAppIconView.image = icon
        collapsedAppNameLabel.stringValue = name
        collapsedAppIconView.isHidden = mode != .collapsed || icon == nil
        collapsedAppNameLabel.isHidden = mode != .collapsed
        collapsedPlayIconView.isHidden = mode != .collapsed || !collapsedAgentDotsView.isHidden
        if mode != .collapsed {
            collapsedAgentDotsView.isHidden = true
        }
        voiceAppIconView.isHidden = mode != .voice || icon == nil
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
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard mode == .collapsed else { return }
        expand?()
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

        shellGlassView.translatesAutoresizingMaskIntoConstraints = false
        shellGlassView.isHidden = true
        addSubview(shellGlassView)

        shellView.translatesAutoresizingMaskIntoConstraints = false
        shellView.fillColor = NSColor(calibratedRed: 0.025, green: 0.036, blue: 0.032, alpha: 0.96)
        shellView.borderColor = NSColor.white.withAlphaComponent(0.085)
        shellView.roundedShadowColor = NSColor.black.withAlphaComponent(0.46)
        shellView.roundedShadowBlurRadius = 16
        shellView.roundedShadowOffset = NSSize(width: 0, height: -8)
        addSubview(shellView)
        let shellClickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleCollapsedClick(_:)))
        shellView.addGestureRecognizer(shellClickRecognizer)

        rightEdgeGradientView.translatesAutoresizingMaskIntoConstraints = false
        rightEdgeGradientView.isHidden = true
        shellView.addSubview(rightEdgeGradientView)

        configureForegroundAppIconViews()
        configureTextStack()
        configureVoiceStack()

        NSLayoutConstraint.activate([
            notchHandle.topAnchor.constraint(equalTo: topAnchor),
            notchHandle.centerXAnchor.constraint(equalTo: centerXAnchor),
            notchHandle.widthAnchor.constraint(equalToConstant: 52),
            notchHandle.heightAnchor.constraint(equalToConstant: 10),

            shellGlassView.topAnchor.constraint(equalTo: topAnchor),
            shellGlassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            shellGlassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            shellGlassView.bottomAnchor.constraint(equalTo: bottomAnchor),

            shellView.topAnchor.constraint(equalTo: topAnchor),
            shellView.leadingAnchor.constraint(equalTo: leadingAnchor),
            shellView.trailingAnchor.constraint(equalTo: trailingAnchor),
            shellView.bottomAnchor.constraint(equalTo: bottomAnchor),

            rightEdgeGradientView.topAnchor.constraint(equalTo: shellView.topAnchor),
            rightEdgeGradientView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor),
            rightEdgeGradientView.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),
            rightEdgeGradientView.widthAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func configureForegroundAppIconViews() {
        for imageView in [collapsedAppIconView, collapsedPlayIconView, voiceAppIconView] {
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 4
            imageView.layer?.masksToBounds = true
            imageView.isHidden = true
        }
        collapsedPlayIconView.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Open OpenClicky")
        collapsedPlayIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        collapsedAppNameLabel.translatesAutoresizingMaskIntoConstraints = false
        collapsedAppNameLabel.font = .systemFont(ofSize: 13, weight: .heavy)
        collapsedAppNameLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        collapsedAppNameLabel.lineBreakMode = .byTruncatingTail
        collapsedAppNameLabel.maximumNumberOfLines = 1
        collapsedAppNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        collapsedAppNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        collapsedAppNameLabel.isHidden = true

        let collapsedStack = NSStackView()
        collapsedStack.orientation = .horizontal
        collapsedStack.alignment = .centerY
        collapsedStack.spacing = 4
        collapsedStack.translatesAutoresizingMaskIntoConstraints = false
        collapsedStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        collapsedStack.addArrangedSubview(collapsedAppIconView)
        collapsedStack.addArrangedSubview(collapsedAppNameLabel)
        shellView.addSubview(collapsedStack)
        shellView.addSubview(collapsedPlayIconView)
        collapsedAgentDotsView.translatesAutoresizingMaskIntoConstraints = false
        collapsedAgentDotsView.isHidden = true
        shellView.addSubview(collapsedAgentDotsView)

        NSLayoutConstraint.activate([
            collapsedAppIconView.widthAnchor.constraint(equalToConstant: 14),
            collapsedAppIconView.heightAnchor.constraint(equalToConstant: 14),
            collapsedPlayIconView.widthAnchor.constraint(equalToConstant: 14),
            collapsedPlayIconView.heightAnchor.constraint(equalToConstant: 14),
            collapsedPlayIconView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: -7),
            collapsedPlayIconView.centerYAnchor.constraint(equalTo: shellView.centerYAnchor),
            collapsedAgentDotsView.widthAnchor.constraint(equalToConstant: 20),
            collapsedAgentDotsView.heightAnchor.constraint(equalToConstant: 8),
            collapsedAgentDotsView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: -7),
            collapsedAgentDotsView.centerYAnchor.constraint(equalTo: shellView.centerYAnchor),
            collapsedStack.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 7),
            collapsedStack.trailingAnchor.constraint(lessThanOrEqualTo: collapsedPlayIconView.leadingAnchor, constant: -4),
            collapsedStack.trailingAnchor.constraint(lessThanOrEqualTo: collapsedAgentDotsView.leadingAnchor, constant: -4),
            collapsedStack.centerYAnchor.constraint(equalTo: shellView.centerYAnchor),
            collapsedAppNameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 46)
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
        voiceStack.spacing = 4
        voiceStack.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(voiceStack)

        let copyStack = NSStackView()
        copyStack.orientation = .vertical
        copyStack.alignment = .leading
        copyStack.spacing = 0
        copyStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voiceTitleLabel.font = .systemFont(ofSize: 13, weight: .heavy)
        voiceTitleLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        voiceTitleLabel.lineBreakMode = .byTruncatingTail
        voiceSubtitleLabel.font = .systemFont(ofSize: 7.5, weight: .semibold)
        voiceSubtitleLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        voiceSubtitleLabel.lineBreakMode = .byTruncatingTail
        voiceSubtitleLabel.isHidden = false
        voiceAppIconView.setContentHuggingPriority(.required, for: .horizontal)
        voiceAppIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.setContentHuggingPriority(.required, for: .horizontal)
        waveformView.setContentCompressionResistancePriority(.required, for: .horizontal)
        voiceStack.addArrangedSubview(voiceAppIconView)
        copyStack.addArrangedSubview(voiceTitleLabel)
        copyStack.addArrangedSubview(voiceSubtitleLabel)
        voiceStack.addArrangedSubview(copyStack)
        voiceStack.addArrangedSubview(voiceNotchSpacer)
        voiceStack.addArrangedSubview(waveformView)
        voiceAppIconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        voiceAppIconView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        copyStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        voiceNotchSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true
        waveformView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        waveformView.heightAnchor.constraint(equalToConstant: 8).isActive = true

        NSLayoutConstraint.activate([
            voiceStack.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 7),
            voiceStack.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: -7),
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
        rightEdgeGradientView.accentColor = accentColor
        updateButtons(in: actionStack)
        shellView.needsDisplay = true
    }

    private func configureRightEdgeGradient(isVisible: Bool, intensity: CGFloat) {
        rightEdgeGradientView.isHidden = !isVisible
        rightEdgeGradientView.accentColor = accentColor
        rightEdgeGradientView.intensity = intensity
        rightEdgeGradientView.cornerRadius = shellView.cornerRadius
        rightEdgeGradientView.roundsTopCorners = shellView.roundsTopCorners
    }

    private func updateButtons(in stack: NSStackView) {
        for case let button as OpenClickyActionPillButton in stack.arrangedSubviews {
            button.accentColor = accentColor
        }
    }

    private func updateVoiceLabels(for phase: OpenClickyNotchVoicePhase, foregroundAppName: String) {
        voiceSubtitleLabel.stringValue = foregroundAppName
        switch phase {
        case .listening:
            voiceTitleLabel.stringValue = "Listening"
            waveformView.isActive = true
        case .processing:
            voiceTitleLabel.stringValue = "Thinking"
            waveformView.isActive = false
        case .responding:
            voiceTitleLabel.stringValue = "Speaking"
            waveformView.isActive = true
        case .idle:
            voiceTitleLabel.stringValue = "Ready"
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

private final class OpenClickyLiquidGlassBackdropView: NSView {
    enum Strength {
        case compact
        case expanded
    }

    static var isLiquidGlassAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    private let backingView: NSView
    private let usesLiquidGlass: Bool
    private let maskLayer = CAShapeLayer()
    private var cornerRadius: CGFloat
    private var roundsTopCorners = true
    private var accentColor: NSColor = .systemBlue
    private var strength: Strength = .compact

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius

        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSObject.Type,
           let glassView = glassClass.init() as? NSView {
            backingView = glassView
            usesLiquidGlass = true
        } else {
            let visualEffectView = NSVisualEffectView()
            visualEffectView.material = .hudWindow
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.state = .active
            backingView = visualEffectView
            usesLiquidGlass = false
        }

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        backingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backingView)
        NSLayoutConstraint.activate([
            backingView.topAnchor.constraint(equalTo: topAnchor),
            backingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyShape()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(cornerRadius: CGFloat, roundsTopCorners: Bool, accentColor: NSColor, strength: Strength) {
        self.cornerRadius = cornerRadius
        self.roundsTopCorners = roundsTopCorners
        self.accentColor = accentColor
        self.strength = strength
        applyShape()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        applyShape()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !usesLiquidGlass else { return }
        let path = roundedPath(in: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.black.withAlphaComponent(strength == .compact ? 0.20 : 0.30).setFill()
        path.fill()
        if strength == .expanded {
            accentColor.withAlphaComponent(0.08).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func applyShape() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = cgPath(in: bounds)
        maskLayer.path = path
        layer?.mask = maskLayer
        if #available(macOS 10.15, *) {
            maskLayer.cornerCurve = .continuous
        }
        layer?.backgroundColor = NSColor.clear.cgColor

        backingView.layer?.cornerRadius = cornerRadius
        backingView.layer?.masksToBounds = true
        if backingView.responds(to: Selector(("setCornerRadius:"))) {
            backingView.setValue(cornerRadius, forKey: "cornerRadius")
        }
    }

    private func roundedPath(in rect: NSRect) -> NSBezierPath {
        guard !roundsTopCorners else {
            return NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))
        path.curve(
            to: NSPoint(x: rect.maxX - radius, y: rect.minY),
            controlPoint1: NSPoint(x: rect.maxX, y: rect.minY + radius * 0.45),
            controlPoint2: NSPoint(x: rect.maxX - radius * 0.45, y: rect.minY)
        )
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.minY + radius),
            controlPoint1: NSPoint(x: rect.minX + radius * 0.45, y: rect.minY),
            controlPoint2: NSPoint(x: rect.minX, y: rect.minY + radius * 0.45)
        )
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }

    private func cgPath(in rect: NSRect) -> CGPath {
        if roundsTopCorners {
            return CGPath(
                roundedRect: rect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + radius), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private final class OpenClickyNotchRightEdgeGradientView: NSView {
    var accentColor: NSColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0) { didSet { needsDisplay = true } }
    var intensity: CGFloat = 0.34 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 17 { didSet { needsDisplay = true } }
    var roundsTopCorners = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }

        NSGraphicsContext.saveGraphicsState()
        clippedPath().addClip()

        let gradient = NSGradient(colors: [
            accentColor.withAlphaComponent(0.0),
            accentColor.withAlphaComponent(0.11 * intensity),
            accentColor.withAlphaComponent(0.34 * intensity),
            accentColor.withAlphaComponent(0.48 * intensity)
        ])
        gradient?.draw(from: NSPoint(x: bounds.minX, y: bounds.midY), to: NSPoint(x: bounds.maxX, y: bounds.midY), options: [])

        let edgeRect = NSRect(x: bounds.maxX - 28, y: bounds.minY, width: 28, height: bounds.height)
        let edgeGradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.0),
            accentColor.withAlphaComponent(0.16 * intensity)
        ])
        edgeGradient?.draw(in: edgeRect, angle: 0)

        NSGraphicsContext.restoreGraphicsState()
    }

    private func clippedPath() -> NSBezierPath {
        let rect = bounds
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let path = NSBezierPath()

        if roundsTopCorners {
            return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }

        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
        path.curve(
            to: NSPoint(x: rect.maxX - radius, y: rect.maxY),
            controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - radius * 0.45),
            controlPoint2: NSPoint(x: rect.maxX - radius * 0.45, y: rect.maxY)
        )
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }
}

private final class OpenClickyRoundedView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderColor: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat { didSet { updateLayerShape(); needsDisplay = true } }
    var roundsTopCorners: Bool = true { didSet { updateLayerShape(); needsDisplay = true } }
    var roundedShadowColor: NSColor? { didSet { updateLayerShape() } }
    var roundedShadowBlurRadius: CGFloat = 0 { didSet { updateLayerShape() } }
    var roundedShadowOffset: NSSize = .zero { didSet { updateLayerShape() } }

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        updateLayerShape()
    }

    required init?(coder: NSCoder) {
        self.cornerRadius = 12
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
        updateLayerShape()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateLayerShape()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = roundedPath(in: bounds.insetBy(dx: 0.5, dy: 0.5))
        fillColor.setFill()
        path.fill()
        if borderColor.alphaComponent > 0 {
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func updateLayerShape() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = false
        if #available(macOS 10.15, *) {
            layer.cornerCurve = .continuous
        }

        if let roundedShadowColor {
            layer.shadowColor = roundedShadowColor.cgColor
            layer.shadowOpacity = Float(roundedShadowColor.alphaComponent)
            layer.shadowRadius = roundedShadowBlurRadius
            layer.shadowOffset = roundedShadowOffset
            layer.shadowPath = shadowPath(in: bounds)
        } else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
        }
    }

    private func roundedPath(in rect: NSRect) -> NSBezierPath {
        guard !roundsTopCorners else {
            return NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))
        path.curve(
            to: NSPoint(x: rect.maxX - radius, y: rect.minY),
            controlPoint1: NSPoint(x: rect.maxX, y: rect.minY + radius * 0.45),
            controlPoint2: NSPoint(x: rect.maxX - radius * 0.45, y: rect.minY)
        )
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.minY + radius),
            controlPoint1: NSPoint(x: rect.minX + radius * 0.45, y: rect.minY),
            controlPoint2: NSPoint(x: rect.minX, y: rect.minY + radius * 0.45)
        )
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }

    private func shadowPath(in rect: NSRect) -> CGPath {
        if roundsTopCorners {
            return CGPath(
                roundedRect: rect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + radius), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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

private final class OpenClickyMainPanelResizeContainerView: NSView {
    private struct ResizeEdges: OptionSet {
        let rawValue: Int

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    var isResizeEnabled: (() -> Bool)?

    private let edgeHitWidth: CGFloat = 16
    private let cornerHitLength: CGFloat = 28
    private var activeEdges: ResizeEdges = []
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartFrame: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isResizeEnabled?() == true, !resizeEdges(at: point).isEmpty else {
            return super.hitTest(point)
        }
        return self
    }

    override func resetCursorRects() {
        guard isResizeEnabled?() == true else { return }
        addCursorRect(NSRect(x: 0, y: 0, width: edgeHitWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.maxX - edgeHitWidth, y: 0, width: edgeHitWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: edgeHitWidth), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.maxY - edgeHitWidth, width: bounds.width, height: edgeHitWidth), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard isResizeEnabled?() == true else {
            super.mouseDown(with: event)
            return
        }
        activeEdges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        guard !activeEdges.isEmpty, let window else {
            super.mouseDown(with: event)
            return
        }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizeEnabled?() == true, !activeEdges.isEmpty, let window else {
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

        window.setFrame(frame, display: true, animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
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

private final class OpenClickyNotchWaveformNSView: NSView {
    var audioPowerLevel: CGFloat = 0 { didSet { needsDisplay = true } }
    var accentColor: NSColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0) { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let barCount = 4
        let spacing: CGFloat = 3
        let barWidth: CGFloat = 2.5
        let normalizedPower = min(max(audioPowerLevel, 0), 1)
        let maxHeight = bounds.height
        let activeAlpha: CGFloat = isActive ? 0.92 : 0.44
        let fill = accentColor.withAlphaComponent(activeAlpha)
        fill.setFill()

        let contentWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = max(0, bounds.width - contentWidth)
        for index in 0..<barCount {
            let wave = CGFloat((sin(Double(index) * 0.86) + 1.0) / 2.0)
            let floor: CGFloat = isActive ? 4 : 3
            let height = min(maxHeight, floor + normalizedPower * 5 + wave * (isActive ? 3 : 2))
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let y = (maxHeight - height) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        }
    }
}

private final class OpenClickyNotchDotsNSView: NSView {
    var accentColor: NSColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0) { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dotCount = 3
        let dotSize: CGFloat = 5
        let spacing: CGFloat = 5
        let contentWidth = CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * spacing
        let startX = max(0, bounds.width - contentWidth)
        let y = (bounds.height - dotSize) / 2

        for index in 0..<dotCount {
            let x = startX + CGFloat(index) * (dotSize + spacing)
            let rect = NSRect(x: x, y: y, width: dotSize, height: dotSize)
            let glowRect = rect.insetBy(dx: -4, dy: -4)
            let glowPath = NSBezierPath(ovalIn: glowRect)
            accentColor.withAlphaComponent(isActive ? 0.14 : 0.08).setFill()
            glowPath.fill()

            let dotPath = NSBezierPath(ovalIn: rect)
            accentColor.withAlphaComponent(isActive ? 0.90 : 0.52).setFill()
            dotPath.fill()
        }
    }
}
