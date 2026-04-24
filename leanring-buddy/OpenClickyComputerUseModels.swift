import Foundation

/// Native, in-app computer-use models inspired by trycua/cua-driver.
///
/// CUA source reference: /Users/jkneen/Documents/GitHub/cua/libs/cua-driver
/// License: MIT, Copyright (c) 2025 Cua AI, Inc.
///
/// This file intentionally contains only OpenClicky-owned data contracts. The
/// runtime adapters live in OpenClickyComputerUseRuntime.swift so model tests can
/// stay pure and cheap.
struct OpenClickyComputerUseWindowBounds: Sendable, Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var agentContextFragment: String {
        "x:\(Int(x)) y:\(Int(y)) width:\(Int(width)) height:\(Int(height))"
    }
}

struct OpenClickyComputerUseWindowInfo: Identifiable, Sendable, Codable, Hashable {
    let id: Int
    let pid: Int32
    let owner: String
    let name: String
    let bounds: OpenClickyComputerUseWindowBounds
    let zIndex: Int
    let isOnScreen: Bool
    let layer: Int

    init(
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

    var displayTitle: String {
        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedOwner.isEmpty && trimmedName.isEmpty { return "Unknown window" }
        if trimmedName.isEmpty { return trimmedOwner }
        if trimmedOwner.isEmpty { return trimmedName }
        return "\(trimmedOwner) — \(trimmedName)"
    }

    var captureLabel: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            return "CUA Swift focused window (\(owner))"
        }
        return "CUA Swift focused window (\(owner) - \(trimmedName))"
    }

    var focusedTargetSummary: String {
        "\(displayTitle) · pid \(pid) · window \(id)"
    }

    var agentContextNote: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let titlePart = trimmedName.isEmpty ? "untitled" : trimmedName
        return "CUA Swift target window id \(id), pid \(pid), owner \(owner), title \(titlePart), bounds \(bounds.agentContextFragment), z-index \(zIndex)."
    }
}

struct OpenClickyComputerUseAppInfo: Identifiable, Sendable, Codable, Hashable {
    var id: String { bundleId ?? "pid:\(pid):\(name)" }

    let pid: Int32
    let bundleId: String?
    let name: String
    let running: Bool
    let active: Bool

    init(pid: Int32, bundleId: String?, name: String, running: Bool, active: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.running = running
        self.active = active
    }
}

struct OpenClickyComputerUsePermissionStatus: Sendable, Codable, Hashable {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    let skyLightKeyboardPathAvailable: Bool

    init(accessibilityGranted: Bool, screenRecordingGranted: Bool, skyLightKeyboardPathAvailable: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.skyLightKeyboardPathAvailable = skyLightKeyboardPathAvailable
    }

    var accessibilitySummary: String {
        accessibilityGranted ? "AX ready" : "AX permission needed"
    }

    var screenRecordingSummary: String {
        screenRecordingGranted ? "screen ready" : "screen permission needed"
    }

    var keyboardSummary: String {
        skyLightKeyboardPathAvailable ? "SkyLight keyboard ready" : "public keyboard fallback"
    }
}

struct OpenClickyComputerUseStatus: Sendable, Codable, Hashable {
    let enabled: Bool
    let permissions: OpenClickyComputerUsePermissionStatus
    let runningAppCount: Int
    let visibleWindowCount: Int
    let focusedWindow: OpenClickyComputerUseWindowInfo?
    let lastErrorMessage: String?

    init(
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

    var isReadyForComputerUse: Bool {
        enabled && permissions.accessibilityGranted && permissions.screenRecordingGranted
    }

    var summary: String {
        guard enabled else { return "Disabled · enable in OpenClicky settings" }

        var parts = [
            "Enabled",
            permissions.accessibilitySummary,
            permissions.screenRecordingSummary,
            permissions.keyboardSummary
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

    var focusedTargetSummary: String {
        focusedWindow?.focusedTargetSummary ?? "No target window refreshed yet"
    }
}

struct OpenClickyComputerUseWindowCapture: Sendable, Hashable {
    let imageData: Data
    let window: OpenClickyComputerUseWindowInfo
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int

    init(
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

    var label: String { window.captureLabel }

    var agentContextNote: String {
        "\(window.agentContextNote) Image dimensions \(screenshotWidthInPixels)x\(screenshotHeightInPixels) pixels."
    }
}

enum OpenClickyComputerUseError: Error, LocalizedError, Equatable {
    case disabled
    case noTargetWindow
    case windowCaptureUnavailable
    case imageEncodingFailed
    case unknownKey(String)
    case eventCreationFailed(String)

    var errorDescription: String? {
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
