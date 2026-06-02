//
//  CompanionScreenCaptureUtility.swift
//  cursor-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let appName: String?
    let bundleIdentifier: String?
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayNativeWidthInPixels: Int?
    let displayNativeHeightInPixels: Int?
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Cached SCShareableContent. Fetching it cold takes 80–200ms because
    /// ScreenCaptureKit enumerates every window on every display. Reusing
    /// it for ~3 seconds lets push-to-talk → screenshot stay under the
    /// audio-engine warmup budget. Refreshed on every miss.
    private static var cachedShareableContent: SCShareableContent?
    private static var cachedShareableContentExpiresAt: Date?
    private static let shareableContentCacheLifetime: TimeInterval = 3.0

    private static func currentShareableContent() async throws -> SCShareableContent {
        if let cached = cachedShareableContent,
           let expiresAt = cachedShareableContentExpiresAt,
           expiresAt > Date() {
            return cached
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedShareableContent = content
        cachedShareableContentExpiresAt = Date().addingTimeInterval(shareableContentCacheLifetime)
        return content
    }

    /// Pre-fetches SCShareableContent so the first capture after key-down
    /// skips the cold enumeration. Safe to call repeatedly — it just
    /// refreshes the cache.
    static func prewarmShareableContent() {
        Task { @MainActor in
            _ = try? await currentShareableContent()
        }
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        try await captureScreensAsJPEG(cursorScreenOnly: false)
    }

    /// Captures only the display that currently contains the cursor. Agent
    /// Mode uses this for default screen context so a multi-monitor setup
    /// doesn't leak unrelated screens into the background-agent prompt.
    static func captureCursorScreenAsJPEG() async throws -> [CompanionScreenCapture] {
        try await captureScreensAsJPEG(cursorScreenOnly: true)
    }

    private static func captureScreensAsJPEG(cursorScreenOnly: Bool) async throws -> [CompanionScreenCapture] {
        let content = try await currentShareableContent()

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        recordEncounteredApplications(
            from: content.windows,
            excludingBundleIdentifier: ownBundleIdentifier,
            source: cursorScreenOnly ? "cursor_screen_capture" : "all_screens_capture"
        )
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }
        let frontmostApp = NSWorkspace.shared.frontmostApplication

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        let displaysToCapture: [SCDisplay]
        if cursorScreenOnly, let cursorDisplay = sortedDisplays.first(where: { display in
            let frame = nsScreenByDisplayID[display.displayID]?.frame ?? display.frame
            return frame.contains(mouseLocation)
        }) {
            displaysToCapture = [cursorDisplay]
        } else {
            displaysToCapture = sortedDisplays
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in displaysToCapture.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let nsScreen = nsScreenByDisplayID[display.displayID]
            let displayFrame = nsScreen?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let backingScaleFactor = nsScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if cursorScreenOnly {
                screenLabel = "cursor screen (primary focus)"
            } else if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                appName: frontmostApp?.localizedName,
                bundleIdentifier: frontmostApp?.bundleIdentifier,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayNativeWidthInPixels: Int((displayFrame.width * backingScaleFactor).rounded()),
                displayNativeHeightInPixels: Int((displayFrame.height * backingScaleFactor).rounded()),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// Captures only the frontmost window of the active app. Used by Tutor Mode
    /// so proactive guidance focuses on the user's current task instead of
    /// unrelated desktop clutter. Falls back to full-screen capture when no
    /// suitable focused window is available.
    static func captureFocusedWindowAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await currentShareableContent()

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        guard let targetWindow = content.windows.first(where: { window in
            guard let appBundleID = window.owningApplication?.bundleIdentifier else { return false }
            guard appBundleID != ownBundleIdentifier else { return false }
            guard appBundleID == frontmostApp?.bundleIdentifier else { return false }
            return window.isOnScreen && window.frame.width > 100 && window.frame.height > 100
        }) else {
            return try await captureAllScreensAsJPEG()
        }
        recordEncounteredApplication(from: targetWindow, source: "focused_window_capture")

        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let windowWidth = max(1, Int(targetWindow.frame.width))
        let windowHeight = max(1, Int(targetWindow.frame.height))
        let aspectRatio = CGFloat(windowWidth) / CGFloat(windowHeight)
        if windowWidth >= windowHeight {
            configuration.width = maxDimension
            configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
        }

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode focused window JPEG"])
        }

        let appName = frontmostApp?.localizedName ?? "unknown app"
        let windowTitle = targetWindow.title ?? ""
        let windowLabel = windowTitle.isEmpty
            ? "focused window (\(appName))"
            : "focused window (\(appName) - \(windowTitle))"
        let windowFrameInAppKit = appKitFrame(for: targetWindow, displays: content.displays)
        let mouseLocation = NSEvent.mouseLocation

        return [CompanionScreenCapture(
            imageData: jpegData,
            label: windowLabel,
            appName: appName,
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            isCursorScreen: windowFrameInAppKit.contains(mouseLocation),
            displayWidthInPoints: windowWidth,
            displayHeightInPoints: windowHeight,
            displayNativeWidthInPixels: nil,
            displayNativeHeightInPixels: nil,
            displayFrame: windowFrameInAppKit,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )]
    }

    private static func recordEncounteredApplications(
        from windows: [SCWindow],
        excludingBundleIdentifier ownBundleIdentifier: String?,
        source: String
    ) {
        var seen = Set<String>()
        for window in windows {
            guard window.isOnScreen,
                  window.frame.width > 100,
                  window.frame.height > 80,
                  let app = window.owningApplication else {
                continue
            }
            let bundleIdentifier = app.bundleIdentifier
            guard bundleIdentifier != ownBundleIdentifier else { continue }
            let key = bundleIdentifier.isEmpty ? app.applicationName : bundleIdentifier
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            OpenClickyApplicationUsageLogStore.shared.recordApplication(
                name: app.applicationName,
                bundleIdentifier: bundleIdentifier,
                source: source
            )
        }
    }

    private static func recordEncounteredApplication(from window: SCWindow, source: String) {
        guard let app = window.owningApplication else { return }
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: app.applicationName,
            bundleIdentifier: app.bundleIdentifier,
            source: source
        )
    }

    private static func appKitFrame(for window: SCWindow, displays: [SCDisplay]) -> CGRect {
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        if let display = displays.first(where: { $0.frame.contains(windowCenter) }),
           let screen = nsScreenByDisplayID[display.displayID] {
            let localX = window.frame.origin.x - display.frame.origin.x
            let localYFromTop = window.frame.origin.y - display.frame.origin.y
            return CGRect(
                x: screen.frame.origin.x + localX,
                y: screen.frame.maxY - localYFromTop - window.frame.height,
                width: window.frame.width,
                height: window.frame.height
            )
        }

        let screen = NSScreen.screens.first ?? NSScreen.main
        let screenHeight = screen?.frame.height ?? window.frame.height
        return CGRect(
            x: window.frame.origin.x,
            y: screenHeight - window.frame.origin.y - window.frame.height,
            width: window.frame.width,
            height: window.frame.height
        )
    }
}
