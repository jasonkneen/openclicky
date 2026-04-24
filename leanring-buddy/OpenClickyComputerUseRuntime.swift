import AppKit
import ApplicationServices
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
        try OpenClickyComputerUseKeyboardInput.press(key, modifiers: modifiers, toPid: pid)
    }

    func typeText(_ text: String, delayMilliseconds: Int = 30, toPid pid: pid_t? = nil) throws {
        guard isEnabled else { throw OpenClickyComputerUseError.disabled }
        try OpenClickyComputerUseKeyboardInput.typeCharacters(text, delayMilliseconds: delayMilliseconds, toPid: pid)
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
enum OpenClickyComputerUsePermissionProbe {
    static func status() -> OpenClickyComputerUsePermissionStatus {
        OpenClickyComputerUsePermissionStatus(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(),
            skyLightKeyboardPathAvailable: OpenClickySkyLightEventPost.isAvailable
        )
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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
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
