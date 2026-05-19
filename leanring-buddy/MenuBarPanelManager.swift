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
    static let clickyShowPanel = Notification.Name("clickyShowPanel")
    static let clickyPanelContentSizeDidChange = Notification.Name("clickyPanelContentSizeDidChange")
    static let clickyMainPanelResizeStateDidChange = Notification.Name("clickyMainPanelResizeStateDidChange")
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
    private var showPanelObserver: NSObjectProtocol?
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

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showPanel()
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
        if let observer = showPanelObserver {
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
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemContextMenu(from: sender)
            return
        }

        togglePanelVisibility()
    }

    private func togglePanelVisibility() {
        if let panel, panel.isVisible {
            if isPanelPinned {
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
            } else {
                hidePanel()
            }
        } else {
            showMainInterfacePanel()
        }
    }

    private func showStatusItemContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()

        let quickItem = NSMenuItem(
            title: "Quick Ask OpenClicky",
            action: #selector(quickAskOpenClickyFromStatusMenu),
            keyEquivalent: ""
        )
        quickItem.target = self
        menu.addItem(quickItem)

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(openSettingsFromStatusMenu),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(agentHistoryMenuItem())

        menu.popUp(positioning: quickItem, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func agentHistoryMenuItem() -> NSMenuItem {
        let historyItem = NSMenuItem(title: "Task History", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Task History")
        let sessions = companionManager.codexAgentSessions.reversed()

        if sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No tasks yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for session in sessions {
                let item = NSMenuItem(
                    title: historyTitle(for: session),
                    action: #selector(openHistorySessionFromStatusMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                submenu.addItem(item)
            }
        }

        historyItem.submenu = submenu
        return historyItem
    }

    private func historyTitle(for session: CodexAgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "Untitled task" : title
        return "\(statusLabel(for: session.status)) · \(fallbackTitle)"
    }

    private func statusLabel(for status: CodexAgentSessionStatus) -> String {
        switch status {
        case .starting: return "Starting"
        case .running: return "Working"
        case .ready: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    @objc private func quickAskOpenClickyFromStatusMenu() {
        companionManager.showQuickTextInputFromMenuBar()
    }

    @objc private func openSettingsFromStatusMenu() {
        companionManager.showSettingsWindow()
    }

    @objc private func openHistorySessionFromStatusMenu(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? UUID else { return }
        companionManager.selectCodexAgentSession(sessionID)
        companionManager.showCodexHUD()
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        showMainInterfacePanel()
    }

    private func showMainInterfacePanel() {
        hidePanel()
        companionManager.notchCaptureWindowManager.showMainInterfacePanel(companionManager: companionManager)
    }

    private func showLegacyStatusItemPanel() {
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
        let notchPanelView = OpenClickyNotchPanelView(
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

        let hostingView = NSHostingView(rootView: notchPanelView)
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
        menuBarPanel.isMovableByWindowBackground = true
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

        // Keep the panel visually consistent (floating + no title bar) in both
        // pinned and transient modes. Pinning now only controls auto-dismiss.
        panel.styleMask = [.borderless, .nonactivatingPanel, .resizable]
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applyPanelMinimumSize(to: panel)

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
        let visibleItems = menuBarItems(from: companionManager)
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

    private func menuBarItems(from companionManager: CompanionManager) -> [ClickyAgentDockItem] {
        var dockItemsBySessionID: [UUID: ClickyAgentDockItem] = [:]
        for item in companionManager.agentDockItems {
            if let sessionID = item.sessionID {
                dockItemsBySessionID[sessionID] = item
            }
        }

        let sessionItems = companionManager.codexAgentSessions
            .filter { session in
                session.hasVisibleActivity && !companionManager.archivedSessionIDs.contains(session.id)
            }
            .map { session -> ClickyAgentDockItem in
                if let existingItem = dockItemsBySessionID[session.id] {
                    return existingItem
                }

                return ClickyAgentDockItem(
                    id: session.id,
                    sessionID: session.id,
                    title: session.title,
                    userInstruction: session.title,
                    accentTheme: session.accentTheme,
                    status: Self.dockStatus(for: session.status),
                    progressStageLabel: session.progressStage.label,
                    progressStepText: session.latestActivityDisplaySummary ?? session.latestActivitySummary,
                    activityStatusLines: session.activityStatusLines,
                    caption: session.latestActivityDisplaySummary ?? session.latestActivitySummary,
                    suggestedNextActions: session.latestResponseCard?.suggestedNextActions ?? [],
                    createdAt: session.createdAt
                )
            }

        let unsessionedItems = companionManager.agentDockItems.filter { $0.sessionID == nil }
        let combinedItems = (sessionItems + unsessionedItems)
            .sorted { $0.createdAt < $1.createdAt }

        return Array(combinedItems.suffix(5))
    }

    private static func dockStatus(for status: CodexAgentSessionStatus) -> ClickyAgentDockStatus {
        switch status {
        case .starting:
            return .starting
        case .running:
            return .running
        case .ready:
            return .done
        case .stopped, .failed:
            return .failed
        }
    }

    private func makeStatusItem(for item: ClickyAgentDockItem) -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            button.target = self
            button.action = #selector(agentStatusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        return statusItem
    }

    private func update(statusItem: NSStatusItem, with item: ClickyAgentDockItem) {
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip(for: item)
        button.image = makeAgentStatusIcon(theme: item.accentTheme, status: item.status)
        button.image?.isTemplate = false
        installDropTarget(on: button, itemID: item.id)
    }

    @objc private func agentStatusItemClicked(_ sender: NSStatusBarButton) {
        guard let rawID = sender.identifier?.rawValue,
              let itemID = UUID(uuidString: rawID),
              let item = latestItemsByID[itemID] else { return }

        handleAgentStatusItemClick(item: item, from: sender, isRightClick: NSApp.currentEvent?.type == .rightMouseUp)
    }

    private func handleAgentStatusItemClick(item: ClickyAgentDockItem, from sender: NSStatusBarButton, isRightClick: Bool) {
        let itemID = item.id

        if isRightClick {
            showAgentContextMenu(for: item, from: sender)
            return
        }

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
        let rootView = ClickyAgentDockHoverCard(
            item: item,
            canOpenDashboard: companionManager.isAdvancedModeEnabled,
            chat: { [weak self, weak companionManager] in
                self?.openMenuBarAgent(item, companionManager: companionManager)
            },
            text: { [weak self, weak companionManager] in
                self?.openMenuBarAgentTextFollowUp(item, companionManager: companionManager)
            },
            voice: { [weak companionManager] in
                companionManager?.prepareVoiceFollowUpForAgentDockItem(item.id)
            },
            close: { [weak popover] in
                popover?.performClose(nil)
            },
            stop: { [weak self, weak companionManager, weak popover] in
                popover?.performClose(nil)
                self?.stopMenuBarAgent(item, companionManager: companionManager)
            },
            dismiss: { [weak self, weak companionManager, weak popover] in
                // Close == dismiss the finished item: hide the popover
                // and remove the dock entry. dismissAgentDockItem is
                // UI-only — it does NOT send a cancel signal (the agent
                // is already terminal here).
                popover?.performClose(nil)
                self?.dismissMenuBarAgent(item, companionManager: companionManager)
            },
            runSuggestedAction: { [weak companionManager, weak popover] actionTitle in
                popover?.performClose(nil)
                companionManager?.runSuggestedNextAction(actionTitle, forAgentDockItem: item.id)
            }
        )
        let controller = NSHostingController(rootView: rootView)
        controller.representedObject = itemID
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 560, height: 360)
        activePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func openMenuBarAgent(_ item: ClickyAgentDockItem, companionManager: CompanionManager?) {
        guard let companionManager else { return }
        if companionManager.agentDockItems.contains(where: { $0.id == item.id }) {
            companionManager.openAgentDockItem(item.id)
            return
        }
        if let sessionID = item.sessionID {
            companionManager.selectCodexAgentSession(sessionID)
        }
        companionManager.showCodexHUD()
    }

    private func openMenuBarAgentTextFollowUp(_ item: ClickyAgentDockItem, companionManager: CompanionManager?) {
        guard let companionManager else { return }
        if companionManager.agentDockItems.contains(where: { $0.id == item.id }) {
            companionManager.showTextFollowUpForAgentDockItem(item.id)
            return
        }
        guard let sessionID = item.sessionID else { return }
        companionManager.selectCodexAgentSession(sessionID)
        companionManager.notchCaptureWindowManager.showMainInterfacePanel(
            companionManager: companionManager,
            focusedAgentSessionID: sessionID
        )
    }

    private func stopMenuBarAgent(_ item: ClickyAgentDockItem, companionManager: CompanionManager?) {
        guard let companionManager else { return }
        if companionManager.agentDockItems.contains(where: { $0.id == item.id }) {
            companionManager.stopAgentDockItem(item.id)
            return
        }
        if let sessionID = item.sessionID {
            companionManager.stopCodexAgentSession(sessionID, reason: "agent_menu_bar_stop")
        }
    }

    private func dismissMenuBarAgent(_ item: ClickyAgentDockItem, companionManager: CompanionManager?) {
        guard let companionManager else { return }
        if companionManager.agentDockItems.contains(where: { $0.id == item.id }) {
            companionManager.dismissAgentDockItem(item.id)
        }
    }

    private func installDropTarget(on button: NSStatusBarButton, itemID: UUID) {
        let targetIdentifier = NSUserInterfaceItemIdentifier("OpenClickyAgentStatusDropTarget")
        let dropTarget: AgentStatusItemDropTargetView

        if let existing = button.subviews.first(where: { $0.identifier == targetIdentifier }) as? AgentStatusItemDropTargetView {
            dropTarget = existing
        } else {
            dropTarget = AgentStatusItemDropTargetView(frame: button.bounds)
            dropTarget.identifier = targetIdentifier
            dropTarget.autoresizingMask = [.width, .height]
            button.addSubview(dropTarget)
        }

        dropTarget.frame = button.bounds
        dropTarget.configure(
            itemID: itemID,
            companionManager: companionManager,
            clickHandler: { [weak self, weak button] itemID, isRightClick in
                guard let self,
                      let button,
                      let item = self.latestItemsByID[itemID] else { return }
                self.handleAgentStatusItemClick(item: item, from: button, isRightClick: isRightClick)
            }
        )
    }

    private func showAgentContextMenu(for item: ClickyAgentDockItem, from sender: NSStatusBarButton) {
        let menu = NSMenu()

        let quickItem = NSMenuItem(
            title: "Quick Reply",
            action: #selector(quickReplyToAgentFromMenu(_:)),
            keyEquivalent: ""
        )
        quickItem.target = self
        quickItem.representedObject = item.id
        menu.addItem(quickItem)

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(openSettingsFromAgentMenu),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(agentHistoryMenuItem())

        menu.popUp(positioning: quickItem, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func agentHistoryMenuItem() -> NSMenuItem {
        let historyItem = NSMenuItem(title: "Task History", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Task History")
        guard let companionManager else {
            let emptyItem = NSMenuItem(title: "OpenClicky is not ready", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
            historyItem.submenu = submenu
            return historyItem
        }

        let sessions = companionManager.codexAgentSessions.reversed()
        if sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No tasks yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for session in sessions {
                let item = NSMenuItem(
                    title: historyTitle(for: session),
                    action: #selector(openHistorySessionFromAgentMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                submenu.addItem(item)
            }
        }

        historyItem.submenu = submenu
        return historyItem
    }

    private func historyTitle(for session: CodexAgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "Untitled task" : title
        return "\(statusLabel(for: session.status)) · \(fallbackTitle)"
    }

    private func statusLabel(for status: CodexAgentSessionStatus) -> String {
        switch status {
        case .starting: return "Starting"
        case .running: return "Working"
        case .ready: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    @objc private func quickReplyToAgentFromMenu(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID else { return }
        if let item = latestItemsByID[itemID] {
            openMenuBarAgentTextFollowUp(item, companionManager: companionManager)
        } else {
            companionManager?.showTextFollowUpForAgentDockItem(itemID)
        }
    }

    @objc private func openSettingsFromAgentMenu() {
        companionManager?.showSettingsWindow()
    }

    @objc private func openHistorySessionFromAgentMenu(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? UUID else { return }
        companionManager?.selectCodexAgentSession(sessionID)
        companionManager?.showCodexHUD()
    }

    private func tooltip(for item: ClickyAgentDockItem) -> String {
        let status: String
        switch item.status {
        case .starting: status = "Starting"
        case .running: status = "Working"
        case .done: status = "Done"
        case .failed: status = "Stopped"
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
        case .white: return NSColor(calibratedWhite: 0.97, alpha: 1)
        case .cyan:
            return NSColor(calibratedWhite: 0.97, alpha: 1)
        case .lime:
            return NSColor(calibratedWhite: 0.97, alpha: 1)
        case .orange:
            return NSColor(calibratedWhite: 0.97, alpha: 1)
        case .violet:
            return NSColor(calibratedWhite: 0.97, alpha: 1)
        }
    }
}

private final class AgentStatusItemDropTargetView: NSView {
    private var itemID: UUID?
    private weak var companionManager: CompanionManager?
    private var clickHandler: ((UUID, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL])
    }

    func configure(
        itemID: UUID,
        companionManager: CompanionManager?,
        clickHandler: @escaping (UUID, Bool) -> Void
    ) {
        self.itemID = itemID
        self.companionManager = companionManager
        self.clickHandler = clickHandler
    }

    override func mouseUp(with event: NSEvent) {
        guard let itemID else { return }
        clickHandler?(itemID, false)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let itemID else { return }
        clickHandler?(itemID, true)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let itemID else { return false }
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        companionManager?.attachDroppedAgentFiles(urls, toAgentDockItem: itemID, source: "agent_menu_avatar_drop")
        return true
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map(\.standardizedFileURL)
        }

        let filenames = pasteboard.propertyList(forType: .fileURL) as? [String] ?? []
        return filenames.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}
