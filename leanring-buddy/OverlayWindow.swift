//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import CoreGraphics
import SwiftUI

// MARK: - AgentParkingPosition

/// Where the agent dock parks itself on the active screen. Eight anchor
/// points: four corners, four mid-edges. Default is top-right because
/// that's where most users put their menubar/notification stack — the
/// dock blends with that visual line without competing for the bottom
/// Dock area. `nonisolated` so the type can be referenced from any
/// actor context (the dock manager calls `originForWindow` from
/// `@MainActor`; CompanionManager bindings cross actors freely).
nonisolated enum AgentParkingPosition: String, CaseIterable, Identifiable {
    case topLeft = "topLeft"
    case topCenter = "topCenter"
    case topRight = "topRight"
    case middleLeft = "middleLeft"
    case middleRight = "middleRight"
    case bottomLeft = "bottomLeft"
    case bottomCenter = "bottomCenter"
    case bottomRight = "bottomRight"

    static let `default`: AgentParkingPosition = .topRight
    static let userDefaultsKey = "openclicky.agentParkingPosition"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top"
        case .topRight: return "Top Right"
        case .middleLeft: return "Left"
        case .middleRight: return "Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// Computes the origin (bottom-left in AppKit coords) for a window
    /// of `size` parked on `screen` at this anchor. Uses `visibleFrame`
    /// so the dock respects the menu bar and system Dock.
    func originForWindow(size: NSSize, on screen: NSScreen, edgeInset: CGFloat = 16) -> CGPoint {
        let frame = screen.frame
        let visible = screen.visibleFrame

        let xLeft = visible.minX + edgeInset
        let xRight = visible.maxX - size.width - edgeInset
        let xCenter = visible.midX - size.width / 2

        let yTop = visible.maxY - size.height - max(edgeInset, frame.maxY - visible.maxY + 8)
        let yBottom = visible.minY + edgeInset
        let yMiddle = visible.midY - size.height / 2

        switch self {
        case .topLeft:      return CGPoint(x: xLeft, y: yTop)
        case .topCenter:    return CGPoint(x: xCenter, y: yTop)
        case .topRight:     return CGPoint(x: xRight, y: yTop)
        case .middleLeft:   return CGPoint(x: xLeft, y: yMiddle)
        case .middleRight:  return CGPoint(x: xRight, y: yMiddle)
        case .bottomLeft:   return CGPoint(x: xLeft, y: yBottom)
        case .bottomCenter: return CGPoint(x: xCenter, y: yBottom)
        case .bottomRight:  return CGPoint(x: xRight, y: yBottom)
        }
    }

    /// Anchor in [0,1]x[0,1] for the preview picker. (0,0) = top-left
    /// in SwiftUI's drawing coordinates.
    var normalizedAnchor: CGPoint {
        switch self {
        case .topLeft:      return CGPoint(x: 0.05, y: 0.10)
        case .topCenter:    return CGPoint(x: 0.50, y: 0.10)
        case .topRight:     return CGPoint(x: 0.95, y: 0.10)
        case .middleLeft:   return CGPoint(x: 0.05, y: 0.50)
        case .middleRight:  return CGPoint(x: 0.95, y: 0.50)
        case .bottomLeft:   return CGPoint(x: 0.05, y: 0.90)
        case .bottomCenter: return CGPoint(x: 0.50, y: 0.90)
        case .bottomRight:  return CGPoint(x: 0.95, y: 0.90)
        }
    }
}

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    let companionManager: CompanionManager
    @ObservedObject var cursorState: CursorOverlayState
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(AppBundleConfiguration.userBuddyFadeWhenIdleEnabledKey) private var buddyFadeWhenIdleEnabled = true
    @AppStorage(AppBundleConfiguration.userBuddyFadeWhenIdleSecondsKey) private var buddyFadeWhenIdleSeconds = 15.0

    /// Extra multiplier when HID has been inactive (orthogonal to onboarding `cursorOpacity`).
    @State private var buddyIdleSuppressionOpacity: Double = 1.0

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager
        self.cursorState = companionManager.cursorOverlayState

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    /// Low-frequency timer: reads HID idle time (~2 Quartz calls/sec, no event taps).
    @State private var idleFadeMonitoringTimer: DispatchSourceTimer?

    /// as a strong reference so the source isn't deallocated mid-tick.
    /// We sample on a `userInteractive` queue (not @MainActor) so the
    /// buddy stays smooth even when the main thread is busy with SwiftUI
    /// animation work or LLM streaming. Hops to main only when the cursor
    /// has actually moved.
    @State private var cursorTrackingTimer: DispatchSourceTimer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    private let fullWelcomeMessage = "hey! i'm clicky"
    private var overlayCursorColor: Color {
        (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor
    }

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(overlayCursorColor)
                            .shadow(color: overlayCursorColor.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity * buddyIdleSuppressionOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(overlayCursorColor)
                            .shadow(
                                color: overlayCursorColor.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity * buddyIdleSuppressionOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            // All three states (triangle, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            Triangle()
                .fill(overlayCursorColor)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: overlayCursorColor, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen && (cursorState.voiceState == .idle || cursorState.voiceState == .responding) ? cursorOpacity * buddyIdleSuppressionOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: cursorState.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Blue waveform — replaces the triangle while listening
            BlueCursorWaveformView(
                audioPowerLevel: cursorState.currentAudioPowerLevel,
                cursorColor: overlayCursorColor,
                isActive: buddyIsVisibleOnThisScreen && cursorState.voiceState == .listening
            )
                .opacity(buddyIsVisibleOnThisScreen && cursorState.voiceState == .listening ? cursorOpacity * buddyIdleSuppressionOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: cursorState.voiceState)

            // Blue spinner — shown while the AI is processing (transcription + Claude + waiting for TTS)
            BlueCursorSpinnerView(
                cursorColor: overlayCursorColor,
                isActive: buddyIsVisibleOnThisScreen && cursorState.voiceState == .processing
            )
                .opacity(buddyIsVisibleOnThisScreen && cursorState.voiceState == .processing ? cursorOpacity * buddyIdleSuppressionOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: cursorState.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()
            scheduleIdleFadeMonitor()

            DispatchQueue.main.async {
                startNavigatingToCurrentDetectedLocationIfNeeded()
                evaluateBuddyHIDIdleFade()
            }

            self.cursorOpacity = 1.0
            self.buddyIdleSuppressionOpacity = 1.0
        }
        .onDisappear {
            timer?.invalidate()
            cursorTrackingTimer?.cancel()
            cursorTrackingTimer = nil
            idleFadeMonitoringTimer?.cancel()
            idleFadeMonitoringTimer = nil
            navigationAnimationTimer?.invalidate()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: cursorState.detectedElementScreenLocation) { _, newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element. When the manager
            // clears the target (for example after the agent dock spawns),
            // force the buddy back into cursor-following mode. Without this,
            // the view could remain in pointing mode until its delayed bubble
            // timers fired, leaving Clicky stuck in the top-right if the main
            // actor was busy starting the agent.
            guard newLocation != nil else {
                resetNavigationStateAndResumeFollowing()
                return
            }
            startNavigatingToCurrentDetectedLocationIfNeeded()
        }
        .onChange(of: buddyFadeWhenIdleEnabled) { _, _ in
            evaluateBuddyHIDIdleFade()
        }
        .onChange(of: buddyFadeWhenIdleSeconds) { _, _ in
            evaluateBuddyHIDIdleFade()
        }
        .onChange(of: cursorState.voiceState) { _, _ in
            evaluateBuddyHIDIdleFade()
        }
        .onChange(of: buddyNavigationMode) { _, _ in
            evaluateBuddyHIDIdleFade()
        }
        .onChange(of: showWelcome) { _, _ in
            evaluateBuddyHIDIdleFade()
        }
    }

    private func startNavigatingToCurrentDetectedLocationIfNeeded() {
        guard let screenLocation = cursorState.detectedElementScreenLocation,
              let displayFrame = cursorState.detectedElementDisplayFrame else {
            return
        }

        // Only navigate if the target is on THIS screen. Use intersection as
        // well as exact equality because NSScreen frame values can differ by
        // tiny amounts across AppKit/SwiftUI conversions.
        guard displayFrame.intersects(screenFrame) || screenFrame.contains(screenLocation) else {
            return
        }

        startNavigatingToElement(screenLocation: screenLocation)
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if cursorState.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Buddy HID idle fade

    /// System HID idle time (`CGEventSource`) in seconds — no CGEvent taps, ~500ms polling.
    private func clippedBuddyFadeIdleThresholdSeconds() -> CGFloat {
        CGFloat(max(5.0, min(180.0, buddyFadeWhenIdleSeconds)))
    }

    private func shortestHIDIdleSecondsAcrossInputs() -> CGFloat {
        let types: [CGEventType] = [
            CGEventType.mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .scrollWheel,
            .keyDown,
            .keyUp,
            .flagsChanged,
        ]
        var shortest = CGFloat.greatestFiniteMagnitude
        for eventType in types {
            let s = CGFloat(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: eventType))
            if s.isFinite, s >= 0, s < shortest {
                shortest = s
            }
        }
        return shortest == .greatestFiniteMagnitude ? 0 : shortest
    }

    private var buddyEligibleForHIDIdleFade: Bool {
        if showWelcome && !welcomeText.isEmpty { return false }
        if buddyNavigationMode != .followingCursor { return false }
        // Keep fully visible whenever voice UX is active (including TTS playback).
        if cursorState.voiceState != .idle { return false }
        return true
    }

    private func evaluateBuddyHIDIdleFade() {
        guard buddyFadeWhenIdleEnabled else {
            if buddyIdleSuppressionOpacity != 1 {
                buddyIdleSuppressionOpacity = 1
            }
            return
        }

        guard buddyEligibleForHIDIdleFade else {
            if buddyIdleSuppressionOpacity != 1 {
                withAnimation(.easeOut(duration: 0.28)) {
                    buddyIdleSuppressionOpacity = 1
                }
            }
            return
        }

        let idle = shortestHIDIdleSecondsAcrossInputs()
        let thresholdSeconds = clippedBuddyFadeIdleThresholdSeconds()
        let shouldHide = idle >= thresholdSeconds
        let targetOpacity: Double = shouldHide ? 0 : 1
        guard abs(targetOpacity - buddyIdleSuppressionOpacity) > 0.02 else { return }

        withAnimation(.easeOut(duration: 0.42)) {
            buddyIdleSuppressionOpacity = targetOpacity
        }
    }

    private func scheduleIdleFadeMonitor() {
        idleFadeMonitoringTimer?.cancel()
        let queue = DispatchQueue(label: "openclicky.buddy.hid.idlefade", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.6, repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler {
            DispatchQueue.main.async {
                evaluateBuddyHIDIdleFade()
            }
        }
        timer.resume()
        idleFadeMonitoringTimer = timer
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        // Sample `NSEvent.mouseLocation` (thread-safe) on a high-priority
        // background queue so cursor tracking is independent of main-actor
        // pressure. A previous version moved this to `Task { @MainActor in
        // ... try? await Task.sleep(...) }` — that re-introduced the
        // exact freeze it was meant to fix because every wake-up landed
        // back on main, contending with SwiftUI animation work and TTS
        // scheduling during agent spawn.
        //
        // We only hop to main when the cursor actually moved. If main is
        // busy, multiple hops may queue up, but each one re-reads
        // `NSEvent.mouseLocation` when it runs, so the buddy never lags
        // behind reality — it just catches up in a burst.
        cursorTrackingTimer?.cancel()

        let queue = DispatchQueue(label: "openclicky.cursor.tracker", qos: .userInteractive)
        let dispatchTimer = DispatchSource.makeTimerSource(queue: queue)
        dispatchTimer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        var lastSampledPoint: CGPoint = .zero
        dispatchTimer.setEventHandler {
            let mouseLocation = NSEvent.mouseLocation
            if mouseLocation == lastSampledPoint { return }
            lastSampledPoint = mouseLocation
            DispatchQueue.main.async {
                updateCursorTracking()
            }
        }
        dispatchTimer.resume()
        cursorTrackingTimer = dispatchTimer
    }

    private func updateCursorTracking() {
        let mouseLocation = NSEvent.mouseLocation
        isCursorOnThisScreen = screenFrame.contains(mouseLocation)

        // During forward flight or pointing, the buddy is NOT interrupted by
        // mouse movement — it completes its full animation and return flight.
        // Only during the RETURN flight do we allow cursor movement to cancel
        // (so the buddy snaps to following if the user moves while it's flying back).
        if buddyNavigationMode == .navigatingToTarget && isReturningToCursor {
            let currentMouseInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
            let distanceFromNavigationStart = hypot(
                currentMouseInSwiftUI.x - cursorPositionWhenNavigationStarted.x,
                currentMouseInSwiftUI.y - cursorPositionWhenNavigationStarted.y
            )
            if distanceFromNavigationStart > 100 {
                cancelNavigationAndResumeFollowing()
            }
            return
        }

        // During forward navigation or pointing, just skip cursor tracking
        if buddyNavigationMode != .followingCursor {
            return
        }

        // Normal cursor following
        let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let buddyX = swiftUIPosition.x + 35
        let buddyY = swiftUIPosition.y + 25
        cursorPosition = CGPoint(x: buddyX, y: buddyY)
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = cursorState.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        resetNavigationStateAndResumeFollowing()
        companionManager.clearDetectedElementLocation()
    }

    private func resetNavigationStateAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        updateCursorTracking()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat
    let cursorColor: Color
    let isActive: Bool

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    @ViewBuilder
    var body: some View {
        if isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
                bars(timelineDate: timelineContext.date)
            }
        } else {
            bars(timelineDate: .distantPast)
        }
    }

    private func bars(timelineDate: Date) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { barIndex in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(cursorColor)
                    .frame(
                        width: 2,
                        height: barHeight(
                            for: barIndex,
                            timelineDate: timelineDate
                        )
                    )
            }
        }
        .shadow(color: cursorColor.opacity(0.6), radius: 6, x: 0, y: 0)
        .animation(.linear(duration: 0.08), value: audioPowerLevel)
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    let cursorColor: Color
    let isActive: Bool
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        cursorColor.opacity(0.0),
                        cursorColor
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning && isActive ? 360 : 0))
            .shadow(color: cursorColor.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                updateSpinning()
            }
            .onChange(of: isActive) { _, _ in
                updateSpinning()
            }
    }

    private func updateSpinning() {
        if isActive {
            isSpinning = false
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        } else {
            withAnimation(nil) {
                isSpinning = false
            }
        }
    }
}

private struct ClickyAgentDockStackView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var hoveredItemID: UUID?
    @State private var didDragDock = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            if companionManager.agentVoiceFollowUpCapturePhase != .idle {
                AgentVoiceFollowUpCaptureBanner(
                    phase: companionManager.agentVoiceFollowUpCapturePhase,
                    audioLevel: companionManager.currentAudioPowerLevel,
                    onCancel: { companionManager.cancelAgentVoiceFollowUpCapture() }
                )
                .frame(width: 512, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            ForEach(companionManager.agentDockItems) { item in
                HStack(alignment: .top, spacing: 22) {
                    // Collapsed by default — icon-only — until the user
                    // hovers. This removes both the always-on conversation
                    // preview AND the post-completion expanded summary card,
                    // matching the "just have the agent icon up there" UX.
                    if shouldShowExpandedCard(for: item) {
                        ClickyAgentDockHoverCard(
                            item: item,
                            canOpenDashboard: companionManager.isAdvancedModeEnabled,
                            chat: { companionManager.openAgentDockItem(item.id) },
                            text: { companionManager.showTextFollowUpForAgentDockItem(item.id) },
                            voice: { companionManager.prepareVoiceFollowUpForAgentDockItem(item.id) },
                            closeThisAgent: { companionManager.closeAgentFromDockItem(item.id) },
                            hideDock: { companionManager.closeAgentDockPanel() },
                            stop: { companionManager.stopAgentDockItem(item.id) },
                            dismiss: { companionManager.dismissAgentDockItem(item.id) },
                            dockDragBegan: {
                                companionManager.beginAgentDockDrag()
                            },
                            dockDragChanged: { companionManager.dragAgentDock(by: $0) },
                            dockDragEnded: {
                                companionManager.endAgentDockDrag()
                                DispatchQueue.main.async {
                                    didDragDock = false
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }

                    Button {
                        if didDragDock {
                            didDragDock = false
                            return
                        }
                        companionManager.openAgentDockItem(item.id)
                    } label: {
                        ClickyAgentDockItemView(item: item)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .pointerCursor()
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                if !didDragDock {
                                    didDragDock = true
                                    companionManager.beginAgentDockDrag()
                                }
                                companionManager.dragAgentDock(by: value.translation)
                            }
                            .onEnded { _ in
                                companionManager.endAgentDockDrag()
                                DispatchQueue.main.async {
                                    didDragDock = false
                                }
                            }
                    )
                }
                .contentShape(Rectangle())
                // Tighter top/trailing inset so the icon sits closer to the
                // corner. Combined with the outer-VStack inset reductions
                // below, the icon shifted ~50px up and ~50px right per UX
                // request 2026-04-28.
                .padding(.top, 0)
                .padding(.trailing, 0)
                .onHover { isHovering in
                    withAnimation(.easeOut(duration: 0.14)) {
                        hoveredItemID = isHovering ? item.id : nil
                    }
                }
            }
        }
        .frame(width: 820, height: 430, alignment: .topTrailing)
        .padding(.top, 0)
        .padding(.trailing, 4)
        .animation(.easeOut(duration: 0.16), value: companionManager.agentDockItems)
        .animation(.easeOut(duration: 0.18), value: companionManager.agentVoiceFollowUpCapturePhase)
    }

    private func shouldShowExpandedCard(for item: ClickyAgentDockItem) -> Bool {
        // Only expand on hover. Previously `.done` and `.failed` stayed
        // expanded automatically so users could read the final summary,
        // but per UX request 2026-04-28 the dock should be icon-only by
        // default — hovering reveals the full card.
        return hoveredItemID == item.id
    }
}

private struct ClickyAgentDockItemView: View {
    let item: ClickyAgentDockItem
    @State private var isStatusAnimating = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(DS.Colors.surface2)
                // Smaller icon (was 68×68) so the dock takes up less screen
                // real estate when collapsed — ties to UX request 2026-04-28.
                .frame(width: 52, height: 52)
                .overlay(
                    Circle()
                        .strokeBorder(
                            item.accentTheme.cursorColor.opacity(0.45),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 5)

            Triangle()
                .fill(item.accentTheme.cursorColor)
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(-35))
                .frame(width: 52, height: 52)

            statusIndicator
                .offset(x: -2, y: 2)
        }
        .frame(width: 92, height: 92, alignment: .center)
        .help(item.title)
        .onAppear {
            isStatusAnimating = true
        }
        .onChange(of: item.status) {
            isStatusAnimating = false
            DispatchQueue.main.async {
                isStatusAnimating = true
            }
        }
    }

    private var statusIndicator: some View {
        ZStack {
            if shouldPulse {
                Circle()
                    .stroke(statusColor.opacity(statusPulseOpacity), lineWidth: 2)
                    .frame(width: statusPulseSize, height: statusPulseSize)
                    .scaleEffect(isStatusAnimating ? statusPulseScale : 0.72)
                    .opacity(isStatusAnimating ? 0.08 : statusPulseOpacity)
                    .animation(
                        .easeInOut(duration: statusPulseDuration).repeatForever(autoreverses: false),
                        value: isStatusAnimating
                    )
            }

            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(item.status == .done ? 0.42 : 0.28), lineWidth: 1)
                )
                .shadow(color: statusColor.opacity(statusGlowOpacity), radius: statusGlowRadius, x: 0, y: 0)
                .scaleEffect(statusCoreScale)
                .animation(
                    shouldPulse
                        ? .easeInOut(duration: statusPulseDuration * 0.5).repeatForever(autoreverses: true)
                        : .easeOut(duration: DS.Animation.fast),
                    value: isStatusAnimating
                )
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(statusAccessibilityLabel)
    }

    private var statusColor: Color {
        switch item.status {
        case .starting:
            return Color(hex: "#60A5FA")
        case .running:
            return Color(hex: "#3B82F6")
        case .done:
            return Color(hex: "#34D399")
        case .failed:
            return Color(hex: "#FF6369")
        }
    }

    private var shouldPulse: Bool {
        switch item.status {
        case .starting, .running, .failed:
            return true
        case .done:
            return false
        }
    }

    private var statusPulseDuration: Double {
        switch item.status {
        case .starting:
            return 1.1
        case .running:
            return 0.82
        case .failed:
            return 0.62
        case .done:
            return 1
        }
    }

    private var statusPulseScale: CGFloat {
        switch item.status {
        case .failed:
            return 1.35
        default:
            return 1.18
        }
    }

    private var statusPulseSize: CGFloat {
        switch item.status {
        case .failed:
            return 22
        default:
            return 20
        }
    }

    private var statusPulseOpacity: Double {
        switch item.status {
        case .starting:
            return 0.62
        case .running:
            return 0.76
        case .failed:
            return 0.88
        case .done:
            return 0
        }
    }

    private var statusGlowOpacity: Double {
        switch item.status {
        case .done:
            return 0.88
        case .failed:
            return 0.95
        default:
            return 0.72
        }
    }

    private var statusGlowRadius: CGFloat {
        switch item.status {
        case .done:
            return 5
        case .failed:
            return 7
        default:
            return 6
        }
    }

    private var statusCoreScale: CGFloat {
        guard shouldPulse else { return 1 }
        return isStatusAnimating ? 1.08 : 0.88
    }

    private var statusAccessibilityLabel: String {
        switch item.status {
        case .starting:
            return "Agent task is starting"
        case .running:
            return "Agent task is working"
        case .done:
            return "Agent task is done"
        case .failed:
            return "Agent task needs attention"
        }
    }
}

/// Three softly-pulsing dots used as a "thinking" affordance while the
/// agent has not produced its first streamed token yet. Replaces the
/// previous static "An agent is working on this." string.
private struct ClickyThinkingDots: View {
    let tint: Color
    @State private var phase: Int = 0
    /// Stored handle for the phase-cycling task so we can cancel it in
    /// `onDisappear`. Without this, every remount of the view (dock
    /// hide/show, hover-card toggle) leaks another infinite task.
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint.opacity(opacity(for: index)))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            // Cancel any prior task before starting a fresh one — guards
            // against duplicate `onAppear` events during transitions.
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

private struct ClickyAgentDockHoverCard: View {
    let item: ClickyAgentDockItem
    let canOpenDashboard: Bool
    let chat: () -> Void
    let text: () -> Void
    let voice: () -> Void
    /// Stops/removes only this agent (session + dock row + HUD tab). Does not hide the whole dock.
    let closeThisAgent: () -> Void
    /// Minimize the dock panel without removing agents.
    let hideDock: () -> Void
    let stop: () -> Void
    /// Called when the user taps "Close" on a terminal (`.done`/`.failed`)
    /// agent. Distinct from `stop` (which sends a cancel signal) — this
    /// just removes the dock item visually.
    let dismiss: () -> Void
    let dockDragBegan: () -> Void
    let dockDragChanged: (CGSize) -> Void
    let dockDragEnded: () -> Void
    @State private var isConfirmingStop = false
    @State private var dockCardDragHasMoved = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(item.accentTheme.cursorColor.opacity(0.85))
                .frame(width: 3)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .frame(width: 14)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged(cardDockDragChanged)
                        .onEnded { _ in cardDockDragEnded() }
                )
                .pointerCursor()

                VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(action: closeThisAgent) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(
                            DSIconButtonStyle(
                                size: 28,
                                isDestructiveOnHover: false,
                                tooltipText: "Close this agent",
                                tooltipAlignment: .trailing
                            )
                        )
                    }

                    AgentStatusPill(
                        title: statusText,
                        subtitle: nil,
                        indicatorColor: dockStatusIndicatorColor
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text("Drag here or the left edge to move the dock")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Colors.surface3.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.8), lineWidth: 1)
                    )
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged(cardDockDragChanged)
                            .onEnded { _ in cardDockDragEnded() }
                    )
                    .pointerCursor()
                }
                .padding(.bottom, 8)

                if hasDistinctUserInstruction {
                    dockWellSection(title: "Your request") {
                        Text(userInstructionDisplay)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 8)
                }

                dockWellSection(title: "Latest output") {
                    latestOutputContent
                }
                .padding(.bottom, 8)

                if hasSessionOutputs {
                    dockWellSection(title: "Session files") {
                        sessionFilesContent
                    }
                    .padding(.bottom, 8)
                }

                Rectangle()
                    .fill(DS.Colors.borderSubtle)
                    .frame(height: 1)
                    .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Follow up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text("Voice opens the mic on your cursor; a status strip appears above the dock while we listen.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        stopControls

                        Spacer(minLength: 10)

                        Button(action: voice) {
                            Label("Voice", systemImage: "mic")
                        }
                        .buttonStyle(ClickyAgentDockPillButtonStyle())

                        Button(action: text) {
                            Label("Text", systemImage: "text.cursor")
                        }
                        .buttonStyle(ClickyAgentDockPillButtonStyle())

                        if canOpenDashboard {
                            Button(action: chat) {
                                Label("Dashboard", systemImage: "rectangle.grid.2x2")
                            }
                            .buttonStyle(ClickyAgentDockPillButtonStyle())
                        }
                    }

                    Button(action: hideDock) {
                        Text("Hide dock")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary.opacity(0.95))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Hide the agent dock until the next task")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 512, alignment: .leading)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 6)
    }

    private func cardDockDragChanged(_ value: DragGesture.Value) {
        if !dockCardDragHasMoved {
            dockCardDragHasMoved = true
            dockDragBegan()
        }
        dockDragChanged(value.translation)
    }

    private func cardDockDragEnded() {
        dockCardDragHasMoved = false
        dockDragEnded()
    }

    private func dockWellSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(DS.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var latestOutputContent: some View {
        if let trimmedCaption,
           !trimmedCaption.isEmpty {
            Text(trimmedCaption)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(2)
                .lineLimit(6)
                .minimumScaleFactor(0.88)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let linkTarget {
                Button {
                    NSWorkspace.shared.open(linkTarget)
                } label: {
                    Label(linkButtonTitle(for: linkTarget), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(ClickyAgentDockPillButtonStyle())
                .padding(.top, 4)
            }
        } else {
            switch item.status {
            case .starting, .running:
                ClickyThinkingDots(tint: item.accentTheme.cursorColor)
            case .done:
                Text("Done.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
            case .failed:
                Text("Needs attention.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.destructiveText)
            }
        }
    }

    private var hasDistinctUserInstruction: Bool {
        !userInstructionDisplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var userInstructionDisplay: String {
        item.userInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCaption: String? {
        item.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var stopControls: some View {
        // Once the agent is in a terminal state (.done / .failed), there's
        // nothing to cancel — show a clean "Close" button that dismisses
        // the dock item instead of the destructive Stop / Confirm-stop
        // affordance.
        switch item.status {
        case .done, .failed:
            Button(action: dismiss) {
                Label("Close", systemImage: "xmark.circle")
            }
            .buttonStyle(ClickyAgentDockPillButtonStyle())
        case .starting, .running:
            if isConfirmingStop {
                Button {
                    isConfirmingStop = false
                    stop()
                } label: {
                    Label("Confirm stop", systemImage: "stop.circle.fill")
                }
                .buttonStyle(ClickyAgentDockStopButtonStyle(isConfirming: true))

                Button("Keep running") {
                    isConfirmingStop = false
                }
                .buttonStyle(ClickyAgentDockPillButtonStyle())
            } else {
                Button {
                    isConfirmingStop = true
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .buttonStyle(ClickyAgentDockStopButtonStyle(isConfirming: false))
            }
        }
    }

    private var linkTarget: URL? {
        // Only scan the live caption — the previous version scanned the
        // canned "An agent is working on this." fallback, which never
        // contained a link anyway.
        Self.firstOpenableURL(in: item.caption ?? "")
    }

    private var hasSessionOutputs: Bool {
        let trimmedPath = item.sessionWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !item.artifactFileURLs.isEmpty || (!trimmedPath.isEmpty && item.sessionID != nil)
    }

    @ViewBuilder
    private var sessionFilesContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            let path = item.sessionWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, item.sessionID != nil {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Label("Session folder", systemImage: "folder")
                }
                .buttonStyle(ClickyAgentDockPillButtonStyle())
            }
            ForEach(Array(item.artifactFileURLs.prefix(10)), id: \.path) { url in
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(url.lastPathComponent, systemImage: "doc.text")
                        .lineLimit(1)
                }
                .buttonStyle(ClickyAgentDockPillButtonStyle())
            }
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
            if raw.hasPrefix("file://"), let url = URL(string: raw) {
                return url
            }
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                return URL(string: raw)
            }
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw)
            }
        }
        return nil
    }

    private var displayTitle: String {
        let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Agent" : trimmedTitle
    }

    private var statusText: String {
        switch item.status {
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }

    private var dockStatusIndicatorColor: Color {
        switch item.status {
        case .starting, .running:
            return DS.Colors.warning
        case .done:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructiveText
        }
    }
}

private struct ClickyAgentDockStopButtonStyle: ButtonStyle {
    let isConfirming: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isConfirming ? Color.white : Color(hex: "#FFB4BA"))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isConfirming ? Color(hex: "#B91C1C").opacity(configuration.isPressed ? 0.95 : 0.82) : Color(hex: "#7F1D1D").opacity(isHovered ? 0.38 : 0.22))
            )
            .overlay(
                Capsule()
                    .stroke(Color(hex: "#FF6369").opacity(isHovered || isConfirming ? 0.50 : 0.28), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .pointerCursor()
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

private struct ClickyAgentDockPillButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(
                        DS.Colors.surface2.opacity(configuration.isPressed ? 1.0 : (isHovered ? 1.0 : 0.92))
                    )
            )
            .overlay(
                Capsule()
                    .stroke(DS.Colors.borderSubtle.opacity(isHovered ? 1.0 : 0.85), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .pointerCursor()
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

private final class ClickyAgentDockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClickyAgentDockWindowManager {
    private var panel: NSPanel?
    private var dragStartFrame: NSRect?
    private var customFrame: NSRect?
    private let dockSize = NSSize(width: 860, height: 480)
    private let hoverCardWidth: CGFloat = 512
    // Track the icon container size used by `ClickyAgentDockItemView`. Used
    // by `textFollowUpOrigin()` to position follow-up popovers relative to
    // the icon's actual width.
    private let dockIconWidth: CGFloat = 92
    // Trailing inset between the dock icon and the panel's right edge.
    // Reduced together with the SwiftUI inner paddings so the icon sits
    // closer to the screen corner.
    private let dockTrailingInset: CGFloat = 4
    private let dockItemSpacing: CGFloat = 22

    func show(
        companionManager: CompanionManager,
        onScreen screen: NSScreen,
        position: AgentParkingPosition
    ) {
        if panel == nil {
            createPanel(companionManager: companionManager)
        }

        if let customFrame {
            panel?.setFrame(customFrame, display: true)
        } else {
            positionPanel(onScreen: screen, position: position)
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func beginDrag() {
        dragStartFrame = panel?.frame
    }

    func drag(by translation: CGSize) {
        guard let panel, let dragStartFrame else { return }
        let frame = NSRect(
            x: dragStartFrame.origin.x + translation.width,
            y: dragStartFrame.origin.y - translation.height,
            width: dragStartFrame.width,
            height: dragStartFrame.height
        )
        panel.setFrame(frame, display: true)
        customFrame = frame
    }

    func endDrag() {
        customFrame = panel?.frame ?? customFrame
        dragStartFrame = nil
    }

    func textFollowUpOrigin() -> CGPoint? {
        guard let panel else { return nil }
        let frame = panel.frame
        let hoverCardLeftX = frame.maxX - dockTrailingInset - dockIconWidth - dockItemSpacing - hoverCardWidth
        return CGPoint(
            x: hoverCardLeftX,
            y: frame.minY - 62
        )
    }

    private func createPanel(companionManager: CompanionManager) {
        let dockPanel = ClickyAgentDockPanel(
            contentRect: NSRect(origin: .zero, size: dockSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        dockPanel.isOpaque = false
        dockPanel.backgroundColor = .clear
        dockPanel.level = .screenSaver
        dockPanel.hasShadow = false
        dockPanel.hidesOnDeactivate = false
        dockPanel.isReleasedWhenClosed = false
        dockPanel.isMovable = false
        dockPanel.isMovableByWindowBackground = false
        dockPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let rootView = ClickyAgentDockStackView(companionManager: companionManager)
            .frame(width: dockSize.width, height: dockSize.height, alignment: .topTrailing)
        let hostingView = NSHostingView(rootView: rootView)
        if #available(macOS 13.0, *) {
            // Critical: keep SwiftUI from driving the NSPanel's size from
            // its ideal content size. Hover cards/caption changes animate
            // the SwiftUI tree frequently; when the hosting view is the
            // window contentView, AppKit can enter a recursive constraints
            // pass and throw NSGenericException. A fixed AppKit container
            // owns the panel size; SwiftUI only draws inside it.
            hostingView.sizingOptions = []
        }
        let containerView = NSView(frame: NSRect(origin: .zero, size: dockSize))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)
        dockPanel.contentView = containerView
        panel = dockPanel
    }

    private func positionPanel(onScreen screen: NSScreen, position: AgentParkingPosition) {
        guard let panel else { return }
        // Keep the previous extra top padding for top-anchored positions
        // (notification banners + menu bar leave less usable area at the
        // top), and use a smaller default elsewhere.
        let edgeInset: CGFloat
        switch position {
        case .topLeft, .topCenter, .topRight:
            edgeInset = max(56, screen.frame.maxY - screen.visibleFrame.maxY + 56)
        default:
            edgeInset = 16
        }
        let origin = position.originForWindow(size: dockSize, on: screen, edgeInset: edgeInset)
        let targetFrame = NSRect(origin: origin, size: dockSize)
        guard panel.frame.integral != targetFrame.integral else { return }
        panel.setFrame(targetFrame, display: true)
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}
