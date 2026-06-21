//
//  OpenClickyNotchCaptureWindowManager.swift
//  cursor-buddy
//
//  Top-of-screen capture surface for OpenClicky. It anchors beneath the
//  MacBook Pro notch when the built-in display is present, otherwise beneath
//  the active main display while docked. This replaces the old cursor-local
//  older floating text interface and mirrors Clicky's top listening affordance.
//

import AppKit
import SwiftUI
import OpenClickyCore

private final class OpenClickyNotchCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum OpenClickyWindowLevels {
    /// The compact notch/dynamic-island status surface sits above normal apps
    /// and Space/full-screen surfaces. The external no-notch pill is a normal
    /// fallback NSPanel rather than DynamicNotchKit's physical-notch surface,
    /// so status-bar-adjacent levels can be re-stacked behind app/menu-bar
    /// windows when displays or Spaces settle.
    static let statusSurface = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    /// The main OpenClicky panel must sit above the status surface so hovering
    /// the dynamic island cannot visually cut into the panel's side chrome.
    static let mainPanel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

    /// First-party dialogs and document windows float one step above the main
    /// panel so they never tuck underneath when launched from OpenClicky.
    static let panelDialog = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)

    static func applyPanelDialogLevel(to window: NSWindow?) {
        window?.level = panelDialog
    }
}

enum OpenClickyNotchVoicePhase {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class OpenClickyNotchCaptureWindowManager {
    private enum ActiveMode {
        case collapsedText
        case voice
    }

    private var panel: OpenClickyNotchCapturePanel?
    private var mainPanel: OpenClickyNotchCapturePanel?
    private let dynamicNotchKitBridge = OpenClickyDynamicNotchKitBridge()
    private var contentView: OpenClickyNotchCaptureRootView?
    private var mainHostingView: NSHostingView<OpenClickyNotchPanelView>?
    private var mainPanelGlassBackdrop: OpenClickyLiquidGlassBackdropView?
    private var mainPanelGlobalClickMonitor: Any?
    private var mainPanelLocalClickMonitor: Any?
    private var mainPanelEscapeKeyMonitor: Any?
    private var mainPanelContentSizeObserver: NSObjectProtocol?
    private var accentThemeObserver: NSObjectProtocol?
    private var mainPanelContentResizeWorkItem: DispatchWorkItem?
    private var isMainPanelUserResizing = false
    private var mainPanelUserPreferredSize: NSSize?
    private var mainPanelPreferredContentHeight: CGFloat?
    private var mainPanelCurrentMinimumSize = OpenClickyNotchCaptureWindowManager.mainPanelMinimumSize
    private var isMainPanelPinned = false
    private var activeMode: ActiveMode?
    private var persistentAccentColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
    private var persistentSubmitText: ((String) -> Void)?
    private var persistentShowMainPanel: (() -> Void)?
    private var persistentHasRunningAgentWork = false
    private var persistentAgentLiveActivity = OpenClickyAgentLiveActivity()
    private var currentVoicePhase: OpenClickyNotchVoicePhase = .idle
    private var currentAudioPowerLevel: CGFloat = 0
    private var isUsingDynamicNotchKitStatusSurface = false
    private var anchorScreenOverride: NSScreen?
    private var collapsedHoverProbeTimer: Timer?
    private var foregroundAppActivationObserver: NSObjectProtocol?
    private var foregroundAppIcon: NSImage?
    private var foregroundAppName: String = "Current app"
    private var contextAffordanceTimer: Timer?
    private var lastContextAffordanceSignature: String?
    private var lastContextAffordanceShownAt: Date?
    private var lastSelectedTextSignature: String?
    // AppKit window frames are in points, not pixels. Keep these as real
    // point sizes; do not divide by backingScaleFactor or the content clips on
    // Retina displays.
    private static let expandedPanelWidth: CGFloat = 520
    private static let mainPanelWidth: CGFloat = 475
    private static let mainPanelHeight: CGFloat = 620
    private static let mainPanelMinimumSize = NSSize(width: 390, height: 340)
    private static let mainPanelMaximumSize = NSSize(width: 620, height: 820)
    private static let builtInMainPanelMaximumWidth: CGFloat = mainPanelWidth
    private static let statusPanelWidthScale: CGFloat = 0.24
    private static let statusPanelHorizontalNudge: CGFloat = 0
    fileprivate static let builtInStatusTrailingInset: CGFloat = 20
    fileprivate static let externalStatusTrailingInset: CGFloat = 24
    fileprivate static let builtInVoiceTrailingInset: CGFloat = 20
    fileprivate static let externalVoiceTrailingInset: CGFloat = 26
    private static let minimumBuiltInCollapsedPanelWidth: CGFloat = 76
    private static let compactBuiltInVoicePanelWidth: CGFloat = 112
    private static let minimumVoicePanelWidth: CGFloat = 180
    private static let minimumExternalCollapsedPanelWidth: CGFloat = compactCollapsedChromeWidth
    private static let maximumExternalCollapsedPanelWidth: CGFloat = 190
    private static let minimumExternalNonNotchedStatusPanelWidth: CGFloat = 260
    private static let maximumExternalNonNotchedStatusPanelWidth: CGFloat = 300
    private static let maximumExpandedStatusPanelWidth: CGFloat = 320
    private static let collapsedLabelFont = NSFont.systemFont(ofSize: 13, weight: .heavy)
    private static let collapsedLabelMaxWidth: CGFloat = 300
    // leading pad + app icon (28) + stack spacing (4) + gap before trailing (8) + play/dots (14) + trailing pad
    private static let collapsedChromeWidth: CGFloat = 10 + 28 + 4 + 8 + 14 + 16
    private static let statusLozengeHeight: CGFloat = 38
    private static let collapsedPanelHeight: CGFloat = statusLozengeHeight
    private static let expandedHandleWidth: CGFloat = 96
    private static let expandedHandleHeight: CGFloat = 10
    private static let textPanelHeight: CGFloat = 112
    private static let mainPanelMaximumHeight: CGFloat = 720
    private static let voicePanelHeight: CGFloat = statusLozengeHeight
    private static let topGap: CGFloat = 0
    private static let noNotchScreenTopOverlap: CGFloat = 2
    private static let notchClearanceGap: CGFloat = 4
    private static let mainPanelGapBelowCapture: CGFloat = 8
    private static let mainPanelPhysicalNotchDownOffset: CGFloat = 56
    private static let screenEdgePadding: CGFloat = 12
    private static let escapeKeyCode: UInt16 = 53
    private static let contextAffordanceCooldown: TimeInterval = 12

    init() {
        mainPanelContentSizeObserver = NotificationCenter.default.addObserver(
            forName: .clickyPanelContentSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let preferredHeight = Self.mainPanelPreferredHeight(from: notification)
            Task { @MainActor [weak self] in
                self?.scheduleVisibleMainPanelResize(preferredHeight: preferredHeight)
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
            let appIcon = app.icon
            let appName = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Current app"

            Task { @MainActor [weak self, bundleIdentifier, bundlePath, appIcon, appName] in
                self?.updateForegroundAppIcon(
                    bundleIdentifier: bundleIdentifier,
                    bundlePath: bundlePath,
                    appIcon: appIcon,
                    name: appName
                )
            }
        }
        accentThemeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccentColorFromDefaults()
            }
        }
    }

    deinit {
        if let observer = mainPanelContentSizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = accentThemeObserver {
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
        // The persistent status pill belongs on the display the user is
        // actually working on. Do this before sizing or choosing the
        // DynamicNotchKit-vs-fallback route, otherwise an older key/main
        // window can pull the notch back to the MacBook and make it disappear
        // from the primary external monitor.
        pinAnchorScreenToActiveInteractionIfNeeded()
        let primaryScreen = preferredAnchorScreen()
        let collapsedWidth = Self.collapsedPanelWidth(for: primaryScreen, appName: foregroundAppName)
        ensureCaptureContentView(width: collapsedWidth, height: Self.collapsedPanelHeight)
        let accentColor = Self.nsAccentColor(for: accentTheme)
        persistentAgentLiveActivity = Self.agentLiveActivity(in: companionManager)
        persistentHasRunningAgentWork = persistentAgentLiveActivity.isActive
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
            hidesAppNameText: Self.hidesCollapsedAppNameText(on: primaryScreen),
            expand: { [weak self] in
                self?.pinAnchorScreenToActiveInteractionIfNeeded()
                self?.persistentShowMainPanel?()
            },
            dismiss: { [weak self] in self?.collapseToPill(accentColor: accentColor, submitText: submitText) }
        )
        startCollapsedHoverProbe()
        let statusScreen = preferredPhysicalNotchStatusScreen()
        let isShowingDynamicNotchKitStatusSurface = showDynamicNotchKitCollapsedIfAvailable(
            on: statusScreen,
            accentColor: accentColor,
            companionManager: companionManager
        )
        if isShowingDynamicNotchKitStatusSurface {
            panel?.orderOut(nil)
        } else {
            showFallbackStatusPanel(width: collapsedWidth, height: Self.collapsedPanelHeight)
        }
    }

    private func showDynamicNotchKitCollapsedIfAvailable(
        on screen: NSScreen?,
        accentColor: NSColor,
        companionManager: CompanionManager?
    ) -> Bool {
        #if canImport(DynamicNotchKit)
        guard let screen, Self.hasPhysicalNotch(on: screen) else { return false }
        let hasRunningAgentWork = companionManager.map(Self.hasRunningAgentWork(in:)) ?? persistentHasRunningAgentWork
        dynamicNotchKitBridge.showCollapsed(
            on: screen,
            accentColor: accentColor,
            foregroundAppIcon: foregroundAppIcon,
            foregroundAppName: foregroundAppName,
            hasRunningAgentWork: hasRunningAgentWork,
            agentLiveActivity: companionManager.map(Self.agentLiveActivity(in:)) ?? persistentAgentLiveActivity,
            openMainPanel: { [weak self] in
                self?.pinAnchorScreenToActiveInteractionIfNeeded()
                self?.persistentShowMainPanel?()
            },
            submitText: persistentSubmitText ?? { _ in }
        )
        isUsingDynamicNotchKitStatusSurface = true
        return true
        #else
        return false
        #endif
    }

    private func showDynamicNotchKitVoiceIfAvailable(
        _ voicePhase: OpenClickyNotchVoicePhase,
        audioPowerLevel: CGFloat,
        on screen: NSScreen?
    ) -> Bool {
        #if canImport(DynamicNotchKit)
        guard let screen, Self.hasPhysicalNotch(on: screen) else { return false }
        dynamicNotchKitBridge.showVoice(
            voicePhase,
            audioPowerLevel: audioPowerLevel,
            on: screen,
            accentColor: Self.nsAccentColor(for: nil),
            foregroundAppIcon: foregroundAppIcon,
            foregroundAppName: foregroundAppName,
            openMainPanel: { [weak self] in
                self?.pinAnchorScreenToActiveInteractionIfNeeded()
                self?.persistentShowMainPanel?()
            }
        )
        isUsingDynamicNotchKitStatusSurface = true
        return true
        #else
        return false
        #endif
    }

    private func showDynamicNotchKitStatusForCurrentModeIfAvailable(on screen: NSScreen?, opensExpanded: Bool = false) -> Bool {
        #if canImport(DynamicNotchKit)
        guard let screen, Self.hasPhysicalNotch(on: screen) else { return false }
        switch activeMode {
        case .collapsedText:
            dynamicNotchKitBridge.showCollapsed(
                on: screen,
                accentColor: persistentAccentColor,
                foregroundAppIcon: foregroundAppIcon,
                foregroundAppName: foregroundAppName,
                hasRunningAgentWork: persistentHasRunningAgentWork,
                agentLiveActivity: persistentAgentLiveActivity,
                openMainPanel: { [weak self] in
                    self?.pinAnchorScreenToActiveInteractionIfNeeded()
                    self?.persistentShowMainPanel?()
                },
                submitText: persistentSubmitText ?? { _ in },
                opensExpanded: opensExpanded
            )
            isUsingDynamicNotchKitStatusSurface = true
            return true
        case .voice:
            dynamicNotchKitBridge.showVoice(
                currentVoicePhase,
                audioPowerLevel: currentAudioPowerLevel,
                on: screen,
                accentColor: Self.nsAccentColor(for: nil),
                foregroundAppIcon: foregroundAppIcon,
                foregroundAppName: foregroundAppName,
                openMainPanel: { [weak self] in
                    self?.pinAnchorScreenToActiveInteractionIfNeeded()
                    self?.persistentShowMainPanel?()
                },
                submitText: persistentSubmitText ?? { _ in },
                opensExpanded: opensExpanded
            )
            isUsingDynamicNotchKitStatusSurface = true
            return true
        case .none:
            return false
        }
        #else
        return false
        #endif
    }

    private func hideDynamicNotchKitStatusSurface() {
        guard isUsingDynamicNotchKitStatusSurface else { return }
        dynamicNotchKitBridge.hide()
        isUsingDynamicNotchKitStatusSurface = false
    }

    func updateAgentLiveActivity(companionManager: CompanionManager) {
        let activity = Self.agentLiveActivity(in: companionManager)
        persistentAgentLiveActivity = activity
        persistentHasRunningAgentWork = activity.isActive

        if isUsingDynamicNotchKitStatusSurface {
            dynamicNotchKitBridge.updateAgentLiveActivity(activity)
        }

        guard activeMode == .collapsedText else { return }
        contentView?.setAgentWorkActive(activity.isActive, foregroundAppName: foregroundAppName)
    }

    func showTextInput(accentTheme: ClickyAccentTheme? = nil, submitText: @escaping (String) -> Void) {
        let accentColor = Self.nsAccentColor(for: accentTheme)
        persistentAccentColor = accentColor
        persistentSubmitText = submitText
        // Quick input is a pointer/display action: if the user invokes it
        // while working on an external monitor, do not let an older frontmost
        // MacBook window pull the input back to the built-in notch display.
        pinAnchorScreenToPointerFirstActiveInteractionIfNeeded()
        guard let screen = preferredAnchorScreen() ?? NSScreen.main else {
            hideDynamicNotchKitStatusSurface()
            return
        }
        // The "Ask Clicky" prompt now lives inside the DynamicNotchKit notch's
        // expanded view rather than the standalone capture panel.
        panel?.orderOut(nil)
        isUsingDynamicNotchKitStatusSurface = true
        let hidesWhenClosed = !Self.hasPhysicalNotch(on: screen)
        dynamicNotchKitBridge.showTextInput(
            on: screen,
            accentColor: accentColor,
            foregroundAppIcon: foregroundAppIcon,
            foregroundAppName: foregroundAppName,
            submitText: submitText,
            hidesWhenClosed: hidesWhenClosed,
            onHiddenWhenClosed: hidesWhenClosed ? { [weak self, weak screen] in
                guard let screen else { return }
                self?.restoreFallbackPillAfterExternalInput(on: screen)
            } : nil
        )
    }


    private func restoreFallbackPillAfterExternalInput(on screen: NSScreen) {
        guard !Self.hasPhysicalNotch(on: screen), mainPanel?.isVisible != true else { return }
        guard let submitText = persistentSubmitText else { return }
        anchorScreenOverride = screen
        isUsingDynamicNotchKitStatusSurface = false
        collapseToPill(accentColor: persistentAccentColor, submitText: submitText)
    }

    func showShortcutInput(accentTheme: ClickyAccentTheme? = nil, submitText: @escaping (String) -> Void) {
        let accentColor = Self.nsAccentColor(for: accentTheme)
        persistentAccentColor = accentColor
        persistentSubmitText = submitText

        if let selectedText = Self.readFocusedSelectedText(), !selectedText.isEmpty {
            let appName = foregroundAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "this app" : foregroundAppName
            let suggestion = Self.selectionContextSuggestion(
                selectedText: selectedText,
                appName: appName,
                appIcon: foregroundAppIcon
            )
            showContextAffordance(suggestion, signature: Self.contextSignature(prefix: "selection", value: selectedText), ignoresCooldown: true)
            return
        }

        if let suggestion = activeCapabilityContextSuggestion() {
            showContextAffordance(suggestion, signature: "capability:\(suggestion.primaryPrompt)", ignoresCooldown: true)
            return
        }

        showTextInput(accentTheme: accentTheme, submitText: submitText)
    }

    func updateVoiceState(_ voicePhase: OpenClickyNotchVoicePhase, audioPowerLevel: CGFloat) {
        currentVoicePhase = voicePhase
        currentAudioPowerLevel = audioPowerLevel
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
            activeMode = .voice
            // Voice status uses the same display ownership as the text pill:
            // keep it on the active interaction screen instead of drifting to
            // the built-in notch because NSApp key/main state is stale.
            pinAnchorScreenToActiveInteractionIfNeeded()
            let primaryScreen = preferredAnchorScreen()
            let hidesStatusText = Self.hidesVoiceStatusText(on: primaryScreen)
            ensureCaptureContentView(width: Self.voicePanelWidth(for: primaryScreen, appName: foregroundAppName), height: Self.voicePanelHeight)
            contentView?.configureVoice(
                phase: voicePhase,
                audioPowerLevel: audioPowerLevel,
                accentColor: Self.nsAccentColor(for: nil),
                foregroundAppIcon: foregroundAppIcon,
                foregroundAppName: foregroundAppName,
                hidesStatusText: hidesStatusText,
                expand: { [weak self] in
                    self?.pinAnchorScreenToActiveInteractionIfNeeded()
                    self?.persistentShowMainPanel?()
                }
            )
            let statusScreen = preferredPhysicalNotchStatusScreen()
            let isShowingDynamicNotchKitStatusSurface = showDynamicNotchKitVoiceIfAvailable(
                voicePhase,
                audioPowerLevel: audioPowerLevel,
                on: statusScreen
            )
            if isShowingDynamicNotchKitStatusSurface {
                panel?.orderOut(nil)
            } else {
                showFallbackStatusPanel(
                    width: Self.voicePanelWidth(for: primaryScreen, appName: foregroundAppName),
                    height: Self.voicePanelHeight
                )
            }
            startCollapsedHoverProbe()
        }
    }

    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {
        guard activeMode == .voice else { return }
        currentAudioPowerLevel = audioPowerLevel
        if isUsingDynamicNotchKitStatusSurface {
            dynamicNotchKitBridge.updateAudioPowerLevel(audioPowerLevel)
        }
        contentView?.updateAudioPowerLevel(audioPowerLevel)
    }

    func hide() {
        panel?.orderOut(nil)
        hideDynamicNotchKitStatusSurface()
        hideMainPanel()
        stopCollapsedHoverProbe()
        stopContextAffordanceObservation()
        activeMode = nil
        anchorScreenOverride = nil
    }

    private func hideMainPanel() {
        mainPanel?.orderOut(nil)
        removeMainPanelClickOutsideMonitors()
        removeMainPanelEscapeKeyMonitor()
        mainHostingView = nil
        mainPanelGlassBackdrop = nil
        if activeMode == .collapsedText {
            startCollapsedHoverProbe()
        }
    }

    private func collapseToPill(accentColor: NSColor, submitText: @escaping (String) -> Void) {
        activeMode = .collapsedText
        let collapsedWidth = Self.collapsedPanelWidth(for: preferredAnchorScreen(), appName: foregroundAppName)
        ensureCaptureContentView(width: collapsedWidth, height: Self.collapsedPanelHeight)
        contentView?.configureCollapsed(
            accentColor: accentColor,
            foregroundAppIcon: foregroundAppIcon,
            foregroundAppName: foregroundAppName,
            hasRunningAgentWork: persistentHasRunningAgentWork,
            hidesAppNameText: Self.hidesCollapsedAppNameText(on: preferredAnchorScreen()),
            expand: { [weak self] in
                self?.pinAnchorScreenToActiveInteractionIfNeeded()
                self?.persistentShowMainPanel?()
            },
            dismiss: { [weak self] in self?.collapseToPill(accentColor: accentColor, submitText: submitText) }
        )
        startCollapsedHoverProbe()
        let statusScreen = preferredPhysicalNotchStatusScreen()
        let isShowingDynamicNotchKitStatusSurface = showDynamicNotchKitCollapsedIfAvailable(
            on: statusScreen,
            accentColor: accentColor,
            companionManager: nil
        )
        if isShowingDynamicNotchKitStatusSurface {
            panel?.orderOut(nil)
        } else {
            showFallbackStatusPanel(width: collapsedWidth, height: Self.collapsedPanelHeight)
        }
    }

    func showMainInterfacePanel(companionManager: CompanionManager, focusedAgentSessionID: UUID? = nil) {
        showMainPanel(companionManager: companionManager, focusedAgentSessionID: focusedAgentSessionID)
    }

    private func showMainPanel(companionManager: CompanionManager, focusedAgentSessionID: UUID? = nil) {
        stopCollapsedHoverProbe()
        panel?.orderOut(nil)
        hideDynamicNotchKitStatusSurface()
        pinAnchorScreenToActiveInteractionIfNeeded()
        ensureMainPanel()
        applyMainPanelResizeBehavior()
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
        let hostingView = OpenClickyMainPanelHostingView(rootView: notchPanelView)
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layerContentsRedrawPolicy = .duringViewResize
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 0
        hostingView.layer?.masksToBounds = false
        if #available(macOS 10.15, *) {
            hostingView.layer?.cornerCurve = .continuous
        }
        let resizeContainer = OpenClickyMainPanelResizeContainerView(frame: NSRect(origin: .zero, size: initialSize))
        resizeContainer.autoresizingMask = [.width, .height]
        resizeContainer.layer?.backgroundColor = NSColor.clear.cgColor
        resizeContainer.isResizeEnabled = { true }
        resizeContainer.onResizeBegan = { [weak self] in
            self?.isMainPanelUserResizing = true
            NotificationCenter.default.post(
                name: .clickyMainPanelResizeStateDidChange,
                object: nil,
                userInfo: ["isResizing": true]
            )
        }
        resizeContainer.onResizeFrameChanged = { [weak self] size in
            self?.mainPanelUserPreferredSize = self?.constrainedMainPanelSize(size)
        }
        resizeContainer.onResizeEnded = { [weak self] size in
            self?.isMainPanelUserResizing = false
            NotificationCenter.default.post(
                name: .clickyMainPanelResizeStateDidChange,
                object: nil,
                userInfo: ["isResizing": false]
            )
            self?.mainPanelUserPreferredSize = self?.constrainedMainPanelSize(size)
            let constrainedSize = self?.constrainedMainPanelSize(size) ?? size
            self?.mainHostingView?.frame = NSRect(origin: .zero, size: constrainedSize)
            self?.mainHostingView?.needsLayout = true
            self?.clampMainPanelToVisibleScreen()
        }
        let glassBackdrop = OpenClickyLiquidGlassBackdropView(cornerRadius: 28)
        glassBackdrop.frame = NSRect(origin: .zero, size: initialSize)
        glassBackdrop.autoresizingMask = [.width, .height]
        glassBackdrop.configure(
            cornerRadius: 28,
            roundsTopCorners: true,
            accentColor: Self.nsAccentColor(for: nil),
            strength: .expanded
        )
        mainPanelGlassBackdrop = glassBackdrop
        resizeContainer.addSubview(glassBackdrop)

        resizeContainer.addSubview(hostingView)
        mainPanel?.contentView = resizeContainer
        mainHostingView = hostingView
        let fittingSize = preferredMainPanelSize()
        showMainPanelWindow(activating: true, width: fittingSize.width, height: fittingSize.height)
    }

    private func showPanel(activating: Bool, width: CGFloat, height: CGFloat) {
        resizeAndReposition(width: width, height: height)
        panel?.level = OpenClickyWindowLevels.statusSurface
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        } else {
            panel?.orderFrontRegardless()
        }
        panel?.orderFrontRegardless()
    }

    private func showFallbackStatusPanel(width: CGFloat, height: CGFloat) {
        hideDynamicNotchKitStatusSurface()
        showPanel(activating: false, width: width, height: height)
    }

    private func refreshFallbackStatusPanelOrderingIfNeeded() {
        guard !isUsingDynamicNotchKitStatusSurface, let panel, panel.isVisible else { return }
        panel.level = OpenClickyWindowLevels.statusSurface
        panel.orderFrontRegardless()
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

        if isPinned {
            mainPanelContentResizeWorkItem?.cancel()
            mainPanelContentResizeWorkItem = nil
            mainPanelPreferredContentHeight = nil
            if let mainPanel {
                mainPanelUserPreferredSize = constrainedMainPanelSize(mainPanel.frame.size)
            }
            refreshMainPanelMinimumSize(preferredHeight: nil)
        }

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
            if let screen = panel.screen, Self.hasPhysicalNotch(on: screen), let root = contentView {
                let windowPoint = panel.convertPoint(fromScreen: clickLocation)
                let localPoint = root.convert(windowPoint, from: nil)
                if root.shellView.frame.contains(localPoint) {
                    return
                }
            } else {
                return
            }
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
        capturePanel.level = OpenClickyWindowLevels.statusSurface
        capturePanel.isOpaque = false
        capturePanel.backgroundColor = .clear
        capturePanel.hasShadow = false
        capturePanel.hidesOnDeactivate = false
        capturePanel.isReleasedWhenClosed = false
        capturePanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        capturePanel.isMovableByWindowBackground = false
        capturePanel.titleVisibility = .hidden
        capturePanel.titlebarAppearsTransparent = true
        // Defeat AppKit's implicit minSize derived from the initial
        // contentRect (which is the expandedPanelWidth, 520pt). Without
        // these the pill window refuses to shrink below the size it was
        // created at, no matter what setFrame is called with.
        capturePanel.minSize = NSSize(width: 20, height: 24)
        capturePanel.contentMinSize = NSSize(width: 20, height: 24)
        return capturePanel
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        panel = Self.makeStatusPanel(width: Self.expandedPanelWidth, height: Self.textPanelHeight)
        refreshThemeAppearance()
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
        interfacePanel.level = OpenClickyWindowLevels.mainPanel
        interfacePanel.isOpaque = false
        interfacePanel.backgroundColor = .clear
        // Keep shadows inside the SwiftUI surface. AppKit's window shadow can
        // create a faint rectangular/rounded outline around transparent panels,
        // especially over bright browser content.
        interfacePanel.hasShadow = false
        interfacePanel.hidesOnDeactivate = false
        interfacePanel.isReleasedWhenClosed = false
        interfacePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Do not let arbitrary SwiftUI content drag the panel. The resize
        // container and visible grab handle provide the deliberate move zones.
        interfacePanel.isMovableByWindowBackground = false
        interfacePanel.titleVisibility = .hidden
        interfacePanel.titlebarAppearsTransparent = true
        interfacePanel.minSize = mainPanelCurrentMinimumSize
        interfacePanel.contentMinSize = mainPanelCurrentMinimumSize
        let maximumSize = mainPanelMaximumSizeForCurrentScreen()
        interfacePanel.maxSize = maximumSize
        interfacePanel.contentMaxSize = maximumSize

        mainPanel = interfacePanel
        applyMainPanelResizeBehavior()
        refreshThemeAppearance()
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
        let screen = preferredAnchorScreen() ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let screen, Self.hasPhysicalNotch(on: screen) {
            let staticFrame = Self.physicalNotchWindowFrame(on: screen)
            panel.setFrame(staticFrame, display: true, animate: false)
            contentView?.setCanvas(size: staticFrame.size)
            repositionMainPanelIfVisible()
            return
        }
        let size = NSSize(width: width, height: height)
        let origin = panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        contentView?.setCanvas(size: size)
        positionPanel(size: size)
        repositionMainPanelIfVisible()
    }

    private func resizeAndRepositionMainPanel(width: CGFloat, height: CGFloat) {
        guard let mainPanel else { return }
        let size = NSSize(width: width, height: height)
        let origin = isMainPanelPinned ? mainPanel.frame.origin : mainPanelOrigin(for: size)
        let frame = constrainedMainPanelFrame(NSRect(origin: origin, size: size))
        mainPanel.setFrame(
            frame,
            display: true,
            animate: false
        )
        mainHostingView?.frame = NSRect(origin: .zero, size: size)
    }

    private func scheduleVisibleMainPanelResize(preferredHeight: CGFloat?) {
        guard !isMainPanelPinned else {
            mainPanelContentResizeWorkItem?.cancel()
            mainPanelContentResizeWorkItem = nil
            mainPanelPreferredContentHeight = nil
            return
        }

        if let preferredHeight {
            mainPanelPreferredContentHeight = preferredHeight
        }
        refreshMainPanelMinimumSize(preferredHeight: preferredHeight)

        mainPanelContentResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Content-size notifications can arrive in clusters while SwiftUI
            // swaps tab bodies, attaches files, or streams chat rows. Animating
            // each intermediate window frame is what makes the panel visibly
            // shudder up and down, so coalesce them and apply the final size
            // without AppKit's window-frame animation.
            self.resizeVisibleMainPanelToCurrentContent(animated: false)
        }
        mainPanelContentResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: workItem)
    }

    private func resizeVisibleMainPanelToCurrentContent(animated: Bool) {
        guard let mainPanel, mainPanel.isVisible else { return }
        if isMainPanelUserResizing || (mainPanel.contentView as? OpenClickyMainPanelResizeContainerView)?.isUserResizing == true { return }
        if isMainPanelPinned {
            let size = constrainedMainPanelSize(mainPanel.frame.size)
            let targetFrame = constrainedMainPanelFrame(NSRect(origin: mainPanel.frame.origin, size: size))
            let hostingFrame = NSRect(origin: .zero, size: size)
            guard targetFrame.integral != mainPanel.frame.integral || mainHostingView?.frame.integral != hostingFrame.integral else { return }
            mainPanel.setFrame(targetFrame, display: true, animate: false)
            mainHostingView?.frame = hostingFrame
            mainHostingView?.needsLayout = true
            return
        }

        let size = preferredMainPanelSize()
        let origin: NSPoint
        if animated {
            // Keep the top edge anchored where the user is already reading it.
            // AppKit window frames grow upward when only the bottom-left origin
            // is preserved, so tab/content changes like Agents or Settings must
            // lower the origin by the height delta and extend the dialog down.
            let topY = mainPanel.frame.maxY
            origin = NSPoint(x: mainPanel.frame.origin.x, y: topY - size.height)
        } else {
            origin = mainPanelOrigin(for: size)
        }
        let targetFrame = constrainedMainPanelFrame(NSRect(origin: origin, size: size))

        guard targetFrame.integral != mainPanel.frame.integral else { return }

        let updateHostingFrame = { [weak self] in
            self?.mainHostingView?.frame = NSRect(origin: .zero, size: size)
            self?.mainHostingView?.needsLayout = true
        }

        if animated {
            updateHostingFrame()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                mainPanel.animator().setFrame(targetFrame, display: true)
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
        let width = mainPanelUserPreferredSize?.width ?? Self.mainPanelWidth

        if let mainPanelPreferredContentHeight {
            return constrainedMainPanelSize(NSSize(width: width, height: mainPanelPreferredContentHeight))
        }

        if let mainPanelUserPreferredSize {
            return constrainedMainPanelSize(mainPanelUserPreferredSize)
        }

        guard let fittingHeight = mainHostingView?.fittingSize.height, fittingHeight > 0 else {
            return constrainedMainPanelSize(NSSize(width: Self.mainPanelWidth, height: Self.mainPanelHeight))
        }
        let height = min(max(ceil(fittingHeight), mainPanelCurrentMinimumSize.height), Self.mainPanelMaximumHeight)
        return NSSize(width: width, height: height)
    }

    nonisolated private static func mainPanelPreferredHeight(from notification: Notification) -> CGFloat? {
        let value = notification.userInfo?["preferredPanelHeight"]
        if let preferredHeight = value as? CGFloat {
            return preferredHeight
        }
        if let preferredHeight = value as? Double {
            return CGFloat(preferredHeight)
        }
        if let preferredHeight = value as? NSNumber {
            return CGFloat(truncating: preferredHeight)
        }
        return nil
    }

    private func constrainedMainPanelSize(_ size: NSSize) -> NSSize {
        let maximumSize = mainPanelMaximumSizeForCurrentScreen()
        return NSSize(
            width: min(max(size.width, mainPanelCurrentMinimumSize.width), maximumSize.width),
            height: min(max(size.height, mainPanelCurrentMinimumSize.height), maximumSize.height)
        )
    }

    private func constrainedMainPanelFrame(_ frame: NSRect) -> NSRect {
        Self.constrainedMainPanelFrame(frame, on: mainPanel?.screen ?? preferredAnchorScreen())
    }

    private func clampMainPanelToVisibleScreen() {
        guard let mainPanel else { return }
        let frame = constrainedMainPanelFrame(mainPanel.frame)
        guard frame.integral != mainPanel.frame.integral else { return }
        mainPanel.setFrame(frame, display: true, animate: false)
    }

    private static func constrainedMainPanelFrame(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        guard let screen else { return frame }
        let visibleFrame = screen.visibleFrame
        let usableFrame = visibleFrame.isEmpty ? screen.frame : visibleFrame
        var constrained = frame

        let minX = usableFrame.minX + screenEdgePadding
        let maxX = usableFrame.maxX - screenEdgePadding - constrained.width
        if maxX >= minX {
            constrained.origin.x = min(max(constrained.origin.x, minX), maxX)
        } else {
            constrained.origin.x = minX
        }

        let minY = usableFrame.minY + screenEdgePadding
        let maxY = usableFrame.maxY - screenEdgePadding - constrained.height
        if maxY >= minY {
            constrained.origin.y = min(max(constrained.origin.y, minY), maxY)
        } else {
            constrained.origin.y = minY
        }

        return constrained
    }

    private func mainPanelMaximumSizeForCurrentScreen() -> NSSize {
        guard let screen = preferredAnchorScreen(), Self.isLikelyBuiltInNotchScreen(screen) else {
            return Self.mainPanelMaximumSize
        }
        return NSSize(width: Self.builtInMainPanelMaximumWidth, height: Self.mainPanelMaximumSize.height)
    }

    private func refreshMainPanelMinimumSize(preferredHeight: CGFloat?) {
        let minimumHeight = min(
            max((preferredHeight ?? Self.mainPanelMinimumSize.height).rounded(.up), Self.mainPanelMinimumSize.height),
            Self.mainPanelMaximumSize.height
        )
        mainPanelCurrentMinimumSize = NSSize(width: Self.mainPanelMinimumSize.width, height: minimumHeight)
        guard let mainPanel else { return }
        mainPanel.minSize = mainPanelCurrentMinimumSize
        mainPanel.contentMinSize = mainPanelCurrentMinimumSize
        let maximumSize = mainPanelMaximumSizeForCurrentScreen()
        mainPanel.maxSize = maximumSize
        mainPanel.contentMaxSize = maximumSize
    }

    private func applyMainPanelResizeBehavior() {
        guard let mainPanel else { return }
        if isMainPanelPinned {
            // Keep the panel visually custom and chrome-free. Resizing is
            // handled entirely by OpenClicky's edge/corner container below;
            // leaving AppKit's resizable mask on lets the hidden system resize
            // tracking fight our manual setFrame calls and makes drags hitch.
            mainPanel.styleMask.remove(.resizable)
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
        mainPanel.minSize = mainPanelCurrentMinimumSize
        mainPanel.contentMinSize = mainPanelCurrentMinimumSize
        let maximumSize = mainPanelMaximumSizeForCurrentScreen()
        mainPanel.maxSize = maximumSize
        mainPanel.contentMaxSize = maximumSize
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
        let x = Self.centeredX(for: size, on: screen)
        // Anchor the dropdown a small gap below the pill (or the menu bar if
        // the pill is hidden). Do NOT subtract the pill height from
        // usableFrame.maxY -- the pill sits above the menu bar (in the notch
        // safe area on built-in displays, overlapping the menu bar on
        // externals), so its placement already accounts for any overhang.
        let pillBottomY: CGFloat
        if Self.hasPhysicalNotch(on: screen) {
            var safeTop: CGFloat = 0
            if #available(macOS 12.0, *) {
                safeTop = screen.safeAreaInsets.top
            }
            pillBottomY = screen.frame.maxY - max(38, safeTop + 6)
        } else if let panel, panel.isVisible {
            pillBottomY = panel.frame.minY
        } else {
            let captureSize = NSSize(
                width: Self.collapsedPanelWidth(for: screen, appName: foregroundAppName),
                height: Self.collapsedPanelHeight
            )
            pillBottomY = Self.statusLozengeY(for: captureSize, on: screen)
        }
        let opensFromPhysicalNotch = Self.hasPhysicalNotch(on: screen)
        let anchorY = min(pillBottomY, usableFrame.maxY)
        let notchDownOffset = opensFromPhysicalNotch ? Self.mainPanelPhysicalNotchDownOffset : 0
        let preferredY = anchorY - Self.mainPanelGapBelowCapture - notchDownOffset - size.height
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

    private func preferredPhysicalNotchStatusScreen() -> NSScreen? {
        Self.physicalNotchStatusScreen(preferred: preferredAnchorScreen())
    }

    private func pinAnchorScreenToActiveInteractionIfNeeded() {
        guard let screen = NSScreen.openClickyActiveInteractionScreen() else { return }
        anchorScreenOverride = screen
    }

    private func pinAnchorScreenToPointerFirstActiveInteractionIfNeeded() {
        let mouseLocation = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            anchorScreenOverride = pointerScreen
            return
        }
        pinAnchorScreenToActiveInteractionIfNeeded()
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

    private func startContextAffordanceObservation() {
        guard contextAffordanceTimer == nil else { return }
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeReadableSelectionForContextAffordance()
            }
        }
        contextAffordanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopContextAffordanceObservation() {
        contextAffordanceTimer?.invalidate()
        contextAffordanceTimer = nil
    }

    private func probeCollapsedNotchHover() {
        guard (activeMode == .collapsedText || activeMode == .voice), mainPanel?.isVisible != true else {
            stopCollapsedHoverProbe()
            return
        }
        refreshFallbackStatusPanelOrderingIfNeeded()
        let mouseLocation = NSEvent.mouseLocation
        guard let hoveredScreen = NSScreen.screens.first(where: { Self.notchHoverRegion(on: $0).contains(mouseLocation) }) else { return }

        if anchorScreenOverride?.displayID != hoveredScreen.displayID {
            anchorScreenOverride = hoveredScreen
            let width = activeMode == .voice
                ? Self.voicePanelWidth(for: hoveredScreen, appName: foregroundAppName)
                : Self.collapsedPanelWidth(for: hoveredScreen, appName: foregroundAppName)
            let height = activeMode == .voice ? Self.voicePanelHeight : Self.collapsedPanelHeight
            resizeAndReposition(width: width, height: height)
        }
        if showDynamicNotchKitStatusForCurrentModeIfAvailable(on: hoveredScreen, opensExpanded: true) {
            panel?.orderOut(nil)
        } else if !Self.hasPhysicalNotch(on: hoveredScreen) {
            let width = activeMode == .voice
                ? Self.voicePanelWidth(for: hoveredScreen, appName: foregroundAppName)
                : Self.collapsedPanelWidth(for: hoveredScreen, appName: foregroundAppName)
            let height = activeMode == .voice ? Self.voicePanelHeight : Self.collapsedPanelHeight
            showFallbackStatusPanel(width: width, height: height)
        }
    }


    private static func notchHoverRegion(on screen: NSScreen) -> NSRect {
        let baseWidth = collapsedPanelWidth(for: screen) + 28
        let physicalNotchWidth = hasPhysicalNotch(on: screen)
            ? (physicalNotchWidth(on: screen) ?? 0)
            : 0
        // DynamicNotchKit's compact SwiftUI content only lives on the small
        // leading/trailing icon areas. Keep the global hover probe wide enough
        // to include the black physical notch itself so hovering the main
        // island surface opens it, not just the icons.
        let width = max(baseWidth, physicalNotchWidth + 72, 196)
        let height = max(collapsedPanelHeight + 28, 48)
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: statusLozengeY(for: NSSize(width: width, height: height), on: screen) - 16,
            width: width,
            height: height
        )
    }

    private static func statusLozengeY(for size: NSSize, on screen: NSScreen) -> CGFloat {
        if notchReservedTopInset(on: screen) != nil {
            // On notch MBP: position the pill so its top edge tucks slightly
            // into the notch safe area (under the physical cutout). Small
            // positive overlap hides the seam and keeps it visually "in the notch".
            return screen.frame.maxY - size.height + Self.noNotchScreenTopOverlap
        }
        // External / no-notch screens: sit the pill TOP exactly at the screen
        // top so the rounded top corners are visible.
        return screen.frame.maxY - size.height - Self.topGap
    }

    private static func centeredX(for size: NSSize, on screen: NSScreen) -> CGFloat {
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let usableFrame = visibleFrame.isEmpty ? fullFrame : visibleFrame
        // Center the notch/status pill on the physical display, not the visible
        // frame, so a side Dock or menu-bar reservation cannot shove it off-center.
        let centeredX = fullFrame.midX - size.width / 2 + Self.statusPanelHorizontalNudge

        guard size.width + (Self.screenEdgePadding * 2) > usableFrame.width else {
            return centeredX
        }

        let minX = usableFrame.minX + Self.screenEdgePadding
        let maxX = usableFrame.maxX - size.width - Self.screenEdgePadding
        return min(max(centeredX, minX), maxX)
    }

    private static func voicePanelWidth(for screen: NSScreen?, appName _: String = "Current app") -> CGFloat {
        guard let screen else { return Self.minimumBuiltInCollapsedPanelWidth }

        if isLikelyBuiltInNotchScreen(screen) {
            // On the built-in MacBook Pro notch display, voice state is carried
            // by iconography only: foreground app icon, phase icon, and the
            // right-side live indicator.
            return Self.compactBuiltInVoicePanelWidth
        }

        let preferredWidth = expandedStatusPanelWidth(for: screen)
        guard usesWideExternalNonNotchedStatusPill(on: screen) else {
            return preferredWidth
        }
        return min(
            Self.maximumExternalNonNotchedStatusPanelWidth,
            max(Self.minimumExternalNonNotchedStatusPanelWidth, preferredWidth)
        )
    }

    private static func hidesVoiceStatusText(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        return isLikelyBuiltInNotchScreen(screen)
    }

    private static func isPlaceholderAppName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "Current app"
    }

    // Chrome with the name label hidden: leading pad + app icon (28) + gap (8) + play/dots (14) + trailing pad
    private static let compactCollapsedChromeWidth: CGFloat = 10 + 28 + 8 + 14 + 16

    private static func intrinsicCollapsedWidth(forAppName name: String) -> CGFloat {
        guard !isPlaceholderAppName(name) else {
            return Self.compactCollapsedChromeWidth
        }
        let textWidth = (name as NSString).size(withAttributes: [.font: Self.collapsedLabelFont]).width
        return Self.collapsedChromeWidth + ceil(textWidth)
    }

    private static func collapsedPanelWidth(for screen: NSScreen?, appName: String = "Current app") -> CGFloat {
        guard let screen else { return Self.compactCollapsedChromeWidth }
        if isLikelyBuiltInNotchScreen(screen) {
            return Self.compactCollapsedChromeWidth
        }

        let intrinsic = intrinsicCollapsedWidth(forAppName: appName)
        if usesWideExternalNonNotchedStatusPill(on: screen) {
            return min(
                Self.maximumExternalNonNotchedStatusPanelWidth,
                max(Self.minimumExternalNonNotchedStatusPanelWidth, intrinsic)
            )
        }

        // Keep the legacy compact sizing for built-in/non-notched displays and
        // any unusual notch-capable surface so this external-display widening
        // cannot alter the MacBook Pro screen path.
        let floor: CGFloat = isPlaceholderAppName(appName) ? Self.compactCollapsedChromeWidth : Self.minimumExternalCollapsedPanelWidth

        return min(Self.maximumExternalCollapsedPanelWidth, max(floor, intrinsic))
    }

    private static func widenedStatusFrameIfStillUseful(_ frame: NSRect?, minimumWidth: CGFloat) -> NSRect? {
        guard let frame else { return nil }
        // Older sessions may have persisted a very narrow hand-sized pill.
        // Keep deliberate larger user placements, but let today's wider island
        // defaults take over when the saved width is below the new minimum.
        guard frame.width >= minimumWidth else { return nil }
        return frame
    }

    private static func isRestorablePillFrame(_ frame: NSRect, on screen: NSScreen) -> Bool {
        guard screen.frame.intersects(frame) else { return false }
        let maximumRestorableWidth = isLikelyBuiltInNotchScreen(screen)
            ? max(Self.maximumExpandedStatusPanelWidth + 40, Self.maximumExternalCollapsedPanelWidth + 40)
            : Self.maximumExpandedStatusPanelWidth + 20
        let minimumRestorableWidth = isLikelyBuiltInNotchScreen(screen)
            ? Self.compactCollapsedChromeWidth
            : Self.minimumExternalCollapsedPanelWidth
        return frame.width >= minimumRestorableWidth
            && frame.width <= maximumRestorableWidth
            && frame.height >= 24
            && frame.height <= Self.textPanelHeight
    }

    private static func hidesCollapsedAppNameText(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        return isLikelyBuiltInNotchScreen(screen)
    }

    private static func expandedStatusPanelWidth(for screen: NSScreen) -> CGFloat {
        let visibleWidth = screen.visibleFrame.isEmpty ? screen.frame.width : screen.visibleFrame.width
        let oneThirdWidth = round((visibleWidth / 3) * Self.statusPanelWidthScale)
        return min(
            Self.maximumExpandedStatusPanelWidth,
            max(Self.minimumVoicePanelWidth, oneThirdWidth)
        )
    }

    private static func agentLiveActivity(in companionManager: CompanionManager) -> OpenClickyAgentLiveActivity {
        let runningSessions = companionManager.codexAgentSessions.filter { session in
            guard !companionManager.archivedSessionIDs.contains(session.id) else { return false }
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }

        guard let primary = runningSessions.first(where: { $0.id == companionManager.activeCodexAgentSessionID }) ?? runningSessions.last else {
            return OpenClickyAgentLiveActivity()
        }

        let title = primary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = primary.latestActivitySummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenClickyAgentLiveActivity(
            isActive: true,
            runningCount: runningSessions.count,
            primaryTitle: title.isEmpty ? "Agent working" : title,
            detail: detail?.isEmpty == false ? detail : nil,
            phaseLabel: primary.progressStage.label
        )
    }

    private static func hasRunningAgentWork(in companionManager: CompanionManager) -> Bool {
        agentLiveActivity(in: companionManager).isActive
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

    private static func physicalNotchStatusScreen(preferred: NSScreen?) -> NSScreen? {
        if let preferred, hasPhysicalNotch(on: preferred) {
            return preferred
        }
        return nil
    }

    private static func usesWideExternalNonNotchedStatusPill(on screen: NSScreen) -> Bool {
        !screenLooksBuiltIn(screen)
            && notchReservedTopInset(on: screen) == nil
            && !hasPhysicalNotch(on: screen)
    }

    private static func isLikelyBuiltInNotchScreen(_ screen: NSScreen) -> Bool {
        screenLooksBuiltIn(screen) && notchReservedTopInset(on: screen) != nil
    }

    private static func screenLooksBuiltIn(_ screen: NSScreen) -> Bool {
        if CGDisplayIsBuiltin(screen.displayID) != 0 {
            return true
        }
        let name = screen.localizedName.lowercased()
        return name.contains("built-in")
            || name.contains("liquid retina")
            || name.contains("macbook")
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

    fileprivate static func physicalNotchWidth(on screen: NSScreen) -> CGFloat? {
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

    fileprivate static func hasPhysicalNotch(on screen: NSScreen) -> Bool {
        guard #available(macOS 12.0, *) else {
            return false
        }

        // Only the built-in MacBook display should ever be treated as a
        // physical notch target. External displays can expose split auxiliary
        // top areas while the menu bar settles, which briefly fooled
        // DynamicNotchKit into drawing a fake notch there.
        if screenLooksBuiltIn(screen),
           let notchWidth = physicalNotchWidth(on: screen),
           notchWidth > 0 {
            return true
        }

        return isLikelyBuiltInNotchScreen(screen)
    }

    private static func physicalNotchWindowFrame(on screen: NSScreen) -> NSRect {
        var safeTop: CGFloat = 0
        if #available(macOS 12.0, *) {
            safeTop = screen.safeAreaInsets.top
        }
        let width: CGFloat = 520
        let height: CGFloat = 226 + safeTop
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func updateForegroundAppIcon(bundleIdentifier: String?, bundlePath: String?, appIcon: NSImage?, name: String) {
        guard bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        if let appIcon {
            foregroundAppIcon = appIcon
        } else if let bundlePath {
            foregroundAppIcon = NSWorkspace.shared.icon(forFile: bundlePath)
        } else {
            foregroundAppIcon = nil
        }
        foregroundAppName = name
        contentView?.updateForegroundApp(icon: foregroundAppIcon, name: foregroundAppName)
        if isUsingDynamicNotchKitStatusSurface {
            dynamicNotchKitBridge.updateForegroundApp(icon: foregroundAppIcon, name: foregroundAppName)
        }
        resizePillToCurrentAppName()
    }

    private func showAppContextAffordanceIfUseful(appName: String, appIcon: NSImage?) {
        guard activeMode == .collapsedText, mainPanel?.isVisible != true else { return }
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != "Current app" else { return }
        guard let suggestion = activeCapabilityContextSuggestion(appName: trimmedName, appIcon: appIcon ?? foregroundAppIcon) else { return }
        showContextAffordance(suggestion, signature: "capability:\(suggestion.primaryPrompt)")
    }

    private func probeReadableSelectionForContextAffordance() {
        guard activeMode == .collapsedText, mainPanel?.isVisible != true else { return }
        guard let selectedText = Self.readFocusedSelectedText(), !selectedText.isEmpty else { return }
        let signature = Self.contextSignature(prefix: "selection", value: selectedText)
        guard signature != lastSelectedTextSignature else { return }
        lastSelectedTextSignature = signature
        let appName = foregroundAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "this app" : foregroundAppName
        let suggestion = Self.selectionContextSuggestion(
            selectedText: selectedText,
            appName: appName,
            appIcon: foregroundAppIcon
        )
        showContextAffordance(suggestion, signature: signature)
    }

    private func showContextAffordance(_ suggestion: OpenClickyNotchContextSuggestion, signature: String, ignoresCooldown: Bool = false) {
        guard let submitText = persistentSubmitText else { return }
        // Context suggestions should appear where the user is currently
        // pointing/working, matching the quick-input route, rather than
        // jumping back to the built-in notched display.
        pinAnchorScreenToPointerFirstActiveInteractionIfNeeded()
        guard let screen = preferredAnchorScreen() ?? NSScreen.main else { return }
        let now = Date()
        if !ignoresCooldown {
            if lastContextAffordanceSignature == signature,
               let shownAt = lastContextAffordanceShownAt,
               now.timeIntervalSince(shownAt) < Self.contextAffordanceCooldown {
                return
            }
            if lastContextAffordanceSignature != signature,
               let shownAt = lastContextAffordanceShownAt,
               now.timeIntervalSince(shownAt) < 5 {
                return
            }
        }
        lastContextAffordanceSignature = signature
        lastContextAffordanceShownAt = now
        panel?.orderOut(nil)
        isUsingDynamicNotchKitStatusSurface = true
        dynamicNotchKitBridge.showContextSuggestion(
            suggestion,
            on: screen,
            accentColor: persistentAccentColor,
            foregroundAppIcon: foregroundAppIcon,
            foregroundAppName: foregroundAppName,
            submitText: submitText
        )
    }

    private func activeCapabilityContextSuggestion(appName: String? = nil, appIcon: NSImage? = nil) -> OpenClickyNotchContextSuggestion? {
        OpenClickySkillDiscoveryStore.shared.reload()
        let trimmedAppName = (appName ?? foregroundAppName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppName.isEmpty, trimmedAppName != "Current app" else { return nil }

        let activeSuggestions = OpenClickySkillDiscoveryStore.shared.suggestions.filter { suggestion in
            let id = suggestion.id.lowercased()
            return id.hasPrefix("active-") && !id.hasSuffix("-screen-context")
        }
        guard !activeSuggestions.isEmpty else { return nil }

        let actions = activeSuggestions.prefix(3).map { suggestion in
            OpenClickyNotchContextAction(
                title: suggestion.chipTitle ?? suggestion.title,
                systemImage: suggestion.systemImage ?? Self.contextSystemImage(forSuggestionSource: suggestion.source),
                prompt: suggestion.installPrompt
            )
        }
        let primaryPrompt = activeSuggestions.first?.installPrompt
            ?? "Use OpenClicky with the active \(trimmedAppName) window and suggest the next useful action."
        let title = activeSuggestions.first?.title ?? "Use OpenClicky with \(trimmedAppName)?"
        let subtitle = activeSuggestions.first?.detail ?? "A relevant OpenClicky capability is available for \(trimmedAppName)."

        return OpenClickyNotchContextSuggestion(
            source: .app,
            title: title,
            subtitle: subtitle,
            appIcon: appIcon ?? foregroundAppIcon,
            appName: trimmedAppName,
            actions: actions,
            primaryPrompt: primaryPrompt
        )
    }

    private static func contextSystemImage(forSuggestionSource source: String) -> String {
        switch source.lowercased() {
        case "mcp": return "point.3.connected.trianglepath.dotted"
        case "installed", "local": return "hammer.fill"
        case "online": return "square.and.arrow.down"
        default: return "sparkles"
        }
    }

    private static func appContextSuggestion(appName: String, appIcon: NSImage?) -> OpenClickyNotchContextSuggestion {
        OpenClickyNotchContextSuggestion(
            source: .app,
            title: "Use OpenClicky with \(appName)?",
            subtitle: "OpenClicky can read the active app context and suggest safe actions.",
            appIcon: appIcon,
            appName: appName,
            actions: [
                OpenClickyNotchContextAction(
                    title: "Summarise this window",
                    systemImage: "text.page",
                    prompt: "Summarise what is visible in \(appName) using OpenClicky's current screen context."
                ),
                OpenClickyNotchContextAction(
                    title: "Suggest actions",
                    systemImage: "sparkles",
                    prompt: "Look at the active \(appName) window and suggest the most useful OpenClicky actions."
                ),
                OpenClickyNotchContextAction(
                    title: "Start an agent",
                    systemImage: "shippingbox",
                    prompt: "Start an OpenClicky agent using the current \(appName) window as context."
                )
            ],
            primaryPrompt: "Use OpenClicky with the active \(appName) window and suggest the next useful action."
        )
    }

    private static func selectionContextSuggestion(selectedText: String, appName: String, appIcon: NSImage?) -> OpenClickyNotchContextSuggestion {
        let snippet = selectedText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortSnippet = String(snippet.prefix(90))
        return OpenClickyNotchContextSuggestion(
            source: .selection,
            title: "Use selected text with OpenClicky?",
            subtitle: shortSnippet.isEmpty ? "Selection detected in \(appName)." : "“\(shortSnippet)”",
            appIcon: appIcon,
            appName: appName,
            actions: [
                OpenClickyNotchContextAction(
                    title: "Summarise selection",
                    systemImage: "text.alignleft",
                    prompt: "Summarise this selected text from \(appName):\n\n\(selectedText)"
                ),
                OpenClickyNotchContextAction(
                    title: "Rewrite it",
                    systemImage: "pencil.and.scribble",
                    prompt: "Rewrite this selected text clearly and concisely:\n\n\(selectedText)"
                ),
                OpenClickyNotchContextAction(
                    title: "Make action items",
                    systemImage: "checklist",
                    prompt: "Extract action items from this selected text:\n\n\(selectedText)"
                )
            ],
            primaryPrompt: "Help me with this selected text from \(appName):\n\n\(selectedText)"
        )
    }

    private static func contextSignature(prefix: String, value: String) -> String {
        let compact = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(prefix):\(compact.prefix(180))"
    }

    private static func readFocusedSelectedText() -> String? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedResult == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let focusedElement = focusedValue as! AXUIElement
        var selectedValue: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectedResult == .success,
              let rawText = selectedValue as? String else {
            return nil
        }

        let compact = rawText.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count >= 4 else { return nil }
        return String(compact.prefix(1_500))
    }

    private func resizePillToCurrentAppName() {
        guard let panel, panel.isVisible else { return }
        let height: CGFloat
        let widthForScreen: (NSScreen) -> CGFloat
        switch activeMode {
        case .voice:
            height = Self.voicePanelHeight
            widthForScreen = { [foregroundAppName] screen in
                Self.voicePanelWidth(for: screen, appName: foregroundAppName)
            }
        case .collapsedText, .none:
            height = Self.collapsedPanelHeight
            widthForScreen = { [foregroundAppName] screen in
                Self.collapsedPanelWidth(for: screen, appName: foregroundAppName)
            }
        }
        let primaryScreen = preferredAnchorScreen() ?? NSScreen.main ?? panel.screen ?? NSScreen.screens.first
        guard let primaryScreen else { return }
        let primaryWidth = widthForScreen(primaryScreen)
        resizeAndReposition(width: primaryWidth, height: height)
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

    private func refreshAccentColorFromDefaults() {
        let accentColor = Self.nsAccentColor(for: nil)
        persistentAccentColor = accentColor
        contentView?.updateAccentColor(accentColor)
        if isUsingDynamicNotchKitStatusSurface {
            dynamicNotchKitBridge.updateTheme(accentColor: accentColor, theme: ClickyTheme.current)
        }
        if let glassBackdrop = mainPanelGlassBackdrop {
            glassBackdrop.configure(
                cornerRadius: 28,
                roundsTopCorners: true,
                accentColor: accentColor,
                strength: .expanded
            )
        }
        refreshThemeAppearance()
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

        let applyToWindow = { (window: NSWindow?) in
            guard let window else { return }
            if let appearanceName = appearanceName {
                window.appearance = NSAppearance(named: appearanceName)
            } else {
                window.appearance = nil
            }
        }

        applyToWindow(panel)
        applyToWindow(mainPanel)
    }

    static func nsAccentColor(for theme: ClickyAccentTheme?) -> NSColor {
        switch theme ?? ClickyAccentTheme.current {
        case .blue:
            return NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
        case .cyan:
            return NSColor(calibratedRed: 0.13, green: 0.83, blue: 0.93, alpha: 1.0)
        case .mint:
            return NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1.0)
        case .lime:
            return NSColor(calibratedRed: 0.64, green: 0.90, blue: 0.21, alpha: 1.0)
        case .amber:
            return NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 1.0)
        case .orange:
            return NSColor(calibratedRed: 1.00, green: 0.54, blue: 0.24, alpha: 1.0)
        case .rose:
            return NSColor(calibratedRed: 1.00, green: 0.31, blue: 0.37, alpha: 1.0)
        case .violet:
            return NSColor(calibratedRed: 0.61, green: 0.43, blue: 1.00, alpha: 1.0)
        case .white:
            return NSColor(calibratedWhite: 0.97, alpha: 1.0)
        }
    }
}

private final class OpenClickyNotchCaptureRootView: NSView {
    private enum Mode {
        case collapsed
        case voice
    }

    private let notchHandle = OpenClickyRoundedView(cornerRadius: 5)
    fileprivate let shellGlassView = OpenClickyLiquidGlassBackdropView(cornerRadius: 24)
    fileprivate let shellView = OpenClickyRoundedView(cornerRadius: 24)
    
    fileprivate var shellWidthConstraint: NSLayoutConstraint?
    fileprivate var shellHeightConstraint: NSLayoutConstraint?
    fileprivate var shellCenterXConstraint: NSLayoutConstraint?
    fileprivate var shellTopConstraint: NSLayoutConstraint?
    private let voiceStack = NSStackView()
    private let voiceTitleLabel = NSTextField(labelWithString: "Listening")
    private let voiceSubtitleLabel = NSTextField(labelWithString: "")
    private let voiceCopyStack = NSStackView()
    private let voicePhaseIconView = NSImageView()
    private var voiceCopyMinimumWidthConstraint: NSLayoutConstraint?
    private var collapsedStackLeadingConstraint: NSLayoutConstraint?
    private var collapsedPlayIconTrailingConstraint: NSLayoutConstraint?
    private var collapsedAgentDotsTrailingConstraint: NSLayoutConstraint?
    private var voiceStackTrailingConstraint: NSLayoutConstraint?
    private let voiceNotchSpacer = NSView()
    private let waveformView = OpenClickyNotchWaveformNSView()
    private let collapsedAppIconView = NSImageView()
    private let collapsedPlayIconView = NSImageView()
    private let collapsedAgentDotsView = OpenClickyNotchDotsNSView()
    private let voiceAppIconView = NSImageView()
    private let collapsedAppNameLabel = NSTextField(labelWithString: "Current app")
    private var hidesCollapsedAppNameText = false
    private var mode: Mode = .voice
    private var dismiss: (() -> Void)?
    private var expand: (() -> Void)?
    private var accentColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
    private var pendingDeferredShellLayout = false

    private static let collapsedLabelMaxWidth: CGFloat = 300

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildViewHierarchy()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func updateShellViewFillColor() {
        let usesLightFill: Bool
        switch ClickyTheme.current {
        case .light:
            usesLightFill = true
        case .dark:
            usesLightFill = false
        case .system:
            let bestMatch = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            usesLightFill = bestMatch != .darkAqua
        }
        let baseColor = usesLightFill ? NSColor.white : NSColor.black
        let borderColor = usesLightFill ? NSColor.black : NSColor.white
        switch mode {
        case .collapsed:
            shellView.fillColor = OpenClickyLiquidGlassBackdropView.isLiquidGlassAvailable ? baseColor.withAlphaComponent(usesLightFill ? 0.24 : 0.34) : baseColor.withAlphaComponent(usesLightFill ? 0.88 : 0.93)
        case .voice:
            shellView.fillColor = OpenClickyLiquidGlassBackdropView.isLiquidGlassAvailable ? baseColor.withAlphaComponent(usesLightFill ? 0.21 : 0.30) : baseColor.withAlphaComponent(usesLightFill ? 0.86 : 0.91)
        }
        shellView.borderColor = borderColor.withAlphaComponent(usesLightFill ? 0.11 : 0.07)
        needsDisplay = true
    }

    func configureCollapsed(accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, hasRunningAgentWork: Bool, hidesAppNameText: Bool = false, expand: @escaping () -> Void, dismiss: @escaping () -> Void) {
        mode = .collapsed
        self.accentColor = accentColor
        self.expand = expand
        self.dismiss = dismiss
        hidesCollapsedAppNameText = hidesAppNameText
        voiceStack.isHidden = true
        let nameIsPlaceholder = foregroundAppName.trimmingCharacters(in: .whitespaces).isEmpty
            || foregroundAppName == "Current app"
        collapsedAppIconView.isHidden = foregroundAppIcon == nil
        collapsedAppNameLabel.isHidden = hidesAppNameText || nameIsPlaceholder
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
        updateShellViewFillColor()
        shellView.roundedShadowColor = nil
        shellView.roundedShadowBlurRadius = 0
        shellView.roundedShadowOffset = .zero
        updateForegroundApp(icon: foregroundAppIcon, name: foregroundAppName)
        updateShellConstraints(animated: true)
        needsDisplay = true
    }

    func configureVoice(
        phase: OpenClickyNotchVoicePhase,
        audioPowerLevel: CGFloat,
        accentColor: NSColor,
        foregroundAppIcon: NSImage?,
        foregroundAppName: String,
        hidesStatusText: Bool = false,
        expand: (() -> Void)? = nil
    ) {
        mode = .voice
        self.accentColor = accentColor
        self.expand = expand
        notchHandle.isHidden = true
        shellView.isHidden = false
        shellGlassView.isHidden = false
        shellGlassView.configure(cornerRadius: 17, roundsTopCorners: false, accentColor: accentColor, strength: .compact)
        shellView.roundsTopCorners = false
        voiceStack.isHidden = false
        voicePhaseIconView.isHidden = !hidesStatusText
        voiceCopyStack.isHidden = hidesStatusText
        voiceTitleLabel.isHidden = hidesStatusText
        collapsedAppIconView.isHidden = true
        collapsedAppNameLabel.isHidden = true
        collapsedPlayIconView.isHidden = true
        collapsedAgentDotsView.isHidden = true
        shellView.cornerRadius = 17
        updateShellViewFillColor()
        shellView.roundedShadowColor = accentColor.withAlphaComponent(0.34)
        shellView.roundedShadowBlurRadius = 22
        shellView.roundedShadowOffset = .zero
        updateAccentColors()
        updateForegroundApp(icon: foregroundAppIcon, name: foregroundAppName)
        updateVoiceLabels(for: phase, foregroundAppName: foregroundAppName, hidesStatusText: hidesStatusText)
        waveformView.audioPowerLevel = audioPowerLevel
        waveformView.accentColor = accentColor
        updateShellConstraints(animated: true)
    }

    func updateForegroundApp(icon: NSImage?, name: String) {
        let nameIsPlaceholder = name.trimmingCharacters(in: .whitespaces).isEmpty
            || name == "Current app"
        collapsedAppIconView.image = icon
        voiceAppIconView.image = icon
        collapsedAppNameLabel.stringValue = name
        collapsedAppIconView.isHidden = mode != .collapsed || icon == nil
        collapsedAppNameLabel.isHidden = mode != .collapsed || hidesCollapsedAppNameText || nameIsPlaceholder
        collapsedPlayIconView.isHidden = mode != .collapsed || !collapsedAgentDotsView.isHidden
        if mode != .collapsed {
            collapsedAgentDotsView.isHidden = true
        }
        voiceAppIconView.isHidden = mode != .voice || icon == nil
    }

    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {
        waveformView.audioPowerLevel = audioPowerLevel
    }

    func updateAccentColor(_ accentColor: NSColor) {
        self.accentColor = accentColor
        collapsedPlayIconView.contentTintColor = accentColor
        collapsedAgentDotsView.accentColor = accentColor
        voicePhaseIconView.contentTintColor = accentColor
        waveformView.accentColor = accentColor
        switch mode {
        case .collapsed:
            shellGlassView.configure(cornerRadius: 17, roundsTopCorners: false, accentColor: accentColor, strength: .compact)
        case .voice:
            shellGlassView.configure(cornerRadius: 17, roundsTopCorners: false, accentColor: accentColor, strength: .compact)
            shellView.roundedShadowColor = accentColor.withAlphaComponent(0.34)
            shellView.roundedShadowBlurRadius = 22
            shellView.roundedShadowOffset = .zero
        }
        updateShellViewFillColor()
        updateAccentColors()
        needsDisplay = true
    }

    func setCanvas(size: NSSize, animated: Bool = false) {
        frame = NSRect(origin: .zero, size: size)
        bounds = NSRect(origin: .zero, size: size)
        needsLayout = true
        needsDisplay = true
        updateShellConstraints(animated: animated)
        // Force the resize-edge cursor rects to recompute against the new
        // width so the hit zones track the pill as it grows/shrinks.
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        
        let trackingRect: NSRect
        if let screen = window?.screen, OpenClickyNotchCaptureWindowManager.hasPhysicalNotch(on: screen) {
            trackingRect = shellView.frame
        } else {
            trackingRect = bounds
        }
        
        addTrackingArea(NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard mode == .collapsed || mode == .voice else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        if let screen = window?.screen, OpenClickyNotchCaptureWindowManager.hasPhysicalNotch(on: screen) {
            guard shellView.frame.contains(localPoint) else { return }
        } else {
            guard bounds.contains(localPoint) || shellView.frame.contains(localPoint) else { return }
        }
        expand?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateShellConstraints(animated: false)
        }
    }

    private func updateShellConstraints(animated: Bool) {
        guard let window = window else { return }
        let isOnNotchScreen: Bool
        let notchWidth: CGFloat
        let safeAreaTop: CGFloat
        if let screen = window.screen, OpenClickyNotchCaptureWindowManager.hasPhysicalNotch(on: screen) {
            isOnNotchScreen = true
            notchWidth = OpenClickyNotchCaptureWindowManager.physicalNotchWidth(on: screen) ?? 172
            var topInset: CGFloat = 0
            if #available(macOS 12.0, *) {
                topInset = screen.safeAreaInsets.top
            }
            safeAreaTop = topInset
        } else {
            isOnNotchScreen = false
            notchWidth = 0
            safeAreaTop = 0
        }

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if isOnNotchScreen {
            switch mode {
            case .collapsed:
                targetWidth = notchWidth * 2.0
                targetHeight = max(38, safeAreaTop + 6)
            case .voice:
                targetWidth = notchWidth * 2.0
                targetHeight = max(38, safeAreaTop + 6)
            }
        } else {
            targetWidth = bounds.width
            targetHeight = bounds.height
        }

        let changes = { [weak self] in
            guard let self else { return }
            self.shellWidthConstraint?.constant = targetWidth
            self.shellHeightConstraint?.constant = targetHeight
            
            if isOnNotchScreen {
                self.collapsedStackLeadingConstraint?.constant = 18
                self.collapsedPlayIconTrailingConstraint?.constant = -OpenClickyNotchCaptureWindowManager.builtInStatusTrailingInset
                self.collapsedAgentDotsTrailingConstraint?.constant = -OpenClickyNotchCaptureWindowManager.builtInStatusTrailingInset
                self.voiceStackTrailingConstraint?.constant = -OpenClickyNotchCaptureWindowManager.builtInVoiceTrailingInset
                
                self.voiceNotchSpacer.isHidden = false
                self.voiceCopyStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            } else {
                self.collapsedStackLeadingConstraint?.constant = 10
                self.collapsedPlayIconTrailingConstraint?.constant = -OpenClickyNotchCaptureWindowManager.externalStatusTrailingInset
                self.collapsedAgentDotsTrailingConstraint?.constant = -OpenClickyNotchCaptureWindowManager.externalStatusTrailingInset
                self.voiceStackTrailingConstraint?.constant = -OpenClickyNotchCaptureWindowManager.externalVoiceTrailingInset

                // The voice pill can be wider than its intrinsic contents on
                // external/fallback surfaces. Keep the middle spacer alive in
                // voice mode so the title stays left and the live indicator
                // hugs the right edge instead of clustering after the label.
                self.voiceNotchSpacer.isHidden = self.mode != .voice
                self.voiceCopyStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            }
            
            self.scheduleDeferredShellLayout()
        }

        if animated && window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                changes()
            }
        } else {
            changes()
        }
        
        updateTrackingAreas()
        window.invalidateCursorRects(for: self)
    }

    private func scheduleDeferredShellLayout() {
        needsLayout = true
        shellGlassView.needsLayout = true
        shellView.needsLayout = true

        guard !pendingDeferredShellLayout else { return }
        pendingDeferredShellLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingDeferredShellLayout = false
            self.needsLayout = true
            self.shellGlassView.needsLayout = true
            self.shellView.needsLayout = true
            self.updateTrackingAreas()
            if let window = self.window {
                window.invalidateCursorRects(for: self)
            }
        }
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateShellViewFillColor()
        }

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
        // The shell-level click recognizer was removed in favor of the
        // mouseDown/mouseUp drag-aware handling on the root view (see
        // OpenClickyNotchCaptureRootView.mouseDown). A single source of truth
        // avoids "drag fires expand as well" double-events.

        configureForegroundAppIconViews()
        configureVoiceStack()

        let widthConstraint = shellView.widthAnchor.constraint(equalToConstant: bounds.width)
        let heightConstraint = shellView.heightAnchor.constraint(equalToConstant: bounds.height)
        let centerXConstraint = shellView.centerXAnchor.constraint(equalTo: centerXAnchor)
        let topConstraint = shellView.topAnchor.constraint(equalTo: topAnchor)
        
        shellWidthConstraint = widthConstraint
        shellHeightConstraint = heightConstraint
        shellCenterXConstraint = centerXConstraint
        shellTopConstraint = topConstraint

        NSLayoutConstraint.activate([
            notchHandle.topAnchor.constraint(equalTo: topAnchor),
            notchHandle.centerXAnchor.constraint(equalTo: centerXAnchor),
            notchHandle.widthAnchor.constraint(equalToConstant: 52),
            notchHandle.heightAnchor.constraint(equalToConstant: 10),

            shellGlassView.topAnchor.constraint(equalTo: shellView.topAnchor),
            shellGlassView.leadingAnchor.constraint(equalTo: shellView.leadingAnchor),
            shellGlassView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor),
            shellGlassView.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),

            widthConstraint,
            heightConstraint,
            centerXConstraint,
            topConstraint
        ])
    }

    private func configureForegroundAppIconViews() {
        for imageView in [collapsedAppIconView, collapsedPlayIconView, voiceAppIconView, voicePhaseIconView] {
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = (imageView == collapsedAppIconView || imageView == voiceAppIconView) ? 6 : 4
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

        let playIconTrailing = collapsedPlayIconView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: CGFloat(-OpenClickyNotchCaptureWindowManager.externalStatusTrailingInset))
        let agentDotsTrailing = collapsedAgentDotsView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: CGFloat(-OpenClickyNotchCaptureWindowManager.externalStatusTrailingInset))
        let stackLeading = collapsedStack.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 10)

        collapsedPlayIconTrailingConstraint = playIconTrailing
        collapsedAgentDotsTrailingConstraint = agentDotsTrailing
        collapsedStackLeadingConstraint = stackLeading

        NSLayoutConstraint.activate([
            collapsedAppIconView.widthAnchor.constraint(equalToConstant: 28),
            collapsedAppIconView.heightAnchor.constraint(equalToConstant: 28),
            collapsedPlayIconView.widthAnchor.constraint(equalToConstant: 14),
            collapsedPlayIconView.heightAnchor.constraint(equalToConstant: 14),
            playIconTrailing,
            collapsedPlayIconView.centerYAnchor.constraint(equalTo: shellView.centerYAnchor),
            collapsedAgentDotsView.widthAnchor.constraint(equalToConstant: 20),
            collapsedAgentDotsView.heightAnchor.constraint(equalToConstant: 8),
            agentDotsTrailing,
            collapsedAgentDotsView.centerYAnchor.constraint(equalTo: shellView.centerYAnchor),
            stackLeading,
            collapsedStack.trailingAnchor.constraint(lessThanOrEqualTo: collapsedPlayIconView.leadingAnchor, constant: -8),
            collapsedStack.trailingAnchor.constraint(lessThanOrEqualTo: collapsedAgentDotsView.leadingAnchor, constant: -8),
            collapsedStack.centerYAnchor.constraint(equalTo: shellView.centerYAnchor),
            // Keep common app names like "Google Chrome" readable while still
            // letting unusually long names tail-truncate inside the compact
        // notch bar instead of forcing the whole surface wide again.
            collapsedAppNameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.collapsedLabelMaxWidth)
        ])
    }

    @objc private func handleCollapsedClick(_ recognizer: NSClickGestureRecognizer) {
        guard mode == .collapsed else { return }
        expand?()
    }

    func setAgentWorkActive(_ isActive: Bool, foregroundAppName _: String) {
        collapsedPlayIconView.isHidden = isActive
        collapsedAgentDotsView.isHidden = !isActive
        collapsedAgentDotsView.isActive = isActive
        needsDisplay = true
    }

    private func configureVoiceStack() {
        voiceStack.orientation = .horizontal
        voiceStack.alignment = .centerY
        voiceStack.spacing = 5
        voiceStack.distribution = .fill
        voiceStack.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(voiceStack)

        voiceCopyStack.orientation = .vertical
        voiceCopyStack.alignment = .leading
        voiceCopyStack.spacing = 0
        voiceCopyStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        voiceCopyStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voiceNotchSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        voiceNotchSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voiceTitleLabel.font = .systemFont(ofSize: 14, weight: .heavy)
        voiceTitleLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        voiceTitleLabel.lineBreakMode = .byTruncatingTail
        voiceSubtitleLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        voiceSubtitleLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        voiceSubtitleLabel.lineBreakMode = .byTruncatingTail
        voiceSubtitleLabel.isHidden = true
        voiceAppIconView.setContentHuggingPriority(.required, for: .horizontal)
        voiceAppIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        voicePhaseIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .heavy)
        voicePhaseIconView.contentTintColor = accentColor
        voicePhaseIconView.setContentHuggingPriority(.required, for: .horizontal)
        voicePhaseIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.setContentHuggingPriority(.required, for: .horizontal)
        waveformView.setContentCompressionResistancePriority(.required, for: .horizontal)
        voiceStack.addArrangedSubview(voiceAppIconView)
        voiceStack.addArrangedSubview(voicePhaseIconView)
        voiceCopyStack.addArrangedSubview(voiceTitleLabel)
        voiceCopyStack.addArrangedSubview(voiceSubtitleLabel)
        voiceStack.addArrangedSubview(voiceCopyStack)
        voiceStack.addArrangedSubview(voiceNotchSpacer)
        voiceStack.addArrangedSubview(waveformView)
        voiceAppIconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        voiceAppIconView.heightAnchor.constraint(equalToConstant: 28).isActive = true
        voicePhaseIconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        voicePhaseIconView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let copyMinimumWidthConstraint = voiceCopyStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        copyMinimumWidthConstraint.isActive = true
        voiceCopyMinimumWidthConstraint = copyMinimumWidthConstraint
        // Let the middle space flex so the state/app cluster hugs the leading
        // edge and the live indicator hugs the trailing edge instead of both
        // components clustering in the center of the notch.
        voiceNotchSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true
        let voiceSpacerExpansionConstraint = voiceNotchSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        voiceSpacerExpansionConstraint.priority = .defaultLow
        voiceSpacerExpansionConstraint.isActive = true
        waveformView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        waveformView.heightAnchor.constraint(equalToConstant: 8).isActive = true

        // Pin the two voice groups to opposite sides of the pill: icon/status
        // on the left, live waveform/indicator on the right.
        let voiceTrailing = voiceStack.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: CGFloat(-OpenClickyNotchCaptureWindowManager.externalVoiceTrailingInset))
        voiceStackTrailingConstraint = voiceTrailing
        NSLayoutConstraint.activate([
            voiceStack.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 12),
            voiceTrailing,
            voiceStack.centerYAnchor.constraint(equalTo: shellView.centerYAnchor)
        ])
        voiceStack.isHidden = true
    }

    private func updateAccentColors() {
        waveformView.accentColor = accentColor
        shellView.needsDisplay = true
    }

    private func updateVoiceLabels(for phase: OpenClickyNotchVoicePhase, foregroundAppName _: String, hidesStatusText: Bool) {
        voiceSubtitleLabel.stringValue = ""
        voiceSubtitleLabel.isHidden = true
        voiceTitleLabel.isHidden = hidesStatusText
        voiceCopyStack.isHidden = hidesStatusText
        voicePhaseIconView.isHidden = !hidesStatusText
        voiceCopyMinimumWidthConstraint?.constant = hidesStatusText ? 0 : 72
        let symbolName: String
        switch phase {
        case .listening:
            voiceTitleLabel.stringValue = "Listening"
            symbolName = "waveform"
            waveformView.isActive = true
        case .processing:
            voiceTitleLabel.stringValue = "Thinking"
            symbolName = "brain.head.profile"
            waveformView.isActive = false
        case .responding:
            voiceTitleLabel.stringValue = "Speaking"
            symbolName = "speaker.wave.2.fill"
            waveformView.isActive = true
        case .idle:
            voiceTitleLabel.stringValue = "Ready"
            symbolName = "checkmark.circle.fill"
            waveformView.isActive = false
        }
        voicePhaseIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: voiceTitleLabel.stringValue)
        voicePhaseIconView.contentTintColor = accentColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Claim physical-notch collapsed clicks for the root view so mouseDown
    // reliably fires the drag-aware/expand path instead of a child control.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        
        if let window = window, let screen = window.screen, OpenClickyNotchCaptureWindowManager.hasPhysicalNotch(on: screen) {
            guard shellView.frame.contains(localPoint) else {
                return nil
            }
            if mode == .collapsed {
                return self
            }
            return super.hitTest(point)
        }
        
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if let screen = window?.screen, OpenClickyNotchCaptureWindowManager.hasPhysicalNotch(on: screen) {
            super.mouseDown(with: event)
            return
        }
        if mode == .collapsed {
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .collapsed {
            expand?()
            return
        }
        super.mouseUp(with: event)
    }

}

final class OpenClickyLiquidGlassBackdropView: NSView {
    enum Strength {
        case compact
        case expanded
    }

    static var isLiquidGlassAvailable: Bool {
        true
    }

    private let glassContainerView = NSGlassEffectContainerView()
    private let glassContentView = NSView()
    private let glassView = NSGlassEffectView()
    private let persistentAccentView = OpenClickyLiquidGlassAccentWashView()
    private var defaultsObserver: NSObjectProtocol?
    private let maskLayer = CAShapeLayer()
    private var cornerRadius: CGFloat
    private var roundsTopCorners = true
    private var accentColor: NSColor = .systemBlue
    private var strength: Strength = .compact

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLiquidGlassState()
    }

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        glassContainerView.translatesAutoresizingMaskIntoConstraints = false
        glassContentView.translatesAutoresizingMaskIntoConstraints = false
        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassContainerView.contentView = glassContentView
        glassContainerView.spacing = 8
        glassView.style = .regular
        glassContentView.addSubview(glassView)
        addSubview(glassContainerView)

        persistentAccentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(persistentAccentView)

        NSLayoutConstraint.activate([
            glassContainerView.topAnchor.constraint(equalTo: topAnchor),
            glassContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            glassView.topAnchor.constraint(equalTo: glassContentView.topAnchor),
            glassView.leadingAnchor.constraint(equalTo: glassContentView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: glassContentView.trailingAnchor),
            glassView.bottomAnchor.constraint(equalTo: glassContentView.bottomAnchor),

            persistentAccentView.topAnchor.constraint(equalTo: topAnchor),
            persistentAccentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            persistentAccentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            persistentAccentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        applyShape()
        updateLiquidGlassState()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateLiquidGlassState()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func updateLiquidGlassState() {
        let opacity = UserDefaults.standard.object(forKey: AppBundleConfiguration.userGlassOpacityDefaultsKey) as? Double ?? 0.75
        let frosting = UserDefaults.standard.object(forKey: AppBundleConfiguration.userGlassFrostingDefaultsKey) as? Double ?? 0.20

        glassView.style = .regular
        glassView.cornerRadius = cornerRadius
        glassView.tintColor = nativeGlassTint(opacity: opacity, frosting: frosting)
        persistentAccentView.configure(
            accentColor: accentColor,
            opacity: opacity,
            frosting: frosting,
            cornerRadius: cornerRadius,
            roundsTopCorners: roundsTopCorners,
            strength: strength
        )
        needsDisplay = true
    }

    func configure(cornerRadius: CGFloat, roundsTopCorners: Bool, accentColor: NSColor, strength: Strength) {
        self.cornerRadius = cornerRadius
        self.roundsTopCorners = roundsTopCorners
        self.accentColor = accentColor
        self.strength = strength
        updateLiquidGlassState()
        applyShape()
    }

    override func layout() {
        super.layout()
        applyShape()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Native Liquid Glass rendering is handled by NSGlassEffectView.
    }

    private func applyShape() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        if roundsTopCorners {
            layer?.mask = nil
            layer?.cornerRadius = cornerRadius
            if #available(macOS 10.15, *) {
                layer?.cornerCurve = .continuous
            }
        } else {
            let path = cgPath(in: bounds)
            maskLayer.path = path
            layer?.mask = maskLayer
            if #available(macOS 10.15, *) {
                maskLayer.cornerCurve = .continuous
            }
        }
        layer?.backgroundColor = NSColor.clear.cgColor
        glassView.cornerRadius = cornerRadius
        persistentAccentView.cornerRadius = cornerRadius
        persistentAccentView.roundsTopCorners = roundsTopCorners
        persistentAccentView.needsDisplay = true
    }

    private func nativeGlassTint(opacity: Double, frosting: Double) -> NSColor? {
        let clampedFrosting = min(max(frosting, 0.0), 1.0)
        let clampedOpacity = min(max(opacity, 0.0), 1.0)
        let strengthBoost = strength == .expanded ? 0.012 : 0.0
        let alpha = CGFloat(0.006 + strengthBoost + clampedOpacity * 0.012 + clampedFrosting * 0.025)
        return accentColor.withAlphaComponent(alpha)
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
        let filletRadius: CGFloat = 8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        
        path.addCurve(
            to: CGPoint(x: rect.maxX - filletRadius, y: rect.maxY - filletRadius),
            control1: CGPoint(x: rect.maxX - filletRadius * 0.5, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - filletRadius, y: rect.maxY - filletRadius * 0.5)
        )
        
        path.addLine(to: CGPoint(x: rect.maxX - filletRadius, y: rect.minY + radius))
        
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - filletRadius - radius, y: rect.minY),
            control: CGPoint(x: rect.maxX - filletRadius, y: rect.minY)
        )
        
        path.addLine(to: CGPoint(x: rect.minX + filletRadius + radius, y: rect.minY))
        
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + filletRadius, y: rect.minY + radius),
            control: CGPoint(x: rect.minX + filletRadius, y: rect.minY)
        )
        
        path.addLine(to: CGPoint(x: rect.minX + filletRadius, y: rect.maxY - filletRadius))
        
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY),
            control1: CGPoint(x: rect.minX + filletRadius, y: rect.maxY - filletRadius * 0.5),
            control2: CGPoint(x: rect.minX + filletRadius * 0.5, y: rect.maxY)
        )
        
        path.closeSubpath()
        return path
    }
}

private final class OpenClickyLiquidGlassAccentWashView: NSView {
    var accentColor: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var glassOpacity: Double = 0.75 { didSet { needsDisplay = true } }
    var glassFrosting: Double = 0.20 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 28 { didSet { needsDisplay = true } }
    var roundsTopCorners: Bool = true { didSet { needsDisplay = true } }
    var strength: OpenClickyLiquidGlassBackdropView.Strength = .expanded { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    func configure(
        accentColor: NSColor,
        opacity: Double,
        frosting: Double,
        cornerRadius: CGFloat,
        roundsTopCorners: Bool,
        strength: OpenClickyLiquidGlassBackdropView.Strength
    ) {
        self.accentColor = accentColor
        self.glassOpacity = opacity
        self.glassFrosting = frosting
        self.cornerRadius = cornerRadius
        self.roundsTopCorners = roundsTopCorners
        self.strength = strength
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let clampedOpacity = min(max(glassOpacity, 0.0), 1.0)
        let clampedFrosting = min(max(glassFrosting, 0.0), 1.0)
        let baseAlpha = strength == .expanded ? 0.050 : 0.038
        let accentAlpha = CGFloat(baseAlpha + clampedOpacity * 0.018 + clampedFrosting * 0.020)

        NSGraphicsContext.saveGraphicsState()
        clippedPath().addClip()

        accentColor.withAlphaComponent(accentAlpha).setFill()
        bounds.fill()

        let gradient = NSGradient(colors: [
            accentColor.withAlphaComponent(accentAlpha * 0.95),
            accentColor.withAlphaComponent(accentAlpha * 0.32),
            NSColor.white.withAlphaComponent(strength == .expanded ? 0.014 : 0.010)
        ])
        gradient?.draw(
            from: NSPoint(x: bounds.minX, y: bounds.minY),
            to: NSPoint(x: bounds.maxX, y: bounds.maxY),
            options: []
        )

        NSGraphicsContext.restoreGraphicsState()
    }

    private func clippedPath() -> NSBezierPath {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard !roundsTopCorners else {
            return NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let filletRadius: CGFloat = 8
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        
        path.curve(
            to: NSPoint(x: rect.maxX - filletRadius, y: rect.minY + filletRadius),
            controlPoint1: NSPoint(x: rect.maxX - filletRadius * 0.5, y: rect.minY),
            controlPoint2: NSPoint(x: rect.maxX - filletRadius, y: rect.minY + filletRadius * 0.5)
        )
        
        path.line(to: NSPoint(x: rect.maxX - filletRadius, y: rect.maxY - radius))
        
        path.curve(
            to: NSPoint(x: rect.maxX - filletRadius - radius, y: rect.maxY),
            controlPoint1: NSPoint(x: rect.maxX - filletRadius, y: rect.maxY - radius * 0.45),
            controlPoint2: NSPoint(x: rect.maxX - filletRadius - radius * 0.45, y: rect.maxY)
        )
        
        path.line(to: NSPoint(x: rect.minX + filletRadius + radius, y: rect.maxY))
        
        path.curve(
            to: NSPoint(x: rect.minX + filletRadius, y: rect.maxY - radius),
            controlPoint1: NSPoint(x: rect.minX + filletRadius + radius * 0.45, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.minX + filletRadius, y: rect.maxY - radius * 0.45)
        )
        
        path.line(to: NSPoint(x: rect.minX + filletRadius, y: rect.minY + filletRadius))
        
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.minY),
            controlPoint1: NSPoint(x: rect.minX + filletRadius, y: rect.minY + filletRadius * 0.5),
            controlPoint2: NSPoint(x: rect.minX + filletRadius * 0.5, y: rect.minY)
        )
        
        path.close()
        return path
    }
}

@MainActor
enum OpenClickyLiquidGlassWindowSurface {
    @discardableResult
    static func install<Content: View>(
        hostingView: NSHostingView<Content>,
        in window: NSWindow,
        frame: NSRect,
        cornerRadius: CGFloat,
        roundsTopCorners: Bool = true,
        accentColor: NSColor? = nil,
        strength: OpenClickyLiquidGlassBackdropView.Strength = .expanded
    ) -> OpenClickyLiquidGlassBackdropView {
        window.isOpaque = false
        window.backgroundColor = .clear

        let containerView = OpenClickyGlassContainerView(frame: frame)
        containerView.autoresizingMask = [.width, .height]
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        let backdrop = OpenClickyLiquidGlassBackdropView(cornerRadius: cornerRadius)
        backdrop.frame = containerView.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.configure(
            cornerRadius: cornerRadius,
            roundsTopCorners: roundsTopCorners,
            accentColor: accentColor ?? OpenClickyNotchCaptureWindowManager.nsAccentColor(for: nil),
            strength: strength
        )
        containerView.addSubview(backdrop)

        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)

        window.contentView = containerView
        return backdrop
    }

    static func hostingView<Content: View>(in window: NSWindow?) -> NSHostingView<Content>? {
        findHostingView(in: window?.contentView)
    }

    private static func findHostingView<Content: View>(in view: NSView?) -> NSHostingView<Content>? {
        guard let view else { return nil }
        if let hostingView = view as? NSHostingView<Content> {
            return hostingView
        }

        for subview in view.subviews {
            if let hostingView: NSHostingView<Content> = findHostingView(in: subview) {
                return hostingView
            }
        }
        return nil
    }
}

final class OpenClickyGlassContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}

private final class OpenClickyRoundedView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderColor: NSColor = .clear { didSet { updateLayerShape(); needsDisplay = true } }
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
        } else if borderColor.alphaComponent > 0 {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.04
            layer.shadowRadius = 0
            layer.shadowOffset = NSSize(width: 0, height: -1)
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
        let filletRadius: CGFloat = 8
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        
        path.curve(
            to: NSPoint(x: rect.maxX - filletRadius, y: rect.maxY - filletRadius),
            controlPoint1: NSPoint(x: rect.maxX - filletRadius * 0.5, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.maxX - filletRadius, y: rect.maxY - filletRadius * 0.5)
        )
        
        path.line(to: NSPoint(x: rect.maxX - filletRadius, y: rect.minY + radius))
        
        path.curve(
            to: NSPoint(x: rect.maxX - filletRadius - radius, y: rect.minY),
            controlPoint1: NSPoint(x: rect.maxX - filletRadius, y: rect.minY + radius * 0.45),
            controlPoint2: NSPoint(x: rect.maxX - filletRadius - radius * 0.45, y: rect.minY)
        )
        
        path.line(to: NSPoint(x: rect.minX + filletRadius + radius, y: rect.minY))
        
        path.curve(
            to: NSPoint(x: rect.minX + filletRadius, y: rect.minY + radius),
            controlPoint1: NSPoint(x: rect.minX + filletRadius + radius * 0.45, y: rect.minY),
            controlPoint2: NSPoint(x: rect.minX + filletRadius, y: rect.minY + radius * 0.45)
        )
        
        path.line(to: NSPoint(x: rect.minX + filletRadius, y: rect.maxY - filletRadius))
        
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.maxY),
            controlPoint1: NSPoint(x: rect.minX + filletRadius, y: rect.maxY - filletRadius * 0.5),
            controlPoint2: NSPoint(x: rect.minX + filletRadius * 0.5, y: rect.maxY)
        )
        
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
        let filletRadius: CGFloat = 8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        
        path.addCurve(
            to: CGPoint(x: rect.maxX - filletRadius, y: rect.maxY - filletRadius),
            control1: CGPoint(x: rect.maxX - filletRadius * 0.5, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - filletRadius, y: rect.maxY - filletRadius * 0.5)
        )
        
        path.addLine(to: CGPoint(x: rect.maxX - filletRadius, y: rect.minY + radius))
        
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - filletRadius - radius, y: rect.minY),
            control: CGPoint(x: rect.maxX - filletRadius, y: rect.minY)
        )
        
        path.addLine(to: CGPoint(x: rect.minX + filletRadius + radius, y: rect.minY))
        
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + filletRadius, y: rect.minY + radius),
            control: CGPoint(x: rect.minX + filletRadius, y: rect.minY)
        )
        
        path.addLine(to: CGPoint(x: rect.minX + filletRadius, y: rect.maxY - filletRadius))
        
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY),
            control1: CGPoint(x: rect.minX + filletRadius, y: rect.maxY - filletRadius * 0.5),
            control2: CGPoint(x: rect.minX + filletRadius * 0.5, y: rect.maxY)
        )
        
        path.closeSubpath()
        return path
    }
}

private final class OpenClickyMainPanelHostingView<Content: View>: NSHostingView<Content> {
    // Keep SwiftUI controls in charge of their own drag gestures. Window
    // movement is handled by the explicit drag affordance/top drag band below,
    // so sliders and other draggable controls should not start moving the panel.
    override var mouseDownCanMoveWindow: Bool { false }
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
    var onResizeBegan: (() -> Void)?
    var onResizeFrameChanged: ((NSSize) -> Void)?
    var onResizeEnded: ((NSSize) -> Void)?
    private(set) var isUserResizing = false

    private let edgeHitWidth: CGFloat = 18
    private let topResizeHitHeight: CGFloat = 8
    private let cornerHitLength: CGFloat = 40
    private let bottomRightHitSize: CGFloat = 58
    private let topDragHitHeight: CGFloat = 18
    private let resizeHandleView = OpenClickyMainPanelResizeHandleView(frame: .zero)
    private var activeEdges: ResizeEdges = []
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartFrame: NSRect = .zero
    private var windowWasMovableByBackground = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        addSubview(resizeHandleView)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview !== resizeHandleView {
            resizeHandleView.removeFromSuperview()
            addSubview(resizeHandleView)
        }
    }

    override func layout() {
        super.layout()
        subviews.forEach { subview in
            if subview === resizeHandleView {
                subview.frame = NSRect(
                    x: max(0, bounds.maxX - 64),
                    y: bounds.minY,
                    width: min(64, bounds.width),
                    height: min(64, bounds.height)
                )
            } else {
                subview.frame = bounds
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if isResizeEnabled?() == true, !resizeEdges(at: point).isEmpty {
            return self
        }
        if draggablePanelPoint(point) {
            return self
        }
        return super.hitTest(point) ?? self
    }

    override func resetCursorRects() {
        guard isResizeEnabled?() == true else { return }
        addCursorRect(NSRect(x: 0, y: 0, width: edgeHitWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.maxX - edgeHitWidth, y: 0, width: edgeHitWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: edgeHitWidth), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.maxY - topResizeHitHeight, width: bounds.width, height: topResizeHitHeight), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: bounds.maxX - bottomRightHitSize, y: 0, width: bottomRightHitSize, height: bottomRightHitSize), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard isResizeEnabled?() == true else {
            super.mouseDown(with: event)
            return
        }
        activeEdges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        guard !activeEdges.isEmpty, let window else {
            if let window, draggablePanelPoint(convert(event.locationInWindow, from: nil)) {
                window.performDrag(with: event)
                applyResizeFrame(window.frame, to: window)
                return
            }
            super.mouseDown(with: event)
            return
        }
        isUserResizing = true
        windowWasMovableByBackground = window.isMovableByWindowBackground
        window.isMovableByWindowBackground = false
        onResizeBegan?()
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

        applyResizeFrame(frame, to: window)
    }

    override func mouseUp(with event: NSEvent) {
        if let window {
            window.isMovableByWindowBackground = windowWasMovableByBackground
            onResizeEnded?(window.frame.size)
            window.displayIfNeeded()
            if let contentView = window.contentView {
                window.invalidateCursorRects(for: contentView)
            }
        }
        isUserResizing = false
        activeEdges = []
        window?.contentView?.needsLayout = true
    }

    private func applyResizeFrame(_ frame: NSRect, to window: NSWindow) {
        let frame = constrainedVisibleFrame(frame, for: window)
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
        window.setFrame(alignedFrame, display: false, animate: false)
        CATransaction.commit()
        onResizeFrameChanged?(alignedFrame.size)
    }

    private func constrainedVisibleFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else {
            return frame
        }
        let visibleFrame = screen.visibleFrame
        let usableFrame = visibleFrame.isEmpty ? screen.frame : visibleFrame
        let padding: CGFloat = 12
        var constrained = frame

        let minX = usableFrame.minX + padding
        let maxX = usableFrame.maxX - padding - constrained.width
        if maxX >= minX {
            constrained.origin.x = min(max(constrained.origin.x, minX), maxX)
        } else {
            constrained.origin.x = minX
        }

        let minY = usableFrame.minY + padding
        let maxY = usableFrame.maxY - padding - constrained.height
        if maxY >= minY {
            constrained.origin.y = min(max(constrained.origin.y, minY), maxY)
        } else {
            constrained.origin.y = minY
        }

        return constrained
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        guard bounds.contains(point) else { return [] }

        var edges: ResizeEdges = []
        let inBottomRightGrip = point.x >= bounds.maxX - bottomRightHitSize && point.y <= bottomRightHitSize
        let nearLeft = point.x <= edgeHitWidth
        let nearRight = point.x >= bounds.maxX - edgeHitWidth
        let nearBottom = point.y <= edgeHitWidth
        let nearTop = point.y >= bounds.maxY - topResizeHitHeight
        let inLowerCornerBand = point.y <= cornerHitLength
        let inUpperCornerBand = point.y >= bounds.maxY - cornerHitLength
        let inLeftCornerBand = point.x <= cornerHitLength
        let inRightCornerBand = point.x >= bounds.maxX - cornerHitLength

        if nearLeft || (inLeftCornerBand && (nearTop || nearBottom)) { edges.insert(.left) }
        if nearRight || inBottomRightGrip || (inRightCornerBand && (nearTop || nearBottom)) { edges.insert(.right) }
        if nearBottom || inBottomRightGrip || (inLowerCornerBand && (nearLeft || nearRight)) { edges.insert(.bottom) }
        if nearTop || (inUpperCornerBand && (nearLeft || nearRight)) { edges.insert(.top) }
        return edges
    }

    private func draggablePanelPoint(_ point: NSPoint) -> Bool {
        guard bounds.contains(point), resizeEdges(at: point).isEmpty else { return false }
        return point.y >= bounds.maxY - topDragHitHeight
    }
}

private final class OpenClickyMainPanelResizeHandleView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(2)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.34).cgColor)

        let inset: CGFloat = 13
        let spacing: CGFloat = 7
        let maxX = bounds.maxX - inset
        let maxY = bounds.maxY - inset
        for index in 0..<3 {
            let offset = CGFloat(index) * spacing
            context.move(to: CGPoint(x: maxX - 22 + offset, y: maxY))
            context.addLine(to: CGPoint(x: maxX, y: maxY - 22 + offset))
        }
        context.strokePath()

        context.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        context.fillEllipse(in: CGRect(x: bounds.maxX - 18, y: bounds.maxY - 18, width: 5, height: 5))
        context.restoreGState()
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
