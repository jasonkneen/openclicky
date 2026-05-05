//
//  WindowPositionManager.swift
//  leanring-buddy
//
//  Manages positioning the app window on the right edge of the screen
//  and shrinking overlapping windows from other apps via the Accessibility API.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

enum PermissionRequestPresentationDestination: Equatable {
    case alreadyGranted
    case systemPrompt
    case systemSettings
}

@MainActor
class WindowPositionManager {
    static let permissionDragAssistantMessage = "I'm OpenClicky - drag me into the list above."

    private static var hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch = false
    private static var hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch = false
    private static let hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"

    /// Returns true when the Mac currently has more than one connected display.
    /// Uses AppKit's screen list, which is available without ScreenCaptureKit's
    /// shareable-content permission prompt.
    static func currentMacHasMultipleDisplays() -> Bool {
        NSScreen.screens.count > 1
    }

    // MARK: - Accessibility Permission

    /// Returns true if the app has Accessibility permission.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Presents exactly one permission path per tap: the system prompt on the first
    /// attempt, then System Settings on later attempts after macOS has already shown
    /// its one-time alert.
    @discardableResult
    static func requestAccessibilityPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasAccessibilityPermission(),
            hasAttemptedSystemPrompt: hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch = true
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .systemSettings:
            openAccessibilitySettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Accessibility pane.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveals the running app bundle in Finder so the user can drag it into
    /// the Accessibility list if it doesn't appear automatically.
    static func revealAppInFinder() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    static func showPermissionDragAssistant(message: String) {
        PermissionDragAssistantWindowManager.shared.show(message: message)
    }

    static func guideAccessibilityPermissionWithDragAssistant() {
        let presentationDestination = requestAccessibilityPermission()
        guard presentationDestination != .alreadyGranted else { return }

        openAccessibilitySettings()
        showPermissionDragAssistant(message: permissionDragAssistantMessage)
    }

    static func guideScreenRecordingPermissionWithDragAssistant() {
        let presentationDestination = requestScreenRecordingPermission()
        guard presentationDestination != .alreadyGranted else { return }

        openScreenRecordingSettings()
        showPermissionDragAssistant(message: permissionDragAssistantMessage)
    }

    static func showAppInPermissionsListDragAssistant(settingsURL: URL) {
        revealAppInFinder()
        NSWorkspace.shared.open(settingsURL)
        showPermissionDragAssistant(message: permissionDragAssistantMessage)
    }

    // MARK: - Screen Recording Permission

    /// Returns true if Screen Recording permission is granted.
    static func hasScreenRecordingPermission() -> Bool {
        let hasScreenRecordingPermissionNow = CGPreflightScreenCaptureAccess()
        if hasScreenRecordingPermissionNow {
            UserDefaults.standard.set(true, forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
        }
        return hasScreenRecordingPermissionNow
    }

    /// Returns true when the app should proceed with session launch without showing
    /// the permission gate again. This intentionally falls back to the last known
    /// granted state because CGPreflightScreenCaptureAccess() can sometimes return a
    /// false negative even though the user has already approved the app.
    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() -> Bool {
        shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: hasScreenRecordingPermission(),
            hasPreviouslyConfirmedScreenRecordingPermission: UserDefaults.standard.bool(forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
        )
    }

    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
        hasScreenRecordingPermissionNow: Bool,
        hasPreviouslyConfirmedScreenRecordingPermission: Bool
    ) -> Bool {
        hasScreenRecordingPermissionNow || hasPreviouslyConfirmedScreenRecordingPermission
    }

    static func clearPreviouslyConfirmedScreenRecordingPermission() {
        UserDefaults.standard.removeObject(forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
    }

    /// Prompts the system dialog for Screen Recording permission.
    /// Uses the system prompt once, then opens System Settings on later attempts so
    /// the user never gets the prompt and the Settings pane at the same time.
    @discardableResult
    static func requestScreenRecordingPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasScreenRecordingPermission(),
            hasAttemptedSystemPrompt: hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch = true
            _ = CGRequestScreenCaptureAccess()
        case .systemSettings:
            openScreenRecordingSettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Screen Recording pane.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    static func permissionRequestPresentationDestination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool
    ) -> PermissionRequestPresentationDestination {
        if hasPermissionNow {
            return .alreadyGranted
        }

        if hasAttemptedSystemPrompt {
            return .systemSettings
        }

        return .systemPrompt
    }

    // MARK: - Window Positioning

    /// Positions the app's main window pinned to the right edge of the screen
    /// that contains the given display ID, vertically centered.
    static func pinMainWindowToRight(onDisplayID displayID: CGDirectDisplayID?) {
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }

        // Find the NSScreen matching the selected display, or fall back to the screen
        // the window is currently on, or finally the main screen.
        let targetScreen: NSScreen
        if let displayID,
           let matchingScreen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            targetScreen = matchingScreen
        } else if let currentScreen = mainWindow.screen {
            targetScreen = currentScreen
        } else if let mainScreen = NSScreen.main {
            targetScreen = mainScreen
        } else {
            return
        }

        let visibleFrame = targetScreen.visibleFrame
        let windowSize = mainWindow.frame.size

        let x = visibleFrame.maxX - windowSize.width
        let y = visibleFrame.minY + (visibleFrame.height - windowSize.height) / 2.0

        mainWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Shrink Overlapping Windows

    /// Checks if the frontmost (non-self) app's focused window overlaps our app window
    /// on the same monitor and, if so, shrinks it so it no longer overlaps.
    /// Only operates if both windows are on the same screen as `targetDisplayID`.
    static func shrinkOverlappingFocusedWindow(targetDisplayID: CGDirectDisplayID?) {
        guard hasAccessibilityPermission() else { return }
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        guard let mainScreen = mainWindow.screen else { return }

        // Only operate if the main window is on the target display
        if let targetDisplayID, mainScreen.displayID != targetDisplayID {
            return
        }

        // Get the frontmost application that isn't us
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get the focused window of the front app.
        //
        // AX APIs return `CFTypeRef` whose actual type depends on the
        // attribute. We must NOT force-cast — a sandboxed/unexpected
        // process can return a different CF type and crash the host. Use
        // CFGetTypeID guards so a mismatch becomes a silent early return.
        var focusedWindowValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard focusedResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return
        }
        let focusedWindow = focusedWindowValue as! AXUIElement // safe: TypeID checked above

        // Get position and size of the focused window
        var positionValueRef: CFTypeRef?
        var sizeValueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValueRef) == .success,
              AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeValueRef) == .success,
              let positionValueRef,
              let sizeValueRef,
              CFGetTypeID(positionValueRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeValueRef) == AXValueGetTypeID() else {
            return
        }
        let positionValue = positionValueRef as! AXValue // safe: TypeID checked above
        let sizeValue = sizeValueRef as! AXValue         // safe: TypeID checked above

        var otherPosition = CGPoint.zero
        var otherSize = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &otherPosition),
              AXValueGetValue(sizeValue, .cgSize, &otherSize) else {
            return
        }

        // The other window's frame in screen coordinates (top-left origin from AX API).
        // Convert to check if it's on the same screen as our window.
        let otherRight = otherPosition.x + otherSize.width
        let ourLeft = mainWindow.frame.origin.x

        // Check that the other window is on the same screen by verifying its origin
        // falls within the target screen's bounds.
        let screenFrame = mainScreen.frame
        let otherCenterX = otherPosition.x + otherSize.width / 2
        // AX uses top-left origin, NSScreen uses bottom-left. Convert AX Y to NSScreen Y.
        let otherNSScreenY = screenFrame.maxY - otherPosition.y - otherSize.height
        let otherCenterY = otherNSScreenY + otherSize.height / 2
        let otherCenter = NSPoint(x: otherCenterX, y: otherCenterY)

        guard screenFrame.contains(otherCenter) else { return }

        // If the other window's right edge extends past our window's left edge, shrink it.
        if otherRight > ourLeft {
            let newWidth = ourLeft - otherPosition.x
            guard newWidth > 200 else { return } // Don't shrink too small

            var newSize = CGSize(width: newWidth, height: otherSize.height)
            guard let newSizeValue = AXValueCreate(.cgSize, &newSize) else { return }
            AXUIElementSetAttributeValue(focusedWindow, kAXSizeAttribute as CFString, newSizeValue)
        }
    }
}

private final class PermissionDragAssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PermissionDragAssistantWindowManager {
    static let shared = PermissionDragAssistantWindowManager()

    private var panel: NSPanel?
    private let panelSize = NSSize(width: 360, height: 118)

    func show(message: String) {
        if panel == nil {
            createPanel(message: message)
        } else if let hostingView = panel?.contentView as? NSHostingView<PermissionDragAssistantView> {
            hostingView.rootView = PermissionDragAssistantView(message: message)
        }

        positionPanel()
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    private func createPanel(message: String) {
        let assistantPanel = PermissionDragAssistantPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        assistantPanel.isFloatingPanel = true
        assistantPanel.level = .screenSaver
        assistantPanel.isOpaque = false
        assistantPanel.backgroundColor = .clear
        assistantPanel.hasShadow = false
        assistantPanel.hidesOnDeactivate = false
        assistantPanel.isReleasedWhenClosed = false
        assistantPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: PermissionDragAssistantView(message: message))
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        assistantPanel.contentView = hostingView

        panel = assistantPanel
    }

    private func positionPanel() {
        guard let panel else { return }
        let targetScreen = NSScreen.screen(containingOrNearestTo: NSEvent.mouseLocation)
        guard let targetScreen else { return }

        let visibleFrame = targetScreen.visibleFrame

        // Position on the left side of the screen near mid-height.
        // System Settings > Security & Privacy shows the app permissions list
        // on the left side of the window, so placing the drag assistant here
        // minimizes the distance the user has to drag the app icon.
        let leftMargin: CGFloat = 40
        let x = visibleFrame.minX + leftMargin
        let y = visibleFrame.midY - panelSize.height / 2

        panel.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: true)
    }
}

private struct PermissionDragAssistantView: View {
    let message: String

    private var appURL: URL {
        Bundle.main.bundleURL
    }

    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: appURL.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(DS.Colors.accentSubtle)
                    )

                Text(message)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()
            }

            HStack(spacing: 9) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: DS.Colors.accentText.opacity(0.32), radius: 5, x: 0, y: 0)

                Text("OpenClicky")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.9), lineWidth: 0.6)
            )
            .onDrag {
                NSItemProvider(object: appURL as NSURL)
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.background.opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.85), lineWidth: 0.6)
        )
        .shadow(color: DS.Colors.accentText.opacity(0.18), radius: 13, x: 0, y: 5)
        .shadow(color: Color.black.opacity(0.45), radius: 9, x: 0, y: 4)
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// The CGDirectDisplayID for this screen.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }

    /// Returns the screen containing `point`, or the nearest screen when the
    /// point lands exactly on a display edge or outside the current desktop.
    static func screen(containingOrNearestTo point: CGPoint) -> NSScreen? {
        if let containingScreen = screens.first(where: { $0.frame.contains(point) }) {
            return containingScreen
        }

        return screens.min { lhs, rhs in
            distanceSquared(from: point, to: lhs.frame) < distanceSquared(from: point, to: rhs.frame)
        } ?? main ?? screens.first
    }

    static var desktopUnionFrame: CGRect? {
        let unionFrame = screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        return unionFrame.isNull ? nil : unionFrame
    }

    static func pointClampedToDesktop(_ point: CGPoint) -> CGPoint {
        guard let unionFrame = desktopUnionFrame else { return point }
        return CGPoint(
            x: min(max(point.x, unionFrame.minX), unionFrame.maxX - 1),
            y: min(max(point.y, unionFrame.minY), unionFrame.maxY - 1)
        )
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}
