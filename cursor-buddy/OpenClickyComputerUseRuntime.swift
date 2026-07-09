import AppKit
import ApplicationServices
import Carbon
import Combine
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC
import ScreenCaptureKit

/// Native CUA-style computer use embedded in OpenClicky.
///
/// CUA source reference: /Users/jkneen/Documents/GitHub/cua/libs/cua-driver
/// License: MIT, Copyright (c) 2025 Cua AI, Inc.
///
/// OpenClicky intentionally embeds the narrow, app-owned subset needed for
/// product runtime: app/window discovery, target-window capture, permission
/// readiness, and pid-directed keyboard input. Full MCP/trajectory/daemon
/// features stay out of the app bundle for now.
@MainActor
final class OpenClickyNativeComputerUseController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: OpenClickyComputerUseStatus
    @Published private(set) var lastWindowCapture: OpenClickyComputerUseWindowCapture?

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        let initialEnabled = userDefaults.bool(forKey: AppBundleConfiguration.userNativeComputerUseDefaultsKey)
        let initialStatus = OpenClickyNativeComputerUseController.makeStatus(
            enabled: initialEnabled,
            lastErrorMessage: nil
        )

        self.userDefaults = userDefaults
        self.isEnabled = initialEnabled
        self.status = initialStatus
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: AppBundleConfiguration.userNativeComputerUseDefaultsKey)
        refreshStatus()
    }

    func refreshStatus() {
        status = Self.makeStatus(enabled: isEnabled, lastErrorMessage: nil)
    }

    @discardableResult
    func refreshFocusedTarget() -> OpenClickyComputerUseWindowInfo? {
        let focusedWindow = OpenClickyComputerUseWindowEnumerator.frontmostTargetWindow()
        status = Self.makeStatus(
            enabled: isEnabled,
            focusedWindow: focusedWindow,
            lastErrorMessage: focusedWindow == nil ? OpenClickyComputerUseError.noTargetWindow.localizedDescription : nil
        )
        return focusedWindow
    }

    func runningApps() -> [OpenClickyComputerUseAppInfo] {
        OpenClickyComputerUseAppEnumerator.apps()
    }

    func visibleWindows() -> [OpenClickyComputerUseWindowInfo] {
        OpenClickyComputerUseWindowEnumerator.visibleWindows()
    }

    func allWindows() -> [OpenClickyComputerUseWindowInfo] {
        OpenClickyComputerUseWindowEnumerator.allWindows()
    }

    func captureFocusedWindowAsJPEG() async throws -> OpenClickyComputerUseWindowCapture {
        guard isEnabled else { throw OpenClickyComputerUseError.disabled }
        guard let targetWindow = refreshFocusedTarget() else { throw OpenClickyComputerUseError.noTargetWindow }

        do {
            let capture = try await OpenClickyComputerUseWindowCaptureUtility.capture(window: targetWindow)
            lastWindowCapture = capture
            status = Self.makeStatus(enabled: true, focusedWindow: targetWindow, lastErrorMessage: nil)
            return capture
        } catch let error as OpenClickyComputerUseError {
            status = Self.makeStatus(enabled: true, focusedWindow: targetWindow, lastErrorMessage: error.localizedDescription)
            throw error
        } catch {
            status = Self.makeStatus(enabled: true, focusedWindow: targetWindow, lastErrorMessage: error.localizedDescription)
            throw error
        }
    }

    func pressKey(_ key: String, modifiers: [String] = [], toPid pid: pid_t? = nil) throws {
        guard isEnabled else { throw OpenClickyComputerUseError.disabled }
        OpenClickyApplicationUsageLogStore.shared.recordFrontmostApplication(source: "native_cua_key_press")
        try OpenClickyComputerUseKeyboardInput.press(key, modifiers: modifiers, toPid: pid)
    }

    func typeText(_ text: String, delayMilliseconds: Int = 30, toPid pid: pid_t? = nil) throws {
        guard isEnabled else { throw OpenClickyComputerUseError.disabled }
        OpenClickyApplicationUsageLogStore.shared.recordFrontmostApplication(source: "native_cua_text_input")
        try OpenClickyComputerUseKeyboardInput.typeCharacters(text, delayMilliseconds: delayMilliseconds, toPid: pid)
    }

    func click(at point: CGPoint) throws {
        guard isEnabled else { throw OpenClickyComputerUseError.disabled }
        OpenClickyApplicationUsageLogStore.shared.recordFrontmostApplication(source: "native_cua_click")
        try OpenClickyComputerUseMouseInput.leftClick(at: point)
    }

    private static func makeStatus(
        enabled: Bool,
        focusedWindow: OpenClickyComputerUseWindowInfo? = nil,
        lastErrorMessage: String? = nil
    ) -> OpenClickyComputerUseStatus {
        let apps = OpenClickyComputerUseAppEnumerator.apps()
        let windows = OpenClickyComputerUseWindowEnumerator.visibleWindows()
        let resolvedFocusedWindow = focusedWindow ?? OpenClickyComputerUseWindowEnumerator.frontmostTargetWindow(from: windows)

        return OpenClickyComputerUseStatus(
            enabled: enabled,
            permissions: OpenClickyComputerUsePermissionProbe.status(),
            runningAppCount: apps.filter(\.running).count,
            visibleWindowCount: windows.count,
            focusedWindow: resolvedFocusedWindow,
            lastErrorMessage: lastErrorMessage
        )
    }
}

@MainActor
final class OpenClickyBackgroundComputerUseController: ObservableObject {
    @Published private(set) var status: OpenClickyBackgroundComputerUseStatus

    private let fileManager: FileManager
    private let sourceRootURL: URL
    private let installedAppURL: URL
    private let manifestURL: URL

    /// The bundled helper exposes privileged Accessibility actions over an
    /// unauthenticated localhost server. Its source is not included in this
    /// checkout, so the Swift client cannot make that server safe by adding a
    /// request header. Do not launch or use it until the helper is rebuilt with
    /// server-side authentication (or a peer-authenticated Unix socket).
    nonisolated private static let unsafeRuntimeMessage = "Background Computer Use is disabled because the bundled helper does not authenticate its privileged local control server. Install a rebuilt authenticated helper before enabling this backend."

    nonisolated private static let developmentSourceRootURL = URL(
        fileURLWithPath: "/Users/jkneen/Documents/GitHub/background-computer-use",
        isDirectory: true
    )

    nonisolated private static func bundledRuntimeRootURL() -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("BackgroundComputerUseRuntime", isDirectory: true)
    }

    nonisolated private static func bundledAppURL(in runtimeRootURL: URL) -> URL {
        runtimeRootURL.appendingPathComponent("BackgroundComputerUse.app", isDirectory: true)
    }

    nonisolated private static func installedAppURL(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("BackgroundComputerUse.app", isDirectory: true)
    }

    init(
        sourceRootURL requestedSourceRootURL: URL = OpenClickyBackgroundComputerUseController.developmentSourceRootURL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager

        let bundledRuntimeRootURL = Self.bundledRuntimeRootURL()
        let bundledAppURL = bundledRuntimeRootURL.map(Self.bundledAppURL(in:))
        let shouldUseBundledRuntime = bundledAppURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        let resolvedSourceRootURL = shouldUseBundledRuntime
            ? bundledRuntimeRootURL ?? requestedSourceRootURL
            : requestedSourceRootURL

        self.sourceRootURL = resolvedSourceRootURL
        self.installedAppURL = shouldUseBundledRuntime
            ? bundledAppURL ?? Self.installedAppURL(fileManager: fileManager)
            : Self.installedAppURL(fileManager: fileManager)
        self.manifestURL = fileManager.temporaryDirectory
            .appendingPathComponent("background-computer-use", isDirectory: true)
            .appendingPathComponent("runtime-manifest.json", isDirectory: false)
        self.status = Self.makeStatus(
            sourceRootURL: sourceRootURL,
            installedAppURL: installedAppURL,
            manifestURL: manifestURL,
            fileManager: fileManager,
            isStarting: false,
            lastErrorMessage: nil
        )
    }

    func refreshStatus() {
        status = Self.makeStatus(
            sourceRootURL: sourceRootURL,
            installedAppURL: installedAppURL,
            manifestURL: manifestURL,
            fileManager: fileManager,
            isStarting: status.isStarting,
            lastErrorMessage: nil
        )
    }

    /// M11: tear down the spawned Background Computer Use helper. Previously
    /// nothing stopped it — startRuntime spawns via /usr/bin/open and forgets the
    /// PID, so this terminates any running instance of the bundled app by bundle
    /// id. Best-effort; logs failures. Also flips the status to not-ready.
    func stopRuntime() {
        let bundleID = "xyz.dubdub.backgroundcomputeruse"
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for app in apps {
            app.terminate()
        }
        // Clear the legacy discoverable manifest as part of shutting down an
        // older helper. It is not trusted as an authority for future launches.
        try? fileManager.removeItem(at: manifestURL)
        status = Self.makeStatus(
            sourceRootURL: sourceRootURL,
            installedAppURL: installedAppURL,
            manifestURL: manifestURL,
            fileManager: fileManager,
            isStarting: false,
            lastErrorMessage: nil
        )
    }

    func startRuntime() {
        // A client-side bearer token is not a security boundary when the
        // server ignores it. Explicitly stop any legacy process instead of
        // spawning a new unauthenticated Accessibility service.
        stopRuntime()
    }

    func ensureRuntimeReady(timeoutSeconds: TimeInterval = 10) async throws {
        _ = timeoutSeconds // Preserves the public signature while disabled.
        refreshStatus()
        throw OpenClickyBackgroundComputerUseError.runtimeUnavailable(Self.unsafeRuntimeMessage)
    }

    func captureFrontmostWindowAsJPEG() async throws -> OpenClickyBackgroundComputerUseWindowCapture {
        try await ensureRuntimeReady()
        let target = try await resolveTargetWindow(appName: nil)
        let state = try await requestWindowState(windowID: target.windowID, imageMode: "path")

        guard let image = state.screenshot.image else {
            throw OpenClickyBackgroundComputerUseError.screenshotUnavailable(state.screenshot.captureError ?? "No screenshot image returned.")
        }

        let imageData: Data
        if let imageBase64 = image.imageBase64,
           let decoded = Data(base64Encoded: imageBase64) {
            imageData = decoded
        } else if let imagePath = image.imagePath {
            imageData = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        } else {
            throw OpenClickyBackgroundComputerUseError.screenshotUnavailable("No screenshot path or base64 image returned.")
        }

        return OpenClickyBackgroundComputerUseWindowCapture(
            imageData: imageData,
            windowID: state.window.windowID,
            title: state.window.title,
            bundleID: state.window.bundleID,
            pid: state.window.pid,
            baseURL: try await runtimeBaseURL().absoluteString,
            stateToken: state.stateToken,
            imagePath: image.imagePath,
            screenshotWidthInPixels: image.pixelWidth,
            screenshotHeightInPixels: image.pixelHeight
        )
    }

    func pressKey(_ key: String, modifiers: [String] = [], targetAppName: String? = nil, stateToken: String? = nil) async throws -> OpenClickyBackgroundComputerUseActionResult {
        try await ensureRuntimeReady()
        let target = try await resolveTargetWindow(appName: targetAppName)
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: targetAppName,
            bundleIdentifier: target.bundleID,
            source: "background_computer_use_key_press"
        )
        let normalizedKey = Self.backgroundPressKeyToken(for: key)
        let chord = (modifiers + [normalizedKey]).filter { !$0.isEmpty }.joined(separator: "+")
        let request = OpenClickyBackgroundComputerUsePressKeyRequest(
            window: target.windowID,
            key: chord,
            cursor: OpenClickyBackgroundComputerUseCursorRequest(
                id: "openclicky-main",
                name: "OpenClicky",
                color: "#38BDF8"
            ),
            imageMode: "omit",
            debug: true,
            stateToken: stateToken
        )
        let response: OpenClickyBackgroundComputerUseActionResponse = try await postJSON(
            path: "/v1/press_key",
            payload: request
        )
        try ensureActionSucceeded(response, route: "press_key")
        return OpenClickyBackgroundComputerUseActionResult(
            windowID: target.windowID,
            summary: response.summary,
            ok: response.ok
        )
    }

    private static func backgroundPressKeyToken(for key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "enter":
            return "return"
        default:
            return trimmed
        }
    }

    func typeText(_ text: String, targetAppName: String? = nil, stateToken: String? = nil) async throws -> OpenClickyBackgroundComputerUseActionResult {
        try await ensureRuntimeReady()
        let target = try await resolveTargetWindow(appName: targetAppName)
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: targetAppName,
            bundleIdentifier: target.bundleID,
            source: "background_computer_use_text_input"
        )
        let request = OpenClickyBackgroundComputerUseTypeTextRequest(
            window: target.windowID,
            text: text,
            focusAssistMode: "focus_and_caret_end",
            cursor: OpenClickyBackgroundComputerUseCursorRequest(
                id: "openclicky-main",
                name: "OpenClicky",
                color: "#38BDF8"
            ),
            imageMode: "omit",
            debug: true,
            stateToken: stateToken
        )
        let response: OpenClickyBackgroundComputerUseActionResponse = try await postJSON(
            path: "/v1/type_text",
            payload: request
        )
        try ensureActionSucceeded(response, route: "type_text")
        return OpenClickyBackgroundComputerUseActionResult(
            windowID: target.windowID,
            summary: response.summary,
            ok: response.ok
        )
    }

    /// Clicks at a window-screenshot pixel coordinate via the background
    /// runtime. BCU's /v1/click "x,y" form is in the same screenshot space
    /// returned by get_window_state / captureFrontmostWindowAsJPEG — NOT
    /// global display points — so callers must point against the BCU window
    /// screenshot and pass the raw screenshot coordinate here.
    func click(at point: CGPoint, window: String, targetAppName: String? = nil, stateToken: String? = nil) async throws -> OpenClickyBackgroundComputerUseActionResult {
        try await ensureRuntimeReady()
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: targetAppName,
            bundleIdentifier: nil,
            source: "background_computer_use_click"
        )
        let request = OpenClickyBackgroundComputerUseClickRequest(
            window: window,
            x: Double(point.x),
            y: Double(point.y),
            clickCount: 1,
            cursor: OpenClickyBackgroundComputerUseCursorRequest(
                id: "openclicky-main",
                name: "OpenClicky",
                color: "#38BDF8"
            ),
            imageMode: "omit",
            debug: true,
            stateToken: stateToken
        )
        let response: OpenClickyBackgroundComputerUseActionResponse = try await postJSON(
            path: "/v1/click",
            payload: request
        )
        try ensureActionSucceeded(response, route: "click")
        return OpenClickyBackgroundComputerUseActionResult(
            windowID: window,
            summary: response.summary,
            ok: response.ok
        )
    }

    private func ensureActionSucceeded(_ response: OpenClickyBackgroundComputerUseActionResponse, route: String) throws {
        guard response.ok else {
            throw OpenClickyBackgroundComputerUseError.actionFailed(route: route, summary: response.summary)
        }
    }

    private func resolveTargetWindow(appName: String?) async throws -> OpenClickyBackgroundComputerUseWindow {
        let resolvedAppName: String
        if let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedAppName = appName
        } else if let nativeTarget = OpenClickyComputerUseWindowEnumerator.frontmostTargetWindow(),
                  !nativeTarget.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedAppName = nativeTarget.owner
        } else {
            let response: OpenClickyBackgroundComputerUseListAppsResponse = try await postJSON(
                path: "/v1/list_apps",
                payload: OpenClickyBackgroundComputerUseEmptyRequest()
            )
            guard let frontmost = response.frontmostApp else {
                throw OpenClickyBackgroundComputerUseError.noFrontmostApp
            }
            resolvedAppName = frontmost.name
        }

        let windowsResponse: OpenClickyBackgroundComputerUseListWindowsResponse = try await postJSON(
            path: "/v1/list_windows",
            payload: OpenClickyBackgroundComputerUseListWindowsRequest(app: resolvedAppName)
        )
        guard let window = windowsResponse.windows.first(where: { $0.isFocused && !$0.isMinimized && $0.isOnScreen })
            ?? windowsResponse.windows.first(where: { $0.isMain && !$0.isMinimized && $0.isOnScreen })
            ?? windowsResponse.windows.first(where: { !$0.isMinimized && $0.isOnScreen })
            ?? windowsResponse.windows.first else {
            throw OpenClickyBackgroundComputerUseError.noWindow(appName: resolvedAppName)
        }

        return window
    }

    private func requestWindowState(windowID: String, imageMode: String) async throws -> OpenClickyBackgroundComputerUseWindowStateResponse {
        try await postJSON(
            path: "/v1/get_window_state",
            payload: OpenClickyBackgroundComputerUseWindowStateRequest(
                window: windowID,
                maxNodes: 6500,
                imageMode: imageMode,
                includeRawScreenshot: false,
                debug: false
            )
        )
    }

    private func runtimeBaseURL() async throws -> URL {
        try await ensureRuntimeReady()
        guard let baseURLString = status.baseURL,
              let baseURL = URL(string: baseURLString) else {
            throw OpenClickyBackgroundComputerUseError.runtimeUnavailable(status.summary)
        }

        return baseURL
    }


    private func postJSON<Request: Encodable, Response: Decodable>(
        path: String,
        payload: Request
    ) async throws -> Response {
        let baseURL = try await runtimeBaseURL()
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: relativePath, relativeTo: baseURL)?.absoluteURL else {
            throw OpenClickyBackgroundComputerUseError.runtimeUnavailable("Invalid runtime path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw OpenClickyBackgroundComputerUseError.httpError(statusCode: httpResponse.statusCode, message: message)
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            status = Self.makeStatus(
                sourceRootURL: sourceRootURL,
                installedAppURL: installedAppURL,
                manifestURL: manifestURL,
                fileManager: fileManager,
                isStarting: false,
                lastErrorMessage: error.localizedDescription
            )
            throw error
        }
    }

    private static func makeStatus(
        sourceRootURL: URL,
        installedAppURL: URL,
        manifestURL: URL,
        fileManager: FileManager,
        isStarting: Bool,
        lastErrorMessage: String?
    ) -> OpenClickyBackgroundComputerUseStatus {
        let sourceAvailable = fileManager.fileExists(atPath: sourceRootURL.path)
        let startScriptURL = sourceRootURL
            .appendingPathComponent("script", isDirectory: true)
            .appendingPathComponent("start.sh", isDirectory: false)
        let bundledAppURL = Self.bundledAppURL(in: sourceRootURL)
        let startScriptAvailable = fileManager.fileExists(atPath: startScriptURL.path)
            || fileManager.fileExists(atPath: bundledAppURL.path)
        let installedAppAvailable = fileManager.fileExists(atPath: installedAppURL.path)
            || fileManager.fileExists(atPath: bundledAppURL.path)
        let manifestExists = fileManager.fileExists(atPath: manifestURL.path)
        let manifest = manifestExists
            ? try? JSONDecoder().decode(
                OpenClickyBackgroundComputerUseRuntimeManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            : nil

        let effectiveErrorMessage = lastErrorMessage ?? Self.unsafeRuntimeMessage
        return OpenClickyBackgroundComputerUseStatus(
            sourceRootPath: sourceRootURL.path,
            sourceAvailable: sourceAvailable,
            startScriptAvailable: startScriptAvailable,
            installedAppAvailable: installedAppAvailable,
            manifestPath: manifestURL.path,
            manifestExists: manifestExists,
            baseURL: manifest?.baseURL,
            startedAt: manifest?.startedAt,
            accessibilityGranted: manifest?.permissions.accessibility.granted,
            screenRecordingGranted: manifest?.permissions.screenRecording.granted,
            instructionsReady: manifest?.instructions.ready,
            instructionsSummary: manifest?.instructions.summary,
            isStarting: isStarting,
            lastErrorMessage: effectiveErrorMessage
        )
    }
}

nonisolated struct OpenClickyBackgroundComputerUseActionResult: Sendable, Hashable {
    let windowID: String
    let summary: String
    let ok: Bool
}

nonisolated enum OpenClickyBackgroundComputerUseError: Error, LocalizedError, Equatable {
    case runtimeUnavailable(String)
    case noFrontmostApp
    case noWindow(appName: String)
    case screenshotUnavailable(String)
    case actionFailed(route: String, summary: String)
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let status):
            return "Background Computer Use runtime is unavailable: \(status)"
        case .noFrontmostApp:
            return "Background Computer Use could not resolve the frontmost app."
        case .noWindow(let appName):
            return "Background Computer Use could not resolve a target window for \(appName)."
        case .screenshotUnavailable(let reason):
            return "Background Computer Use screenshot unavailable: \(reason)"
        case .actionFailed(let route, let summary):
            return "Background Computer Use \(route) failed: \(summary)"
        case .httpError(let statusCode, let message):
            return "Background Computer Use HTTP \(statusCode): \(message)"
        }
    }
}

private nonisolated struct OpenClickyBackgroundComputerUseRuntimeManifest: Decodable {
    let baseURL: String
    let startedAt: String?
    let permissions: OpenClickyBackgroundComputerUseRuntimePermissions
    let instructions: OpenClickyBackgroundComputerUseRuntimeInstructions
}

private nonisolated struct OpenClickyBackgroundComputerUseRuntimePermissions: Decodable {
    let accessibility: OpenClickyBackgroundComputerUsePermission
    let screenRecording: OpenClickyBackgroundComputerUsePermission
}

private nonisolated struct OpenClickyBackgroundComputerUsePermission: Decodable {
    let granted: Bool
}

private nonisolated struct OpenClickyBackgroundComputerUseRuntimeInstructions: Decodable {
    let ready: Bool
    let summary: String
}

private nonisolated struct OpenClickyBackgroundComputerUseEmptyRequest: Encodable {}

private nonisolated struct OpenClickyBackgroundComputerUseListAppsResponse: Decodable {
    let frontmostApp: OpenClickyBackgroundComputerUseRunningApp?
    let runningApps: [OpenClickyBackgroundComputerUseRunningApp]
}

private nonisolated struct OpenClickyBackgroundComputerUseRunningApp: Decodable {
    let name: String
    let bundleID: String
    let pid: Int32
    let isFrontmost: Bool
    let onscreenWindowCount: Int
}

private nonisolated struct OpenClickyBackgroundComputerUseListWindowsRequest: Encodable {
    let app: String
}

private nonisolated struct OpenClickyBackgroundComputerUseListWindowsResponse: Decodable {
    let windows: [OpenClickyBackgroundComputerUseWindow]
}

private nonisolated struct OpenClickyBackgroundComputerUseWindow: Decodable, Sendable, Hashable {
    let windowID: String
    let title: String
    let bundleID: String
    let pid: Int32
    let isFocused: Bool
    let isMain: Bool
    let isMinimized: Bool
    let isOnScreen: Bool
}

private nonisolated struct OpenClickyBackgroundComputerUseWindowStateRequest: Encodable {
    let window: String
    let maxNodes: Int
    let imageMode: String
    let includeRawScreenshot: Bool
    let debug: Bool
}

private nonisolated struct OpenClickyBackgroundComputerUseWindowStateResponse: Decodable {
    let stateToken: String
    let window: OpenClickyBackgroundComputerUseResolvedWindow
    let screenshot: OpenClickyBackgroundComputerUseScreenshot
}

private nonisolated struct OpenClickyBackgroundComputerUseResolvedWindow: Decodable, Sendable, Hashable {
    let windowID: String
    let title: String
    let bundleID: String
    let pid: Int32
}

private nonisolated struct OpenClickyBackgroundComputerUseScreenshot: Decodable {
    let status: String
    let image: OpenClickyBackgroundComputerUseScreenshotImage?
    let captureError: String?
}

private nonisolated struct OpenClickyBackgroundComputerUseScreenshotImage: Decodable {
    let imagePath: String?
    let imageBase64: String?
    let pixelWidth: Int
    let pixelHeight: Int
}

private nonisolated struct OpenClickyBackgroundComputerUseCursorRequest: Encodable {
    let id: String
    let name: String
    let color: String
}

private nonisolated struct OpenClickyBackgroundComputerUsePressKeyRequest: Encodable {
    let window: String
    let key: String
    let cursor: OpenClickyBackgroundComputerUseCursorRequest
    let imageMode: String
    let debug: Bool
    // BCU stale-coordinate guard token (H4): obtained from /v1/get_window_state
    // and echoed back so BCU can reject clicks/keys against a stale AX tree.
    let stateToken: String?
}

private nonisolated struct OpenClickyBackgroundComputerUseTypeTextRequest: Encodable {
    let window: String
    let text: String
    let focusAssistMode: String
    let cursor: OpenClickyBackgroundComputerUseCursorRequest
    let imageMode: String
    let debug: Bool
    let stateToken: String?

    enum CodingKeys: String, CodingKey {
        case window
        case text
        case focusAssistMode
        case cursor
        case imageMode
        case debug
        case stateToken
    }
}

private nonisolated struct OpenClickyBackgroundComputerUseClickRequest: Encodable {
    let window: String
    let x: Double
    let y: Double
    let clickCount: Int
    let cursor: OpenClickyBackgroundComputerUseCursorRequest
    let imageMode: String
    let debug: Bool
    let stateToken: String?
}

private nonisolated struct OpenClickyBackgroundComputerUseActionResponse: Decodable {
    let ok: Bool
    let summary: String
}

@MainActor
enum OpenClickyComputerUsePermissionProbe {
    static func status() -> OpenClickyComputerUsePermissionStatus {
        OpenClickyComputerUsePermissionStatus(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(),
            skyLightKeyboardPathAvailable: OpenClickySkyLightEventPost.isAvailable,
            fullDiskAccessLikelyGranted: OpenClickyMacPrivacyPermissionProbe.hasLikelyFullDiskAccess()
        )
    }
}

enum OpenClickyMacPrivacyPermissionProbe {
    static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    static let systemEventsBundleIdentifier = "com.apple.systemevents"

    static func hasSystemEventsAutomationPermission(prompt: Bool = false) -> Bool {
        hasAppleEventsAutomationPermission(
            targetBundleIdentifier: systemEventsBundleIdentifier,
            prompt: prompt
        )
    }

    static func hasAppleEventsAutomationPermission(targetBundleIdentifier: String, prompt: Bool = false) -> Bool {
        // Avoid noisy non-prompt probes for targets that are not running. On
        // macOS, even System Events can emit repeated AEDeterminePermission...
        // procNotFound diagnostics when probed from the refresh timer before it
        // is launched. Explicit request flows still pass prompt: true below.
        if !prompt,
           NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleIdentifier).isEmpty {
            return false
        }

        let target = NSAppleEventDescriptor(bundleIdentifier: targetBundleIdentifier)
        guard let targetDescriptor = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(
            targetDescriptor,
            typeWildCard,
            typeWildCard,
            prompt
        )
        return status == noErr
    }

    static func hasLikelyFullDiskAccess(fileManager: FileManager = .default) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Messages/chat.db"),
            home.appendingPathComponent("Library/Safari/History.db"),
            home.appendingPathComponent("Library/Mail", isDirectory: true)
        ]

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            if canReadProtectedItem(candidate, fileManager: fileManager) {
                return true
            }
        }

        return false
    }

    private static func canReadProtectedItem(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }

        if isDirectory.boolValue {
            return (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil
        }

        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return false
        }
        try? handle.close()
        return true
    }
}

enum OpenClickyComputerUseAppEnumerator {
    static func apps() -> [OpenClickyComputerUseAppInfo] {
        var byBundleId: [String: OpenClickyComputerUseAppInfo] = [:]
        var entries: [OpenClickyComputerUseAppInfo] = []

        func record(_ info: OpenClickyComputerUseAppInfo) {
            if let bundleId = info.bundleId, !bundleId.isEmpty {
                if byBundleId[bundleId] != nil { return }
                byBundleId[bundleId] = info
            }
            entries.append(info)
        }

        var seenPids = Set<Int32>()
        if let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for window in windows {
                guard let rawPid = window[kCGWindowOwnerPID as String] as? Int,
                      let pid = Int32(exactly: rawPid),
                      !seenPids.contains(pid),
                      let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular else {
                    continue
                }
                seenPids.insert(pid)
                record(runningInfo(app))
            }
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard !seenPids.contains(pid) else { continue }
            seenPids.insert(pid)
            record(runningInfo(app))
        }

        for installed in installedApps() {
            if let bundleId = installed.bundleId, byBundleId[bundleId] != nil {
                continue
            }
            record(installed)
        }

        return entries
    }

    private static func runningInfo(_ app: NSRunningApplication) -> OpenClickyComputerUseAppInfo {
        OpenClickyComputerUseAppInfo(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier,
            name: app.localizedName ?? "",
            running: true,
            active: app.isActive
        )
    }

    private static func installedApps() -> [OpenClickyComputerUseAppInfo] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "\(home)/Applications",
            "\(home)/Applications/Chrome Apps.localized",
            "/System/Applications",
            "/System/Applications/Utilities"
        ]

        return roots.flatMap { root -> [OpenClickyComputerUseAppInfo] in
            guard let children = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
            return children.compactMap { child in
                guard child.hasSuffix(".app") else { return nil }
                return infoFromBundle(at: "\(root)/\(child)")
            }
        }
    }

    private static func infoFromBundle(at path: String) -> OpenClickyComputerUseAppInfo? {
        guard let bundle = Bundle(path: path), let bundleId = bundle.bundleIdentifier else { return nil }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent

        return OpenClickyComputerUseAppInfo(
            pid: 0,
            bundleId: bundleId,
            name: name,
            running: false,
            active: false
        )
    }
}

enum OpenClickyComputerUseWindowEnumerator {
    static func visibleWindows() -> [OpenClickyComputerUseWindowInfo] {
        enumerate(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    static func allWindows() -> [OpenClickyComputerUseWindowInfo] {
        enumerate(options: [.excludeDesktopElements])
    }

    static func frontmostTargetWindow(from windows: [OpenClickyComputerUseWindowInfo]? = nil) -> OpenClickyComputerUseWindowInfo? {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidates = (windows ?? visibleWindows())
            .filter { $0.isOnScreen && $0.layer == 0 && $0.bounds.width > 100 && $0.bounds.height > 80 }
            .filter { window in
                guard let app = NSRunningApplication(processIdentifier: window.pid) else { return true }
                return app.bundleIdentifier != ownBundleIdentifier
            }

        if let frontmostBundleIdentifier, frontmostBundleIdentifier != ownBundleIdentifier {
            let focusedCandidates = candidates.filter { window in
                NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier == frontmostBundleIdentifier
            }
            if let focused = focusedCandidates.max(by: { $0.zIndex < $1.zIndex }) {
                return focused
            }
        }

        return candidates.max(by: { $0.zIndex < $1.zIndex })
    }

    private static func enumerate(options: CGWindowListOption) -> [OpenClickyComputerUseWindowInfo] {
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let total = rawWindows.count
        return rawWindows.enumerated().compactMap { index, entry in
            parse(entry, zIndex: total - index)
        }
    }

    private static func parse(_ entry: [String: Any], zIndex: Int) -> OpenClickyComputerUseWindowInfo? {
        guard let id = entry[kCGWindowNumber as String] as? Int,
              let pidValue = entry[kCGWindowOwnerPID as String] as? Int,
              let pid = Int32(exactly: pidValue),
              let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Double] else {
            return nil
        }

        let bounds = OpenClickyComputerUseWindowBounds(
            x: boundsDictionary["X"] ?? 0,
            y: boundsDictionary["Y"] ?? 0,
            width: boundsDictionary["Width"] ?? 0,
            height: boundsDictionary["Height"] ?? 0
        )

        return OpenClickyComputerUseWindowInfo(
            id: id,
            pid: pid,
            owner: entry[kCGWindowOwnerName as String] as? String ?? "",
            name: entry[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            zIndex: zIndex,
            isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
            layer: entry[kCGWindowLayer as String] as? Int ?? 0
        )
    }
}

enum OpenClickyComputerUseWindowCaptureUtility {
    @MainActor
    static func capture(window targetWindow: OpenClickyComputerUseWindowInfo) async throws -> OpenClickyComputerUseWindowCapture {
        let content = try await CompanionScreenCaptureUtility.currentShareableContent()
        guard let screenCaptureWindow = content.windows.first(where: { Int($0.windowID) == targetWindow.id }) else {
            throw OpenClickyComputerUseError.windowCaptureUnavailable
        }

        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let windowWidth = max(1, Int(screenCaptureWindow.frame.width))
        let windowHeight = max(1, Int(screenCaptureWindow.frame.height))
        let aspectRatio = CGFloat(windowWidth) / CGFloat(windowHeight)

        if windowWidth >= windowHeight {
            configuration.width = maxDimension
            configuration.height = max(1, Int(CGFloat(maxDimension) / aspectRatio))
        } else {
            configuration.height = maxDimension
            configuration.width = max(1, Int(CGFloat(maxDimension) * aspectRatio))
        }

        let filter = SCContentFilter(desktopIndependentWindow: screenCaptureWindow)
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let imageData = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw OpenClickyComputerUseError.imageEncodingFailed
        }

        return OpenClickyComputerUseWindowCapture(
            imageData: imageData,
            window: targetWindow,
            screenshotWidthInPixels: cgImage.width,
            screenshotHeightInPixels: cgImage.height
        )
    }
}

enum OpenClickyComputerUseKeyboardInput {
    static func press(_ key: String, modifiers: [String] = [], toPid pid: pid_t? = nil) throws {
        guard let code = virtualKeyCode(for: key) else {
            throw OpenClickyComputerUseError.unknownKey(key)
        }
        let flags = modifierMask(for: modifiers)
        try sendKey(code: code, down: true, flags: flags, toPid: pid)
        try sendKey(code: code, down: false, flags: flags, toPid: pid)
    }

    static func typeCharacters(_ text: String, delayMilliseconds: Int = 30, toPid pid: pid_t? = nil) throws {
        let clampedDelay = max(0, min(200, delayMilliseconds))
        for character in text {
            try sendUnicodeCharacter(character, toPid: pid)
            if clampedDelay > 0 {
                usleep(UInt32(clampedDelay) * 1_000)
            }
        }
    }

    private static func sendKey(code: Int, down: Bool, flags: CGEventFlags, toPid pid: pid_t?) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else {
            throw OpenClickyComputerUseError.eventCreationFailed("code=\(code) down=\(down)")
        }
        event.flags = flags
        post(event, toPid: pid)
    }

    private static func sendUnicodeCharacter(_ character: Character, toPid pid: pid_t?) throws {
        let utf16 = Array(String(character).utf16)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                throw OpenClickyComputerUseError.eventCreationFailed("unicode character \"\(character)\" down=\(keyDown)")
            }
            utf16.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
                }
            }
            post(event, toPid: pid)
        }
    }

    private static func post(_ event: CGEvent, toPid pid: pid_t?) {
        if let pid {
            if !OpenClickySkyLightEventPost.postToPid(pid, event: event) {
                event.postToPid(pid)
            }
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private static func modifierMask(for modifiers: [String]) -> CGEventFlags {
        var mask: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command": mask.insert(.maskCommand)
            case "shift": mask.insert(.maskShift)
            case "option", "alt": mask.insert(.maskAlternate)
            case "ctrl", "control": mask.insert(.maskControl)
            case "fn": mask.insert(.maskSecondaryFn)
            default: break
            }
        }
        return mask
    }

    private static func virtualKeyCode(for name: String) -> Int? {
        let lowercasedName = name.lowercased()
        if let named = namedKeys[lowercasedName] { return named }
        guard lowercasedName.count == 1, let first = lowercasedName.first else { return nil }
        if let letter = letterKeys[first] { return letter }
        if let digit = digitKeys[first] { return digit }
        return nil
    }

    private static let namedKeys: [String: Int] = [
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        "delete": 0x33, "backspace": 0x33,
        "forwarddelete": 0x75, "del": 0x75,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "leftarrow": 0x7B,
        "right": 0x7C, "rightarrow": 0x7C,
        "down": 0x7D, "downarrow": 0x7D,
        "up": 0x7E, "uparrow": 0x7E,
        "home": 0x73, "end": 0x77,
        "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F
    ]

    private static let letterKeys: [Character: Int] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06
    ]

    private static let digitKeys: [Character: Int] = [
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
        "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19
    ]
}

enum OpenClickyComputerUseMouseInput {
    static func leftClick(at point: CGPoint) throws {
        // M9: clamp an off-screen point to the nearest screen before converting,
        // instead of returning an unconverted AppKit point (wrong-Y) to a CGEvent
        // — which previously landed an intended-but-off-screen click at an
        // unrelated on-screen location. Now we find the nearest screen, clamp
        // into its frame, and convert. If no screen exists at all, we throw.
        let clampedPoint = Self.clampToNearestScreen(point)
        let quartzPoint = try Self.quartzPoint(fromAppKitPoint: clampedPoint)
        try postMouseEvent(type: .mouseMoved, at: quartzPoint)
        try postMouseEvent(type: .leftMouseDown, at: quartzPoint)
        usleep(35_000)
        try postMouseEvent(type: .leftMouseUp, at: quartzPoint)
    }

    /// Clamp a point to the nearest screen's frame (used when a model-derived
    /// coordinate lands in a gap between displays or outside the desktop union).
    private static func clampToNearestScreen(_ point: CGPoint) -> CGPoint {
        if NSScreen.screens.contains(where: { $0.frame.contains(point) }) {
            return point
        }
        let nearest = NSScreen.screens.min(by: { lhs, rhs in
            Self.distance(from: point, to: lhs.frame) < Self.distance(from: point, to: rhs.frame)
        })
        guard let frame = nearest?.frame else { return point }
        return CGPoint(
            x: min(max(point.x, frame.minX), frame.maxX),
            y: min(max(point.y, frame.minY), frame.maxY)
        )
    }

    private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return (dx * dx) + (dy * dy)
    }

    private static func quartzPoint(fromAppKitPoint point: CGPoint) throws -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            // After clamping this should not happen unless there are no screens
            // at all (headless / display sleep). Throw rather than hand an
            // unconverted AppKit point (wrong Y axis) to CGEvent.
            throw OpenClickyComputerUseError.eventCreationFailed("click target is off-screen and no display is available")
        }

        let appKitFrame = screen.frame
        let quartzFrame = CGDisplayBounds(displayID)
        let localX = point.x - appKitFrame.origin.x
        let localYFromTop = appKitFrame.maxY - point.y
        return CGPoint(
            x: quartzFrame.origin.x + localX,
            y: quartzFrame.origin.y + localYFromTop
        )
    }

    private static func postMouseEvent(type: CGEventType, at point: CGPoint) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw OpenClickyComputerUseError.eventCreationFailed("mouse \(type.rawValue) at \(Int(point.x)),\(Int(point.y))")
        }
        event.post(tap: .cghidEventTap)
    }
}

enum OpenClickySkyLightEventPost {
    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthMessageFn = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias FactoryMsgSendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> AnyObject?

    private struct Resolved {
        let postToPid: PostToPidFn
        let setAuthMessage: SetAuthMessageFn
        let msgSendFactory: FactoryMsgSendFn
        let messageClass: AnyClass
        let factorySelector: Selector
    }

    private static let resolved: Resolved? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

        func resolve<T>(_ name: String, as _: T.Type) -> T? {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard let postToPid = resolve("SLEventPostToPid", as: PostToPidFn.self),
              let setAuthMessage = resolve("SLEventSetAuthenticationMessage", as: SetAuthMessageFn.self),
              let msgSendFactory = resolve("objc_msgSend", as: FactoryMsgSendFn.self),
              let messageClass = NSClassFromString("SLSEventAuthenticationMessage") else {
            return nil
        }

        return Resolved(
            postToPid: postToPid,
            setAuthMessage: setAuthMessage,
            msgSendFactory: msgSendFactory,
            messageClass: messageClass,
            factorySelector: NSSelectorFromString("messageWithEventRecord:pid:version:")
        )
    }()

    static var isAvailable: Bool { resolved != nil }

    @discardableResult
    static func postToPid(_ pid: pid_t, event: CGEvent) -> Bool {
        guard let resolved else { return false }

        if let record = extractEventRecord(from: event),
           let message = resolved.msgSendFactory(
            resolved.messageClass as AnyObject,
            resolved.factorySelector,
            record,
            pid,
            0
           ) {
            resolved.setAuthMessage(event, message)
        }

        resolved.postToPid(pid, event)
        return true
    }

    private static func extractEventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let record = slot.pointee { return record }
        }
        return nil
    }
}
