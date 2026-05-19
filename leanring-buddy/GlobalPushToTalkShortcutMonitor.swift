//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    let shiftDoubleTapPublisher = PassthroughSubject<CGPoint, Never>()

    @Published private(set) var isActivationShortcutEnabled = true

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var isShiftCurrentlyPressed = false
    private var isShiftTapStandaloneCandidate = false
    private var lastStandaloneShiftTapDate: Date?
    private let maximumShiftDoubleTapInterval: TimeInterval = 0.42
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
        }
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    func setActivationShortcutEnabled(_ enabled: Bool) {
        guard isActivationShortcutEnabled != enabled else { return }

        isActivationShortcutEnabled = enabled
        if !enabled && isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isActivationShortcutEnabled else {
            handleStandaloneShiftTapIfNeeded(eventType: eventType, event: event)
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            handleStandaloneShiftTapIfNeeded(eventType: eventType, event: event)
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleStandaloneShiftTapIfNeeded(eventType: CGEventType, event: CGEvent) {
        if eventType == .keyDown && isShiftCurrentlyPressed {
            // Shift was used as a real typing modifier, not as the standalone
            // double-tap shortcut. Without this guard, typing two capital
            // letters or symbols quickly can open the OpenClicky panel.
            isShiftTapStandaloneCandidate = false
            lastStandaloneShiftTapDate = nil
            return
        }

        guard eventType == .flagsChanged else { return }

        let flags = event.flags
        let isShiftDown = flags.contains(.maskShift)
        let isShiftOnly = isShiftDown
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskCommand)

        if isShiftOnly && !isShiftCurrentlyPressed {
            isShiftCurrentlyPressed = true
            isShiftTapStandaloneCandidate = true
            return
        }

        if isShiftCurrentlyPressed && !isShiftDown {
            defer {
                isShiftCurrentlyPressed = false
                isShiftTapStandaloneCandidate = false
            }

            guard isShiftTapStandaloneCandidate else { return }

            let now = Date()
            if let lastStandaloneShiftTapDate,
               now.timeIntervalSince(lastStandaloneShiftTapDate) <= maximumShiftDoubleTapInterval {
                self.lastStandaloneShiftTapDate = nil
                shiftDoubleTapPublisher.send(NSEvent.mouseLocation)
            } else {
                lastStandaloneShiftTapDate = now
            }
            return
        }

        if isShiftCurrentlyPressed && !isShiftOnly {
            isShiftTapStandaloneCandidate = false
            lastStandaloneShiftTapDate = nil
        }

        isShiftCurrentlyPressed = isShiftDown
    }
}
