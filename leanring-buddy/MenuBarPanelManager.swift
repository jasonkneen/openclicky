//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside unless pinned.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    static let clickyPanelContentSizeDidChange = Notification.Name("clickyPanelContentSizeDidChange")
}

private enum CompanionPanelContentMode {
    case main
    case settings
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var contentSizeObserver: NSObjectProtocol?
    private var isPanelPinned = false
    private var currentContentMode: CompanionPanelContentMode = .main

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 356
    private let panelHeight: CGFloat = 428
    private let panelMinimumSize = NSSize(width: 356, height: 428)
    private let transientPanelScreenEdgePadding: CGFloat = 12
    private let transientPanelMaximumContentHeight: CGFloat = 720

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        contentSizeObserver = NotificationCenter.default.addObserver(
            forName: .clickyPanelContentSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let isShowingSettings = notification.userInfo?["isShowingSettings"] as? Bool {
                self?.currentContentMode = isShowingSettings ? .settings : .main
            }
            self?.resizeVisiblePanelToCurrentContent()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = contentSizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the clicky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            if isPanelPinned {
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
            } else {
                hidePanel()
            }
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        if !isPanelPinned {
            positionPanelBelowStatusItem()
        } else {
            enforcePanelMinimumSize()
        }

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(
            companionManager: companionManager,
            isPanelPinned: isPanelPinned,
            setPanelPinned: { [weak self] isPinned in
                self?.setPanelPinned(isPinned)
            }
        )
        .frame(
            minWidth: panelWidth,
            maxWidth: .infinity,
            minHeight: panelHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.isReleasedWhenClosed = false
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true
        applyPanelMinimumSize(to: menuBarPanel)
        menuBarPanel.setFrameAutosaveName("OpenClickyPinnedCompanionPanelV100ContentWrap")

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
        applyPinnedPanelBehavior()
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? statusItemFrame
        let maximumPanelWidth = max(
            panelMinimumSize.width,
            visibleFrame.width - (transientPanelScreenEdgePadding * 2)
        )
        let availablePanelHeight = max(
            panelMinimumSize.height,
            statusItemFrame.minY - visibleFrame.minY - gapBelowMenuBar - transientPanelScreenEdgePadding
        )
        let maximumPanelHeight = min(availablePanelHeight, transientPanelMaximumContentHeight)

        let actualPanelHeight = preferredPanelHeight(maximumPanelHeight: maximumPanelHeight)

        // Horizontally center the panel beneath the status item icon
        let currentPanelWidth = max(panel.frame.width, panelWidth)
        let actualPanelWidth = min(currentPanelWidth, maximumPanelWidth)
        let centeredPanelOriginX = statusItemFrame.midX - (actualPanelWidth / 2)
        let panelOriginX = min(
            max(centeredPanelOriginX, visibleFrame.minX + transientPanelScreenEdgePadding),
            visibleFrame.maxX - actualPanelWidth - transientPanelScreenEdgePadding
        )
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: actualPanelWidth, height: actualPanelHeight),
            display: true
        )
    }

    private func resizeVisiblePanelToCurrentContent() {
        guard let panel, panel.isVisible else { return }

        DispatchQueue.main.async {
            if self.isPanelPinned {
                self.resizePinnedPanelToCurrentContent()
            } else {
                self.positionPanelBelowStatusItem()
            }
        }
    }

    private func preferredPanelHeight(maximumPanelHeight: CGFloat) -> CGFloat {
        switch currentContentMode {
        case .main:
            return min(max(panelMinimumSize.height, panelHeight), maximumPanelHeight)
        case .settings:
            let fittingSize = panel?.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
            let measuredPanelHeight = max(panelMinimumSize.height, fittingSize.height)
            return min(measuredPanelHeight, maximumPanelHeight)
        }
    }

    private func resizePinnedPanelToCurrentContent() {
        guard let panel else { return }
        guard let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }

        let maximumPanelWidth = max(panelMinimumSize.width, visibleFrame.width - (transientPanelScreenEdgePadding * 2))
        let maximumPanelHeight = min(
            max(panelMinimumSize.height, visibleFrame.height - (transientPanelScreenEdgePadding * 2)),
            transientPanelMaximumContentHeight
        )
        let constrainedWidth = min(panel.frame.width, maximumPanelWidth)
        let constrainedHeight = preferredPanelHeight(maximumPanelHeight: maximumPanelHeight)

        guard constrainedWidth != panel.frame.width || constrainedHeight != panel.frame.height else { return }

        let topY = panel.frame.maxY
        let constrainedOriginX = min(
            max(panel.frame.origin.x, visibleFrame.minX + transientPanelScreenEdgePadding),
            visibleFrame.maxX - constrainedWidth - transientPanelScreenEdgePadding
        )
        let constrainedOriginY = min(
            max(topY - constrainedHeight, visibleFrame.minY + transientPanelScreenEdgePadding),
            visibleFrame.maxY - constrainedHeight - transientPanelScreenEdgePadding
        )

        panel.setFrame(
            NSRect(x: constrainedOriginX, y: constrainedOriginY, width: constrainedWidth, height: constrainedHeight),
            display: true
        )
    }

    private func applyPanelMinimumSize(to panel: NSPanel) {
        panel.minSize = panelMinimumSize
        panel.contentMinSize = panelMinimumSize
    }

    private func enforcePanelMinimumSize() {
        guard let panel else { return }
        let currentFrame = panel.frame
        let constrainedWidth = max(currentFrame.width, panelMinimumSize.width)
        let constrainedHeight = max(currentFrame.height, panelMinimumSize.height)

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

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        guard !isPanelPinned else { return }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func setPanelPinned(_ isPinned: Bool) {
        guard isPanelPinned != isPinned else { return }
        isPanelPinned = isPinned
        applyPinnedPanelBehavior()

        guard let panel else { return }
        if isPinned {
            removeClickOutsideMonitor()
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        } else {
            positionPanelBelowStatusItem()
            if panel.isVisible {
                installClickOutsideMonitor()
            }
        }
    }

    private func applyPinnedPanelBehavior() {
        guard let panel else { return }

        if isPanelPinned {
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            panel.title = "OpenClicky"
            panel.titleVisibility = .visible
            panel.titlebarAppearsTransparent = false
            panel.isMovableByWindowBackground = false
            panel.isFloatingPanel = false
            panel.level = .normal
            panel.isOpaque = true
            panel.backgroundColor = .windowBackgroundColor
            panel.hasShadow = true
            panel.collectionBehavior = []
            applyPanelMinimumSize(to: panel)
        } else {
            panel.styleMask = [.borderless, .nonactivatingPanel, .resizable]
            panel.title = ""
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = false
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            applyPanelMinimumSize(to: panel)
        }

        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        enforcePanelMinimumSize()
    }
}
