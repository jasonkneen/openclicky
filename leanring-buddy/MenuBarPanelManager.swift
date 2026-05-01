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
    private var contentResizeWorkItem: DispatchWorkItem?
    private var isPanelPinned = false

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 356
    private let panelHeight: CGFloat = 318
    private let panelMinimumSize = NSSize(width: 356, height: 300)
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
            Task { @MainActor [weak self] in
                self?.hidePanel()
            }
        }

        contentSizeObserver = NotificationCenter.default.addObserver(
            forName: .clickyPanelContentSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resizeVisiblePanelToCurrentContent()
            }
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
        let isCreatingPanel = panel == nil
        if panel == nil {
            createPanel()
        }

        if !isPanelPinned {
            positionPanelBelowStatusItem(allowFittingSize: !isCreatingPanel)
        } else {
            enforcePanelMinimumSize()
        }

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()

        if isCreatingPanel {
            resizeVisiblePanelToCurrentContent(after: 0.08)
        }
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

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
        applyPinnedPanelBehavior()
    }

    private func positionPanelBelowStatusItem(allowFittingSize: Bool = true) {
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

        let actualPanelHeight = preferredPanelHeight(
            maximumPanelHeight: maximumPanelHeight,
            allowFittingSize: allowFittingSize
        )

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
        resizeVisiblePanelToCurrentContent(after: 0.03)
    }

    private func resizeVisiblePanelToCurrentContent(after delay: TimeInterval) {
        guard let panel, panel.isVisible else { return }

        contentResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if self.isPanelPinned {
                self.resizePinnedPanelToCurrentContent()
            } else {
                self.positionPanelBelowStatusItem()
            }
        }
        contentResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func preferredPanelHeight(maximumPanelHeight: CGFloat, allowFittingSize: Bool = true) -> CGFloat {
        if allowFittingSize,
           let panel,
           let contentView = panel.contentView {
            contentView.layoutSubtreeIfNeeded()
            contentView.invalidateIntrinsicContentSize()
            let fittingHeight = ceil(contentView.fittingSize.height)
            if fittingHeight.isFinite, fittingHeight > 0 {
                return min(max(panelMinimumSize.height, fittingHeight), maximumPanelHeight)
            }
        }

        return min(max(panelMinimumSize.height, panelHeight), maximumPanelHeight)
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

// MARK: - Agent Menu Bar Status Items

@MainActor
final class AgentMenuBarStatusManager: NSObject {
    private var statusItemsByItemID: [UUID: NSStatusItem] = [:]
    private var latestItemsByID: [UUID: ClickyAgentDockItem] = [:]
    private var syncTask: Task<Void, Never>?
    private var activePopover: NSPopover?
    private weak var companionManager: CompanionManager?

    func scheduleSync(companionManager: CompanionManager) {
        syncTask?.cancel()
        syncTask = Task { [weak companionManager, weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            await MainActor.run {
                guard let self, let companionManager else { return }
                self.sync(companionManager: companionManager)
            }
        }
    }

    func sync(companionManager: CompanionManager) {
        self.companionManager = companionManager
        let visibleItems = Array(companionManager.agentDockItems.suffix(5))
        latestItemsByID = Dictionary(uniqueKeysWithValues: visibleItems.map { ($0.id, $0) })

        let visibleIDs = Set(visibleItems.map(\.id))
        let staleIDs = statusItemsByItemID.keys.filter { !visibleIDs.contains($0) }
        for itemID in staleIDs {
            if let statusItem = statusItemsByItemID.removeValue(forKey: itemID) {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
        }

        for item in visibleItems {
            let statusItem = statusItemsByItemID[item.id] ?? makeStatusItem(for: item)
            statusItemsByItemID[item.id] = statusItem
            update(statusItem: statusItem, with: item)
        }
    }

    private func makeStatusItem(for item: ClickyAgentDockItem) -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            button.target = self
            button.action = #selector(agentStatusItemClicked(_:))
            button.imagePosition = .imageOnly
        }
        return statusItem
    }

    private func update(statusItem: NSStatusItem, with item: ClickyAgentDockItem) {
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip(for: item)
        button.image = makeAgentStatusIcon(theme: item.accentTheme, status: item.status)
        button.image?.isTemplate = false
    }

    @objc private func agentStatusItemClicked(_ sender: NSStatusBarButton) {
        guard let rawID = sender.identifier?.rawValue,
              let itemID = UUID(uuidString: rawID),
              let item = latestItemsByID[itemID] else { return }

        if let activePopover, activePopover.isShown {
            activePopover.performClose(nil)
            if activePopover.contentViewController?.representedObject as? UUID == itemID {
                return
            }
        }

        guard let companionManager else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let rootView = AgentMenuBarStatusPopoverView(
            item: item,
            canOpenDashboard: companionManager.isAdvancedModeEnabled,
            voice: { [weak companionManager] in
                companionManager?.prepareVoiceFollowUpForAgentDockItem(item.id)
            },
            text: { [weak companionManager] in
                companionManager?.showTextFollowUpForAgentDockItem(item.id)
            },
            dashboard: { [weak companionManager] in
                companionManager?.openAgentDockItem(item.id)
            },
            close: { [weak popover] in
                popover?.performClose(nil)
            },
            stop: { [weak companionManager, weak popover] in
                popover?.performClose(nil)
                companionManager?.stopAgentDockItem(item.id)
            },
            runSuggestedAction: { [weak companionManager, weak popover] actionTitle in
                popover?.performClose(nil)
                companionManager?.runSuggestedNextAction(actionTitle)
            },
            dismiss: { [weak companionManager, weak popover] in
                // Close == dismiss the finished item: hide the popover
                // and remove the dock entry. dismissAgentDockItem is
                // UI-only — it does NOT send a cancel signal (the agent
                // is already terminal here).
                popover?.performClose(nil)
                companionManager?.dismissAgentDockItem(item.id)
            }
        )
        let controller = NSHostingController(rootView: rootView)
        controller.representedObject = itemID
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 420, height: 300)
        activePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func tooltip(for item: ClickyAgentDockItem) -> String {
        let status: String
        switch item.status {
        case .starting: status = "Starting"
        case .running: status = "Working"
        case .done: status = "Done"
        case .failed: status = "Needs attention"
        }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Agent: \(status)" : "Agent: \(status) — \(title)"
    }

    private func makeAgentStatusIcon(theme: ClickyAccentTheme, status: ClickyAgentDockStatus) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let accent = Self.nsColor(for: theme)
        let center = CGPoint(x: size * 0.48, y: size * 0.50)
        let radius: CGFloat = 7.2

        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        accent.withAlphaComponent(status == .running ? 0.36 : 0.20).setStroke()
        ring.lineWidth = status == .running ? 2.0 : 1.2
        ring.stroke()

        let triangleSize = size * 0.55
        let height = triangleSize * sqrt(3.0) / 2.0
        let top = CGPoint(x: center.x, y: center.y + height / 1.5)
        let bottomLeft = CGPoint(x: center.x - triangleSize / 2, y: center.y - height / 3)
        let bottomRight = CGPoint(x: center.x + triangleSize / 2, y: center.y - height / 3)
        let angle = -35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - center.x, dy = point.y - center.y
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: center.x + cosA * dx - sinA * dy, y: center.y + sinA * dx + cosA * dy)
        }
        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()
        accent.setFill()
        path.fill()

        let dotColor: NSColor
        switch status {
        case .starting: dotColor = NSColor.systemBlue
        case .running: dotColor = accent
        case .done: dotColor = NSColor.systemGreen
        case .failed: dotColor = NSColor.systemRed
        }
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: size - 6.2, y: size - 6.2, width: 5.4, height: 5.4)).fill()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let dotStroke = NSBezierPath(ovalIn: NSRect(x: size - 6.2, y: size - 6.2, width: 5.4, height: 5.4))
        dotStroke.lineWidth = 0.7
        dotStroke.stroke()

        image.unlockFocus()
        return image
    }

    private static func nsColor(for theme: ClickyAccentTheme) -> NSColor {
        switch theme {
        case .blue: return NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1)
        case .mint: return NSColor(calibratedRed: 0.21, green: 0.83, blue: 0.60, alpha: 1)
        case .amber: return NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 1)
        case .rose: return NSColor(calibratedRed: 1.00, green: 0.31, blue: 0.37, alpha: 1)
        }
    }
}

private struct AgentMenuBarStatusPopoverView: View {
    private let popoverWidth: CGFloat = 420
    let item: ClickyAgentDockItem
    let canOpenDashboard: Bool
    let voice: () -> Void
    let text: () -> Void
    let dashboard: () -> Void
    let close: () -> Void
    let stop: () -> Void
    let runSuggestedAction: (String) -> Void
    /// Called when the user taps "Dismiss" on a terminal (`.done` / `.failed`)
    /// agent. Distinct from `stop` (which sends a cancel signal) — Dismiss
    /// dismisses the popover AND removes the finished item from the dock
    /// collection so it stops occupying the menu bar.
    let dismiss: () -> Void
    @State private var isConfirmingStop = false
    @State private var hoveredQuickAction: QuickAction? = nil
    @State private var statusLineCycleIndex = 0
    @State private var statusLineCycleTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                Text(statusText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(statusColor.opacity(0.18)))

                Text(titleText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .padding(.trailing, 30)

            VStack(alignment: .leading, spacing: 3) {
                Text("Stage: \(item.progressStageLabel)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.70))
                    .lineLimit(1)

                if let statusLine = currentStatusLine {
                    Text("\(statusLineLabel): \(statusLine)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.58))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if let liveProgressText, !liveProgressText.isEmpty {
                    Text(liveProgressText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.82))
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // No real activity yet — emit a thinking affordance
                    // instead of "An agent is working on this." so the user
                    // sees real-time progress, not canned filler.
                    AgentMenuBarThinkingDots(tint: item.accentTheme.cursorColor)
                }

                HStack(spacing: 8) {
                    if let linkTarget {
                        Button {
                            NSWorkspace.shared.open(linkTarget)
                        } label: {
                            Label(linkButtonTitle(for: linkTarget), systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                    }

                    Spacer(minLength: 0)

                    if item.status == .starting || item.status == .running {
                        Button("Stop") {
                            isConfirmingStop = true
                        }
                        .foregroundColor(Color(hex: "#FFB4BA"))
                        .confirmationDialog("Stop this agent?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
                            Button("Stop", role: .destructive, action: stop)
                            Button("Keep running", role: .cancel) {}
                        }
                    }
                }
            }

            if !item.suggestedNextActions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(item.suggestedNextActions, id: \.self) { actionTitle in
                        Button(actionTitle) {
                            runSuggestedAction(actionTitle)
                        }
                        .lineLimit(1)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 8) {
                stopControls
                HStack(spacing: 10) {
                    quickActionButton(icon: "mic", label: "Voice", quickAction: .voice, action: voice)
                    quickActionButton(icon: "text.cursor", label: "Text", quickAction: .text, action: text)
                    if canOpenDashboard {
                        quickActionButton(icon: "rectangle.grid.2x2", label: "Dashboard", quickAction: .dashboard, action: dashboard)
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .semibold))
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(Color.white.opacity(0.72))
            .offset(x: 8, y: -8)
        }
        .padding(14)
        .frame(width: popoverWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [item.accentTheme.cursorColor.opacity(0.20), Color(hex: "#111827")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .onAppear { restartStatusLineCycle() }
        .onDisappear {
            statusLineCycleTask?.cancel()
            statusLineCycleTask = nil
        }
        .onChange(of: item.activityStatusLines) { _, _ in
            restartStatusLineCycle()
        }
        .onChange(of: item.progressStepText ?? "") { _, _ in
            restartStatusLineCycle()
        }
    }

    @ViewBuilder
    private var stopControls: some View {
        // Closing the panel should never cancel/remove the task. Keep
        // "Close" available for every state. For terminal sessions,
        // provide a separate explicit "Dismiss" action to remove it.
        switch item.status {
        case .done, .failed:
            Button("Close", action: close)
                .foregroundColor(Color.white.opacity(0.82))
            Button("Dismiss", action: dismiss)
                .foregroundColor(Color.white.opacity(0.82))
        case .starting, .running:
            Button("Close", action: close)
                .foregroundColor(Color.white.opacity(0.82))
        }
    }

    @ViewBuilder
    private func quickActionButton(icon: String, label: String, quickAction: QuickAction, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                if hoveredQuickAction == quickAction {
                    Text(label)
                }
            }
        }
        .onHover { hoveredQuickAction = $0 ? quickAction : nil }
    }

    private enum QuickAction {
        case voice, text, dashboard
    }

    private var linkTarget: URL? {
        Self.firstOpenableURL(in: liveProgressText ?? "")
    }

    private var statusLineLabel: String {
        activityStatusLines.count > 1 ? "Update" : "Step"
    }

    private var currentStatusLine: String? {
        let lines = activityStatusLines
        guard !lines.isEmpty else { return nil }
        let safeIndex = min(statusLineCycleIndex, lines.count - 1)
        return lines[safeIndex]
    }

    private var activityStatusLines: [String] {
        var lines: [String] = []
        for candidate in item.activityStatusLines + [item.progressStepText ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !lines.contains(trimmed) {
                lines.append(trimmed)
            }
        }
        return lines
    }

    /// Caption text — only the actual streamed agent activity. nil when the
    /// agent has not produced any output yet so the view can render a
    /// thinking indicator instead of the "An agent is working on this."
    /// placeholder.
    private var liveProgressText: String? {
        let trimmed = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        switch item.status {
        case .starting, .running:
            return nil
        case .done:
            return "Done."
        case .failed:
            return "Needs attention."
        }
    }

    private func linkButtonTitle(for url: URL) -> String {
        url.isFileURL ? "Open \(url.lastPathComponent)" : "Open link"
    }

    private static func firstOpenableURL(in text: String) -> URL? {
        let patterns = [
            #"`((?:file://)?/[^`]+)`"#,
            #"((?:file://)?/Users/[^\s`]+)"#,
            #"(https?://[^\s`]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,)\n\t "))
            if raw.hasPrefix("file://"), let url = URL(string: raw) { return url }
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
            if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        }
        return nil
    }

    private var titleText: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Agent task" : title
    }


    private var statusText: String {
        switch item.status {
        case .starting: return "Starting"
        case .running: return "Working"
        case .done: return "Done"
        case .failed: return "Attention"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .starting: return Color(hex: "#93C5FD")
        case .running: return item.accentTheme.cursorColor
        case .done: return Color(hex: "#34D399")
        case .failed: return Color(hex: "#FF6369")
        }
    }

    private func restartStatusLineCycle() {
        statusLineCycleTask?.cancel()
        statusLineCycleTask = nil
        statusLineCycleIndex = 0
        let count = activityStatusLines.count
        guard count > 1 else { return }
        statusLineCycleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if Task.isCancelled { return }
                let lineCount = activityStatusLines.count
                guard lineCount > 1 else { return }
                statusLineCycleIndex = (statusLineCycleIndex + 1) % lineCount
            }
        }
    }
}

/// Three softly-pulsing dots used in the menu-bar status popover while the
/// agent has not yet produced its first streamed token. Replaces the
/// previous static "An agent is working on this." caption fallback.
private struct AgentMenuBarThinkingDots: View {
    let tint: Color
    @State private var phase: Int = 0
    /// Stored handle for the phase-cycling task so we can cancel it in
    /// `onDisappear`. Without this, every popover open/close leaks
    /// another infinite task — the menu-bar popover is shown/hidden far
    /// more often than the dock card, so the leak compounds quickly.
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint.opacity(opacity(for: index)))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            animationTask?.cancel()
            animationTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 360_000_000)
                    if Task.isCancelled { return }
                    phase = (phase + 1) % 3
                }
            }
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
        }
    }

    private func opacity(for index: Int) -> Double {
        index == phase ? 0.95 : 0.32
    }
}
