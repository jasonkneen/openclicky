//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for the OpenClicky cursor companion.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
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

/// Cursor avatar styles.
///
/// Stored as a `String` (with embedded payload for `.pet`) so it round-trips
/// through `@AppStorage` and `UserDefaults` cleanly.
///
/// Legacy values:
///   - `"triangle"` (pre-fork single triangle) ➝ treated as `.triangleFilled`.
///   - `"paperclip"` (removed; was hardcoded clippy) ➝ falls back to default.
///   - `"customAsset"` (single static template image) ➝ falls back to default.
enum ClickyCursorAvatarStyle: Equatable {
    case triangleFilled
    case triangleOutline
    case pet(id: String)

    static let userDefaultsKey = "openclicky.cursorAvatarStyle"
    static let `default`: ClickyCursorAvatarStyle = .triangleFilled

    /// Storage representation. `.pet(id)` is encoded as `"pet:<id>"`.
    var storageValue: String {
        switch self {
        case .triangleFilled:    return "triangleFilled"
        case .triangleOutline:   return "triangleOutline"
        case .pet(let id):       return "pet:\(id)"
        }
    }

    init(storageValue raw: String) {
        switch raw {
        case "triangleFilled", "triangle", "":
            self = .triangleFilled
        case "triangleOutline":
            self = .triangleOutline
        // Legacy values we no longer support — fall back to default.
        case "paperclip", "customAsset":
            self = .triangleFilled
        default:
            if raw.hasPrefix("pet:") {
                let id = String(raw.dropFirst("pet:".count))
                if !id.isEmpty {
                    self = .pet(id: id)
                    return
                }
            }
            self = .triangleFilled
        }
    }

    /// Whether the parent view should apply rotation to this avatar.
    /// Triangles point in a direction; pets always face up and use their
    /// own running-left/running-right rows for direction.
    var honorsParentRotation: Bool {
        switch self {
        case .triangleFilled, .triangleOutline: return true
        case .pet:                              return false
        }
    }
}

private struct ClickyCursorAvatarView: View {
    let accentColor: Color
    var showsEyes: Bool = true
    /// High-level animation state used when rendering a pet. Ignored for
    /// triangle styles. Default is `.idle` so the existing call sites that
    /// don't have a state machine still render cleanly.
    var animationState: ClickyBuddyAnimationState = .idle
    @AppStorage(ClickyCursorAvatarStyle.userDefaultsKey) private var avatarStyleRawValue = ClickyCursorAvatarStyle.default.storageValue
    @ObservedObject private var petLibrary = ClickyBuddyPetLibrary.shared

    private var avatarStyle: ClickyCursorAvatarStyle {
        ClickyCursorAvatarStyle(storageValue: avatarStyleRawValue)
    }

    var body: some View {
        switch avatarStyle {
        case .triangleFilled:
            ClickyTriangleCursorView(accentColor: accentColor, style: .filled)
        case .triangleOutline:
            ClickyTriangleCursorView(accentColor: accentColor, style: .outline)
        case .pet(let id):
            if let pet = petLibrary.pet(withID: id) {
                ClickyPetSpriteView(pet: pet, animationState: animationState, haloColor: accentColor)
            } else {
                // Pet referenced but not installed (yet) — graceful fallback
                // keeps the cursor visible while the user re-picks or hatches.
                ClickyTriangleCursorView(accentColor: accentColor, style: .filled)
            }
        }
    }
}

private struct ClickyTriangleCursorView: View {
    enum Style { case filled, outline }
    let accentColor: Color
    let style: Style

    var body: some View {
        ZStack {
            switch style {
            case .filled:
                ClickyTriangleShape()
                    .fill(accentColor)
                    .shadow(color: accentColor.opacity(0.45), radius: 4)
            case .outline:
                ClickyTriangleShape()
                    .stroke(accentColor.opacity(0.34), style: StrokeStyle(lineWidth: 8.0, lineJoin: .round))
                    .blur(radius: 1.8)
                ClickyTriangleShape()
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 3.2, lineJoin: .round))
            }
        }
        .aspectRatio(0.86, contentMode: .fit)
    }
}

private struct ClickyTriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let size = min(rect.width, rect.height) * 0.82
        let height = size * sqrt(3.0) / 2.0
        let top = CGPoint(x: center.x, y: center.y + height * 0.56)
        let bottomLeft = CGPoint(x: center.x - size / 2.0, y: center.y - height * 0.44)
        let bottomRight = CGPoint(x: center.x + size / 2.0, y: center.y - height * 0.44)

        path.move(to: top)
        path.addLine(to: bottomLeft)
        path.addLine(to: bottomRight)
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

struct AgentTaskBubbleSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct ExternalProxyBubbleSizePreferenceKey: PreferenceKey {
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

// SwiftUI view for the glowing cursor companion.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// mascot when it is. During voice interaction, the mascot is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    let companionManager: CompanionManager
    @ObservedObject var cursorState: CursorOverlayState
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue

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
    /// High-priority background timer that drives cursor tracking. Held
    /// as a strong reference so the source isn't deallocated mid-tick.
    /// We sample on a `userInteractive` queue (not @MainActor) so the
    /// buddy stays smooth even when the main thread is busy with SwiftUI
    /// animation work or LLM streaming. Hops to main only when the cursor
    /// has actually moved.
    @State private var cursorTrackingTimer: DispatchSourceTimer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var agentTaskBubbleSize: CGSize = .zero
    @State private var externalProxyBubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the cursor companion in degrees.
    /// Changes to face the direction of travel when navigating to a target.
    @State private var buddyRotationDegrees: Double = 2.0

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

    /// Scale factor applied to the buddy mascot during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Pet animation state
    //
    // Only used when the user has picked a `.pet(...)` cursor avatar style.
    // Triangle styles ignore these.

    /// High-level animation state fed to `ClickyPetSpriteView`.
    @State private var petAnimationState: ClickyBuddyAnimationState = .idle

    /// Last horizontal cursor position used to estimate running direction.
    @State private var lastDirectionSampleX: CGFloat = 0
    /// Wall-clock time of the last running-row update — drives a small dwell
    /// hysteresis so tiny ↔ swap doesn't flip-flop the row every frame.
    @State private var lastRunningRowFlipAt: Date = .distantPast

    @AppStorage(ClickyCursorAvatarStyle.userDefaultsKey)
    private var avatarStyleRawValueForRotation = ClickyCursorAvatarStyle.default.storageValue

    /// True when the active avatar is rotation-aware (triangles).
    private var avatarHonorsRotation: Bool {
        ClickyCursorAvatarStyle(storageValue: avatarStyleRawValueForRotation).honorsParentRotation
    }

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
                    .opacity(bubbleOpacity)
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
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            if let externalPrimaryCaption = cursorState.externalPrimaryCaptionText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !externalPrimaryCaption.isEmpty,
               buddyIsVisibleOnThisScreen {
                externalCaption(
                    externalPrimaryCaption,
                    at: cursorPosition,
                    color: externalPrimaryCaptionColor
                )
            }

            ForEach(externalSecondaryCursorsOnThisScreen) { cursor in
                externalSecondaryCursor(cursor)
            }

            if shouldShowAgentTaskBubble,
               let agentTaskBubbleText = cursorState.agentTaskBubbleText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !agentTaskBubbleText.isEmpty {
                let bubblePosition = anchoredBubblePosition(
                    for: cursorPosition,
                    bubbleSize: agentTaskBubbleSize,
                    horizontalOffset: 12,
                    verticalOffset: 20
                )

                Text(agentTaskBubbleText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(overlayCursorColor.opacity(0.94))
                            .shadow(color: overlayCursorColor.opacity(0.48), radius: 8, x: 0, y: 0)
                    )
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: AgentTaskBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .position(x: bubblePosition.x, y: bubblePosition.y)
                    .opacity(cursorOpacity)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.16), value: cursorState.agentTaskBubbleText)
                    .onPreferenceChange(AgentTaskBubbleSizePreferenceKey.self) { newSize in
                        agentTaskBubbleSize = newSize
                    }
            }

            // Cursor companion — shown when idle or while TTS is playing (responding).
            // All three states (mascot, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            //
            // Rotation is applied conditionally: triangle styles point in their
            // direction of travel via rotation; pet sprites face up and use
            // their own running-left/running-right rows for direction instead.
            ClickyCursorAvatarView(
                accentColor: overlayCursorColor,
                animationState: petAnimationState
            )
                .frame(width: avatarHonorsRotation ? 25 : 48, height: avatarHonorsRotation ? 33 : 52)
                .rotationEffect(.degrees(avatarHonorsRotation ? buddyRotationDegrees : 0))
                .shadow(color: overlayCursorColor.opacity(0.86), radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen && (cursorState.voiceState == .idle || cursorState.voiceState == .responding) ? cursorOpacity : 0)
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
                    value: buddyRotationDegrees
                )
                // Recompute pet row whenever ANY relevant input changes —
                // covers navigation flights (cursorPosition is updated by
                // the bezier timer, not the mouse tracker) and state-only
                // transitions like processing or pointing.
                .onChange(of: cursorPosition) { _, newPos in
                    updatePetAnimationStateForCursorMotion(toX: newPos.x)
                }
                .onChange(of: buddyNavigationMode) { _, _ in
                    updatePetAnimationStateForCursorMotion(toX: cursorPosition.x)
                }
                .onChange(of: cursorState.voiceState) { _, _ in
                    updatePetAnimationStateForCursorMotion(toX: cursorPosition.x)
                }

            // Blue waveform — replaces the mascot while listening
            BlueCursorWaveformView(
                audioPowerLevel: cursorState.currentAudioPowerLevel,
                cursorColor: overlayCursorColor,
                isActive: buddyIsVisibleOnThisScreen && cursorState.voiceState == .listening
            )
                .opacity(buddyIsVisibleOnThisScreen && cursorState.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: cursorState.voiceState)

            // Blue spinner — shown while the AI is processing (transcription + Claude + waiting for TTS)
            BlueCursorSpinnerView(
                cursorColor: overlayCursorColor,
                isActive: buddyIsVisibleOnThisScreen && cursorState.voiceState == .processing
            )
                .opacity(buddyIsVisibleOnThisScreen && cursorState.voiceState == .processing ? cursorOpacity : 0)
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
            DispatchQueue.main.async {
                startNavigatingToCurrentDetectedLocationIfNeeded()
            }

            self.cursorOpacity = 1.0
        }
        .onDisappear {
            timer?.invalidate()
            cursorTrackingTimer?.cancel()
            cursorTrackingTimer = nil
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

    /// Whether the buddy mascot should be visible on this screen.
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

    private var shouldShowAgentTaskBubble: Bool {
        buddyIsVisibleOnThisScreen
            && buddyNavigationMode == .followingCursor
            && !showWelcome
            && cursorState.voiceState != .listening
            && cursorState.voiceState != .processing
    }

    private var externalPrimaryCaptionColor: Color {
        colorFromHex(cursorState.externalPrimaryCaptionAccentHex) ?? overlayCursorColor
    }

    private var externalSecondaryCursorsOnThisScreen: [OpenClickyExternalProxyCursor] {
        cursorState.externalSecondaryCursors.filter { cursor in
            screenFrame.contains(cursor.screenLocation)
        }
    }

    @ViewBuilder
    private func externalSecondaryCursor(_ cursor: OpenClickyExternalProxyCursor) -> some View {
        let local = convertScreenPointToSwiftUICoordinates(cursor.screenLocation)
        let position = CGPoint(x: local.x + 35, y: local.y + 25)
        let color = colorFromHex(cursor.accentHex) ?? overlayCursorColor
        ZStack {
            ClickyCursorAvatarView(accentColor: color, showsEyes: false)
                .frame(width: 23, height: 30)
                .rotationEffect(.degrees(2))
                .shadow(color: color.opacity(0.90), radius: 10, x: 0, y: 0)
                .position(position)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))

            if let caption = cursor.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
               !caption.isEmpty {
                externalCaption(caption, at: position, color: color)
            }
        }
        .animation(.spring(response: 0.16, dampingFraction: 0.72), value: cursor.screenLocation)
    }

    @ViewBuilder
    private func externalCaption(_ caption: String, at position: CGPoint, color: Color) -> some View {
        let bubblePosition = anchoredBubblePosition(
            for: position,
            bubbleSize: externalProxyBubbleSize,
            horizontalOffset: 12,
            verticalOffset: 20
        )

        Text(caption)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.95))
                    .shadow(color: color.opacity(0.48), radius: 8, x: 0, y: 0)
            )
            .frame(maxWidth: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: ExternalProxyBubbleSizePreferenceKey.self, value: geo.size)
                }
            )
            .position(x: bubblePosition.x, y: bubblePosition.y)
            .onPreferenceChange(ExternalProxyBubbleSizePreferenceKey.self) { newSize in
                externalProxyBubbleSize = newSize
            }
            .transition(.opacity.combined(with: .move(edge: .leading)))
            .animation(.easeOut(duration: 0.12), value: caption)
    }

    private func colorFromHex(_ rawHex: String?) -> Color? {
        guard let hex = rawHex?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    private func anchoredBubblePosition(
        for cursorPosition: CGPoint,
        bubbleSize: CGSize,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat
    ) -> CGPoint {
        let halfWidth = bubbleSize.width / 2
        let halfHeight = bubbleSize.height / 2
        let minMargin: CGFloat = 8

        var x = cursorPosition.x + horizontalOffset + halfWidth
        let maxX = screenFrame.width - halfWidth - minMargin
        let minX = halfWidth + minMargin

        if x > maxX {
            x = cursorPosition.x - horizontalOffset - halfWidth
        }
        x = min(max(x, minX), maxX)

        var y = cursorPosition.y + verticalOffset + halfHeight
        let maxY = screenFrame.height - halfHeight - minMargin
        let minY = halfHeight + minMargin
        y = min(max(y, minY), maxY)

        return CGPoint(x: x, y: y)
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

        updatePetAnimationStateForCursorMotion(toX: buddyX)
    }

    // MARK: - Pet animation state derivation

    /// Translates the buddy's full state (voice, navigation, cursor motion)
    /// into the right atlas row for the pet sprite. Called on every cursor
    /// position change AND on every navigation/voice state change so the
    /// pet stays in sync regardless of who's driving the position update
    /// (mouse tracker vs. bezier-flight timer).
    private func updatePetAnimationStateForCursorMotion(toX newX: CGFloat) {
        // Skip work entirely when the active avatar isn't a pet — the
        // triangle styles ignore animation state.
        guard !avatarHonorsRotation else { return }

        // Highest priority: thinking spinner shouldn't show running cycles.
        if cursorState.voiceState == .processing {
            setPetAnimationState(.review)
            lastDirectionSampleX = newX
            return
        }
        // Pointing-at-target is a stationary pose — wave at the target.
        if buddyNavigationMode == .pointingAtTarget {
            setPetAnimationState(.waving)
            lastDirectionSampleX = newX
            return
        }

        // Velocity drives direction whether we're following the cursor OR
        // flying along a bezier arc — both update `cursorPosition`. During
        // navigation the bezier timer ticks at 60fps so dx stays meaningful.
        let dx = newX - lastDirectionSampleX
        let now = Date()
        let deadZone: CGFloat = 1.5
        let minDwell: TimeInterval = 0.08
        let isFlying = buddyNavigationMode == .navigatingToTarget

        if abs(dx) < deadZone {
            // Mid-flight with no horizontal component (vertical arc, or
            // crest of the curve where dx briefly approaches 0) — fall back
            // to the generic running row so the sprite keeps looking active.
            if isFlying {
                if petAnimationState != .running {
                    setPetAnimationState(.running)
                }
            } else if now.timeIntervalSince(lastRunningRowFlipAt) > 0.6 {
                // Following cursor and cursor has been still for >0.6s.
                setPetAnimationState(.idle)
            }
        } else {
            let desired: ClickyBuddyAnimationState = dx > 0 ? .runningRight : .runningLeft
            if desired != petAnimationState,
               now.timeIntervalSince(lastRunningRowFlipAt) > minDwell {
                setPetAnimationState(desired)
                lastRunningRowFlipAt = now
            }
        }
        lastDirectionSampleX = newX
    }

    private func setPetAnimationState(_ next: ClickyBuddyAnimationState) {
        if petAnimationState != next {
            petAnimationState = next
        }
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
    /// to the specified destination. The mascot tilts toward its direction
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
            // A small offset makes the paperclip lean into rightward movement
            // instead of standing straight up during flight.
            self.buddyRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 18.0

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

        // Rotate back to default angle now that we've arrived
        buddyRotationDegrees = 2.0

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
        buddyRotationDegrees = 2.0
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

/// A small blue waveform that replaces the cursor companion while
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
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timelineContext in
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
        .animation(.linear(duration: 0.04), value: audioPowerLevel)
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

/// A small blue spinning indicator that replaces the cursor companion
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
    @State private var manuallyClosedExpandedItemIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
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
                            close: {
                                // Close should collapse this expanded hover panel
                                // immediately, even while the cursor is still
                                // over the dock icon. Keep the dock icon/task.
                                manuallyClosedExpandedItemIDs.insert(item.id)
                                hoveredItemID = nil
                            },
                            stop: { companionManager.stopAgentDockItem(item.id) },
                            dismiss: { companionManager.dismissAgentDockItem(item.id) },
                            runSuggestedAction: { actionTitle in
                                companionManager.runSuggestedNextAction(actionTitle)
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
                        if !isHovering {
                            // Re-enable expansion after the pointer leaves, so a
                            // later hover can open the panel again.
                            manuallyClosedExpandedItemIDs.remove(item.id)
                        }
                    }
                }
            }
        }
        .frame(width: 760, height: 500, alignment: .topTrailing)
        .padding(.top, 0)
        .padding(.trailing, 4)
        .animation(.easeOut(duration: 0.16), value: companionManager.agentDockItems)
    }

    private func shouldShowExpandedCard(for item: ClickyAgentDockItem) -> Bool {
        // Only expand on hover. Previously `.done` and `.failed` stayed
        // expanded automatically so users could read the final summary,
        // but per UX request 2026-04-28 the dock should be icon-only by
        // default — hovering reveals the full card.
        return hoveredItemID == item.id && !manuallyClosedExpandedItemIDs.contains(item.id)
    }
}

private struct ClickyAgentDockItemView: View {
    let item: ClickyAgentDockItem
    @State private var isStatusAnimating = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.82),
                            Color(hex: "#101827").opacity(0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                // Smaller icon (was 68×68) so the dock takes up less screen
                // real estate when collapsed — ties to UX request 2026-04-28.
                .frame(width: 52, height: 52)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.26),
                                    item.accentTheme.cursorColor.opacity(0.36),
                                    Color.white.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )
                )
                .shadow(color: item.accentTheme.cursorColor.opacity(0.34), radius: 24, x: 0, y: 11)
                .shadow(color: item.accentTheme.cursorColor.opacity(0.70), radius: 16, x: 0, y: 0)
                .shadow(color: Color.black.opacity(0.50), radius: 8, x: 0, y: 4)

            ClickyCursorAvatarView(accentColor: item.accentTheme.cursorColor)
                .frame(width: 25, height: 33)
                .rotationEffect(.degrees(2))
                .shadow(color: item.accentTheme.cursorColor.opacity(0.82), radius: 7, x: 0, y: 0)
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

private struct ClickyAgentDockConversationPreview: View {
    let item: ClickyAgentDockItem
    let canOpenDashboard: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            conversationBubble(
                label: "YOU",
                content: { userBubbleText },
                labelColor: Color(hex: "#FF7A9A"),
                backgroundColor: Color(hex: "#341214").opacity(0.96),
                borderColor: Color(hex: "#7F1D3A").opacity(0.42)
            )

            conversationBubble(
                label: "AGENT",
                content: { agentBubbleContent },
                labelColor: item.accentTheme.cursorColor.opacity(0.95),
                backgroundColor: item.accentTheme.cursorColor.opacity(0.12),
                borderColor: item.accentTheme.cursorColor.opacity(0.28)
            )
        }
        .frame(width: 430, alignment: .leading)
        .shadow(color: item.accentTheme.cursorColor.opacity(0.18), radius: 18, x: 0, y: 8)
        .shadow(color: Color.black.opacity(0.30), radius: 10, x: 0, y: 6)
    }

    private func conversationBubble<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content,
        labelColor: Color,
        backgroundColor: Color,
        borderColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundColor(labelColor)
                .kerning(0.4)

            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    /// The full user instruction — no clipping. The dock card width and
    /// `lineLimit(nil)` let it wrap so the user sees exactly what was sent.
    private var userBubbleText: some View {
        Text(fullUserInstruction)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Either the latest streamed assistant text, or a live "thinking"
    /// indicator while we wait for the first token. Never the canned
    /// "An agent is working on this." string.
    @ViewBuilder
    private var agentBubbleContent: some View {
        let trimmedCaption = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedCaption.isEmpty {
            switch item.status {
            case .starting, .running:
                ClickyThinkingDots(tint: item.accentTheme.cursorColor)
            case .done:
                Text("Done.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(item.accentTheme.cursorColor)
            case .failed:
                Text("Needs attention.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
            }
        } else {
            Text(trimmedCaption)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fullUserInstruction: String {
        let fullInstruction = item.userInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullInstruction.isEmpty { return fullInstruction }
        let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "hey there" : trimmedTitle
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
    let close: () -> Void
    let stop: () -> Void
    /// Called when the user taps "Dismiss" on a terminal (`.done`/`.failed`)
    /// agent. Distinct from `stop` (which sends a cancel signal) — this
    /// just removes the dock item visually.
    let dismiss: () -> Void
    let runSuggestedAction: (String) -> Void
    @State private var isConfirmingStop = false
    @State private var hoveredQuickAction: QuickAction? = nil
    @State private var statusLineCycleIndex = 0
    @State private var statusLineCycleTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(statusText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(statusTextColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(statusBackgroundColor))

                Text(displayTitle)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(item.accentTheme.cursorColor.opacity(0.95))
                    .kerning(1.4)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .padding(.trailing, 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("Stage: \(item.progressStageLabel)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                if let statusLine = currentStatusLine {
                    Text("\(statusLineLabel): \(statusLine)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            .padding(.top, 2)

            agentProgressContent
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                if !item.suggestedNextActions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(item.suggestedNextActions, id: \.self) { actionTitle in
                            Button(action: {
                                runSuggestedAction(actionTitle)
                            }) {
                                Text(actionTitle)
                            }
                            .buttonStyle(ClickyAgentDockPillButtonStyle())
                        }
                    }
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 10)
                    actionButtons
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(
                DSIconButtonStyle(
                    size: 28,
                    isDestructiveOnHover: false,
                    tooltipText: "Close",
                    tooltipAlignment: .trailing
                )
            )
            .offset(x: 8, y: -8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 500, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            item.accentTheme.cursorColor.opacity(0.18),
                            Color(hex: "#111827").opacity(0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(item.accentTheme.cursorColor.opacity(0.20), lineWidth: 1.2)
        )
        .shadow(color: item.accentTheme.cursorColor.opacity(0.24), radius: 18, x: 0, y: 8)
        .shadow(color: Color.black.opacity(0.42), radius: 10, x: 0, y: 6)
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
    private var agentProgressContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let trimmedCaption,
               !trimmedCaption.isEmpty {
                Text(trimmedCaption)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(5)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // No real activity yet — surface a thinking indicator
                // instead of the canned "An agent is working on this." line.
                switch item.status {
                case .starting, .running:
                    ClickyThinkingDots(tint: item.accentTheme.cursorColor)
                case .done:
                    Text("Done.")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(item.accentTheme.cursorColor)
                case .failed:
                    Text("Needs attention.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }

            HStack(spacing: 8) {
                if let linkTarget {
                    Button {
                        NSWorkspace.shared.open(linkTarget)
                    } label: {
                        Label(linkButtonTitle(for: linkTarget), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(ClickyAgentDockPillButtonStyle())
                }

                Spacer(minLength: 0)

                if item.status == .starting || item.status == .running {
                    Button {
                        isConfirmingStop = true
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(ClickyAgentDockStopButtonStyle(isConfirming: false))
                    .confirmationDialog("Stop this agent?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
                        Button("Stop", role: .destructive, action: stop)
                        Button("Keep running", role: .cancel) {}
                    }
                }
            }
        }
    }

    private var trimmedCaption: String? {
        guard let trimmed = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered == "checking the work" || lowered == "check the work" {
            return nil
        }
        return trimmed
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
            if lines.last != trimmed {
                lines.append(trimmed)
            }
        }
        return lines
    }

    private func restartStatusLineCycle() {
        statusLineCycleTask?.cancel()
        statusLineCycleTask = nil
        let lines = activityStatusLines
        statusLineCycleIndex = 0
        guard lines.count > 1 else { return }

        statusLineCycleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_900_000_000)
                if Task.isCancelled { return }
                let count = activityStatusLines.count
                guard count > 1 else { continue }
                withAnimation(.easeInOut(duration: 0.18)) {
                    statusLineCycleIndex = (statusLineCycleIndex + 1) % count
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            HoverExpandIconActionButton(icon: "mic", label: "Voice", isExpanded: hoveredQuickAction == .voice, action: voice)
                .onHover { hoveredQuickAction = $0 ? .voice : nil }
            HoverExpandIconActionButton(icon: "text.cursor", label: "Text", isExpanded: hoveredQuickAction == .text, action: text)
                .onHover { hoveredQuickAction = $0 ? .text : nil }
            if canOpenDashboard {
                HoverExpandIconActionButton(icon: "rectangle.grid.2x2", label: "Dashboard", isExpanded: hoveredQuickAction == .dashboard, action: chat)
                    .onHover { hoveredQuickAction = $0 ? .dashboard : nil }
            }
            if item.status == .done || item.status == .failed {
                Button(action: dismiss) { Label("Dismiss", systemImage: "trash") }
                    .buttonStyle(ClickyAgentDockPillButtonStyle())
            }
        }
    }

    private enum QuickAction { case voice, text, dashboard }

    private var linkTarget: URL? {
        // Only scan the live caption — the previous version scanned the
        // canned "An agent is working on this." fallback, which never
        // contained a link anyway.
        Self.firstOpenableURL(in: item.caption ?? "")
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
        return trimmedTitle.isEmpty ? "HEY THERE" : trimmedTitle.uppercased()
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

    private var statusTextColor: Color {
        switch item.status {
        case .starting, .running:
            return Color(hex: "#93C5FD")
        case .done:
            return item.accentTheme.cursorColor
        case .failed:
            return Color(hex: "#FF6369")
        }
    }

    private var statusBackgroundColor: Color {
        switch item.status {
        case .starting, .running:
            return Color(hex: "#1D4ED8").opacity(0.25)
        case .done:
            return item.accentTheme.cursorColor.opacity(0.24)
        case .failed:
            return DS.Colors.destructive.opacity(0.24)
        }
    }

}

private struct HoverExpandIconActionButton: View {
    let icon: String
    let label: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                if isExpanded { Text(label) }
            }
        }
        .buttonStyle(ClickyAgentDockPillButtonStyle())
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
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : (isHovered ? 0.14 : 0.10)))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isHovered ? 0.24 : 0.14), lineWidth: 1)
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
    private var dragStartMouseLocation: CGPoint?
    private var customFrame: NSRect?
    private let dockSize = NSSize(width: 800, height: 540)
    private let hoverCardWidth: CGFloat = 560
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
        dragStartMouseLocation = NSEvent.mouseLocation
    }

    func drag(by translation: CGSize) {
        guard let panel, let dragStartFrame else { return }
        let frame: NSRect
        if let dragStartMouseLocation {
            // Keep the dock visually locked to the cursor by computing deltas
            // from global mouse positions. This avoids SwiftUI gesture
            // translation lag when the panel itself is moving during drag.
            let currentMouseLocation = NSEvent.mouseLocation
            let dx = currentMouseLocation.x - dragStartMouseLocation.x
            let dy = currentMouseLocation.y - dragStartMouseLocation.y
            frame = NSRect(
                x: dragStartFrame.origin.x + dx,
                y: dragStartFrame.origin.y + dy,
                width: dragStartFrame.width,
                height: dragStartFrame.height
            )
        } else {
            frame = NSRect(
                x: dragStartFrame.origin.x + translation.width,
                y: dragStartFrame.origin.y - translation.height,
                width: dragStartFrame.width,
                height: dragStartFrame.height
            )
        }
        // Keep updates lightweight while dragging; AppKit redraws naturally
        // on the next pass and this reduces perceived "left behind" lag.
        panel.setFrame(frame, display: false)
        customFrame = frame
    }

    func endDrag() {
        customFrame = panel?.frame ?? customFrame
        dragStartFrame = nil
        dragStartMouseLocation = nil
    }

    /// When true, the dock was manually moved and should not auto-follow
    /// cursor screen changes until explicitly reset.
    var hasUserPinnedFrame: Bool {
        customFrame != nil
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
        var origin = position.originForWindow(size: dockSize, on: screen, edgeInset: edgeInset)
        // UX tweak (2026-05-01): move the default top-right parked dock
        // closer into the corner by nudging it up/right.
        if position == .topRight {
            origin.x += 70
            origin.y += 70
        }
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
