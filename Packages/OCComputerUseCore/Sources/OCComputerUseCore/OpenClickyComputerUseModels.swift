import Foundation

nonisolated public enum OpenClickyComputerUseBackendID: String, CaseIterable, Identifiable, Sendable {
    case nativeSwift = "native_swift"
    case backgroundComputerUse = "background_computer_use"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .nativeSwift:
            return "Native CUA Swift"
        case .backgroundComputerUse:
            return "Background Computer Use"
        }
    }

    public var subtitle: String {
        switch self {
        case .nativeSwift:
            return "Embedded OpenClicky control"
        case .backgroundComputerUse:
            return "Loopback runtime from background-computer-use"
        }
    }

    public var executorID: String {
        switch self {
        case .nativeSwift:
            return "native_cua"
        case .backgroundComputerUse:
            return "background_computer_use"
        }
    }

    public static let fallback: OpenClickyComputerUseBackendID = .nativeSwift

    public static func resolving(_ rawValue: String?) -> OpenClickyComputerUseBackendID {
        guard let rawValue,
              let backend = OpenClickyComputerUseBackendID(rawValue: rawValue) else {
            return fallback
        }

        return backend
    }
}

/// Native, in-app computer-use models inspired by trycua/cua-driver.
///
/// CUA source reference: /Users/jkneen/Documents/GitHub/cua/libs/cua-driver
/// License: MIT, Copyright (c) 2025 Cua AI, Inc.
///
/// This file intentionally contains only data contracts. The runtime adapters
/// (AppKit, Accessibility, ScreenCaptureKit, CGEvent) live in the host app so
/// model tests can stay pure and cheap. Process-querying conveniences such as
/// `bundleIdentifier` / `appName` are provided by the host as extensions.
public struct OpenClickyComputerUseWindowBounds: Sendable, Codable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var agentContextFragment: String {
        "x:\(Int(x)) y:\(Int(y)) width:\(Int(width)) height:\(Int(height))"
    }
}

public struct OpenClickyComputerUseWindowInfo: Identifiable, Sendable, Codable, Hashable {
    public let id: Int
    public let pid: Int32
    public let owner: String
    public let name: String
    public let bounds: OpenClickyComputerUseWindowBounds
    public let zIndex: Int
    public let isOnScreen: Bool
    public let layer: Int

    public init(
        id: Int,
        pid: Int32,
        owner: String,
        name: String,
        bounds: OpenClickyComputerUseWindowBounds,
        zIndex: Int,
        isOnScreen: Bool,
        layer: Int
    ) {
        self.id = id
        self.pid = pid
        self.owner = owner
        self.name = name
        self.bounds = bounds
        self.zIndex = zIndex
        self.isOnScreen = isOnScreen
        self.layer = layer
    }

    public var displayTitle: String {
        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedOwner.isEmpty && trimmedName.isEmpty { return "Unknown window" }
        if trimmedName.isEmpty { return trimmedOwner }
        if trimmedOwner.isEmpty { return trimmedName }
        return "\(trimmedOwner) — \(trimmedName)"
    }

    public var captureLabel: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            return "CUA Swift focused window (\(owner))"
        }
        return "CUA Swift focused window (\(owner) - \(trimmedName))"
    }

    public var focusedTargetSummary: String {
        "\(displayTitle) · pid \(pid) · window \(id)"
    }

    public var agentContextNote: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let titlePart = trimmedName.isEmpty ? "untitled" : trimmedName
        return "CUA Swift target window id \(id), pid \(pid), owner \(owner), title \(titlePart), bounds \(bounds.agentContextFragment), z-index \(zIndex)."
    }
}

public struct OpenClickyComputerUseAppInfo: Identifiable, Sendable, Codable, Hashable {
    public var id: String { bundleId ?? "pid:\(pid):\(name)" }

    public let pid: Int32
    public let bundleId: String?
    public let name: String
    public let running: Bool
    public let active: Bool

    public init(pid: Int32, bundleId: String?, name: String, running: Bool, active: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.running = running
        self.active = active
    }
}

public struct OpenClickyComputerUsePermissionStatus: Sendable, Codable, Hashable {
    public let accessibilityGranted: Bool
    public let screenRecordingGranted: Bool
    public let skyLightKeyboardPathAvailable: Bool
    public let fullDiskAccessLikelyGranted: Bool

    public init(
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        skyLightKeyboardPathAvailable: Bool,
        fullDiskAccessLikelyGranted: Bool = false
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.skyLightKeyboardPathAvailable = skyLightKeyboardPathAvailable
        self.fullDiskAccessLikelyGranted = fullDiskAccessLikelyGranted
    }

    public var accessibilitySummary: String {
        accessibilityGranted ? "AX ready" : "AX permission needed"
    }

    public var screenRecordingSummary: String {
        screenRecordingGranted ? "screen ready" : "screen permission needed"
    }

    public var keyboardSummary: String {
        skyLightKeyboardPathAvailable ? "SkyLight keyboard ready" : "public keyboard fallback"
    }

    public var fullDiskAccessSummary: String {
        fullDiskAccessLikelyGranted ? "Full Disk Access likely ready" : "Full Disk Access not detected"
    }
}

public struct OpenClickyComputerUseStatus: Sendable, Codable, Hashable {
    public let enabled: Bool
    public let permissions: OpenClickyComputerUsePermissionStatus
    public let runningAppCount: Int
    public let visibleWindowCount: Int
    public let focusedWindow: OpenClickyComputerUseWindowInfo?
    public let lastErrorMessage: String?

    public init(
        enabled: Bool,
        permissions: OpenClickyComputerUsePermissionStatus,
        runningAppCount: Int,
        visibleWindowCount: Int,
        focusedWindow: OpenClickyComputerUseWindowInfo?,
        lastErrorMessage: String?
    ) {
        self.enabled = enabled
        self.permissions = permissions
        self.runningAppCount = runningAppCount
        self.visibleWindowCount = visibleWindowCount
        self.focusedWindow = focusedWindow
        self.lastErrorMessage = lastErrorMessage
    }

    public var isReadyForComputerUse: Bool {
        enabled && permissions.accessibilityGranted && permissions.screenRecordingGranted
    }

    public var summary: String {
        guard enabled else { return "Disabled · enable in OpenClicky settings" }

        var parts = [
            "Enabled",
            permissions.accessibilitySummary,
            permissions.screenRecordingSummary,
            permissions.keyboardSummary,
            permissions.fullDiskAccessSummary
        ]

        if let focusedWindow {
            parts.append(focusedWindow.owner)
        } else if let lastErrorMessage, !lastErrorMessage.isEmpty {
            parts.append(lastErrorMessage)
        } else {
            parts.append("no focused target")
        }

        return parts.joined(separator: " · ")
    }

    public var focusedTargetSummary: String {
        focusedWindow?.focusedTargetSummary ?? "No target window refreshed yet"
    }
}

public struct OpenClickyComputerUseWindowCapture: Sendable, Hashable {
    public let imageData: Data
    public let window: OpenClickyComputerUseWindowInfo
    public let screenshotWidthInPixels: Int
    public let screenshotHeightInPixels: Int

    public init(
        imageData: Data,
        window: OpenClickyComputerUseWindowInfo,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) {
        self.imageData = imageData
        self.window = window
        self.screenshotWidthInPixels = screenshotWidthInPixels
        self.screenshotHeightInPixels = screenshotHeightInPixels
    }

    public var label: String { window.captureLabel }

    public var agentContextNote: String {
        let widthScale = window.bounds.width / Double(max(1, screenshotWidthInPixels))
        let heightScale = window.bounds.height / Double(max(1, screenshotHeightInPixels))
        return "\(window.agentContextNote) Image dimensions \(screenshotWidthInPixels)x\(screenshotHeightInPixels) pixels. Screenshot is a proportional downsample of the focused window, not full native display pixels; map screenshot pixel coordinates to window bounds with xScale \(Self.formatScale(widthScale)) and yScale \(Self.formatScale(heightScale))."
    }

    private static func formatScale(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

public struct OpenClickyBackgroundComputerUseStatus: Sendable, Hashable {
    public let sourceRootPath: String
    public let sourceAvailable: Bool
    public let startScriptAvailable: Bool
    public let installedAppAvailable: Bool
    public let manifestPath: String
    public let manifestExists: Bool
    public let baseURL: String?
    public let startedAt: String?
    public let accessibilityGranted: Bool?
    public let screenRecordingGranted: Bool?
    public let instructionsReady: Bool?
    public let instructionsSummary: String?
    public let isStarting: Bool
    public let lastErrorMessage: String?

    public init(
        sourceRootPath: String,
        sourceAvailable: Bool,
        startScriptAvailable: Bool,
        installedAppAvailable: Bool,
        manifestPath: String,
        manifestExists: Bool,
        baseURL: String?,
        startedAt: String?,
        accessibilityGranted: Bool?,
        screenRecordingGranted: Bool?,
        instructionsReady: Bool?,
        instructionsSummary: String?,
        isStarting: Bool,
        lastErrorMessage: String?
    ) {
        self.sourceRootPath = sourceRootPath
        self.sourceAvailable = sourceAvailable
        self.startScriptAvailable = startScriptAvailable
        self.installedAppAvailable = installedAppAvailable
        self.manifestPath = manifestPath
        self.manifestExists = manifestExists
        self.baseURL = baseURL
        self.startedAt = startedAt
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.instructionsReady = instructionsReady
        self.instructionsSummary = instructionsSummary
        self.isStarting = isStarting
        self.lastErrorMessage = lastErrorMessage
    }

    public var isRuntimeReady: Bool {
        manifestExists && baseURL != nil && instructionsReady != false && lastErrorMessage == nil
    }

    public var summary: String {
        if isStarting {
            return "Starting runtime from \(sourceRootPath)"
        }

        guard sourceAvailable else {
            return "Source folder missing at \(sourceRootPath)"
        }

        guard startScriptAvailable else {
            return "BackgroundComputerUse launcher missing at \(sourceRootPath)"
        }

        guard manifestExists else {
            return installedAppAvailable
                ? "Installed app found, but runtime manifest is not active"
                : "Runtime not started yet"
        }

        if let lastErrorMessage, !lastErrorMessage.isEmpty {
            return "Runtime manifest found, but last request failed: \(lastErrorMessage)"
        }

        let permissionSummary: String
        switch (accessibilityGranted, screenRecordingGranted) {
        case (.some(true), .some(true)):
            permissionSummary = "permissions ready"
        case (.some(false), .some(false)):
            permissionSummary = "Accessibility and Screen Recording needed"
        case (.some(false), _):
            permissionSummary = "Accessibility needed"
        case (_, .some(false)):
            permissionSummary = "Screen Recording needed"
        default:
            permissionSummary = "permissions unknown"
        }

        if let baseURL, !baseURL.isEmpty {
            return "Ready at \(baseURL) - \(permissionSummary)"
        }

        return "Manifest found - \(permissionSummary)"
    }
}

public struct OpenClickyBackgroundComputerUseWindowCapture: Sendable, Hashable {
    public let imageData: Data
    public let windowID: String
    public let title: String
    public let bundleID: String
    public let pid: Int32
    public let baseURL: String
    public let stateToken: String
    public let imagePath: String?
    public let screenshotWidthInPixels: Int
    public let screenshotHeightInPixels: Int

    public init(
        imageData: Data,
        windowID: String,
        title: String,
        bundleID: String,
        pid: Int32,
        baseURL: String,
        stateToken: String,
        imagePath: String?,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) {
        self.imageData = imageData
        self.windowID = windowID
        self.title = title
        self.bundleID = bundleID
        self.pid = pid
        self.baseURL = baseURL
        self.stateToken = stateToken
        self.imagePath = imagePath
        self.screenshotWidthInPixels = screenshotWidthInPixels
        self.screenshotHeightInPixels = screenshotHeightInPixels
    }

    public var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            return bundleID
        }

        return "\(bundleID) - \(trimmedTitle)"
    }

    public var label: String {
        "Background Computer Use window (\(displayTitle))"
    }

    public var agentContextNote: String {
        let imagePathNote = imagePath.map { "Screenshot path \($0)." } ?? "Screenshot path unavailable."
        return "BackgroundComputerUse target window \(windowID), pid \(pid), bundleID \(bundleID), title \(title), state token \(stateToken), runtime \(baseURL). Image dimensions \(screenshotWidthInPixels)x\(screenshotHeightInPixels) pixels. \(imagePathNote)"
    }
}

public enum OpenClickyComputerUseError: Error, LocalizedError, Equatable {
    case disabled
    case noTargetWindow
    case windowCaptureUnavailable
    case imageEncodingFailed
    case unknownKey(String)
    case eventCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Native CUA Swift computer use is disabled in OpenClicky settings."
        case .noTargetWindow:
            return "No non-OpenClicky target window is available."
        case .windowCaptureUnavailable:
            return "The target window is not available through ScreenCaptureKit."
        case .imageEncodingFailed:
            return "Failed to encode the target window image."
        case .unknownKey(let key):
            return "Unknown key name: \(key)"
        case .eventCreationFailed(let detail):
            return "Failed to create keyboard event: \(detail)"
        }
    }
}
