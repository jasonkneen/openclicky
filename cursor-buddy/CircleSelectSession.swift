//
//  CircleSelectSession.swift
//  OpenClicky
//
//  Samples a freehand trail while push-to-talk is held so the user can
//  circle something and talk in the same gesture. Default mode tracks mouse
//  movement only; optional mode requires the primary button while held.
//

import AppKit
import OCComputerUseCore
import Foundation

struct CircleSelectAmbientContext: Equatable, Sendable {
    var appName: String?
    var bundleIdentifier: String?
    var windowTitle: String?
    var documentPath: String?
    var pageURL: String?
    var appSkillSummary: String?

    var isEmpty: Bool {
        appName == nil
            && windowTitle == nil
            && documentPath == nil
            && pageURL == nil
            && (appSkillSummary?.isEmpty ?? true)
    }

    var summaryLine: String {
        var parts: [String] = []
        if let appName, !appName.isEmpty {
            if let windowTitle, !windowTitle.isEmpty {
                parts.append("App: \(appName) — \"\(windowTitle)\"")
            } else {
                parts.append("App: \(appName)")
            }
        } else if let windowTitle, !windowTitle.isEmpty {
            parts.append("Window: \(windowTitle)")
        }
        if let pageURL, !pageURL.isEmpty {
            parts.append("URL: \(pageURL)")
        }
        if let documentPath, !documentPath.isEmpty {
            parts.append("Document: \(documentPath)")
        }
        if let appSkillSummary, !appSkillSummary.isEmpty {
            parts.append(appSkillSummary)
        }
        return parts.joined(separator: "\n")
    }
}

struct CircleSelectSealedStroke: Equatable, Sendable {
    var points: [CGPoint]
    var screenFrame: CGRect
    var captureRect: CGRect
    var pathLength: CGFloat
    var ambient: CircleSelectAmbientContext
    var sealedAt: Date
    var snap: CircleSelectSnapResult?

    var startPositionInScreen: CGPoint {
        CGPoint(x: captureRect.minX, y: captureRect.minY)
    }

    var endPositionInScreen: CGPoint {
        CGPoint(x: captureRect.maxX, y: captureRect.maxY)
    }

    func handoffSelection(instruction: String) -> HandoffRegionSelection {
        var summary = ambient.summaryLine
        if let snap {
            let snapLine = "Snapped target: \(snap.label) (\(snap.source))"
            summary = summary.isEmpty ? snapLine : summary + "\n" + snapLine
        }
        return HandoffRegionSelection(
            startPositionInScreen: startPositionInScreen,
            endPositionInScreen: endPositionInScreen,
            screenFrame: screenFrame,
            comment: instruction,
            pathPoints: points,
            ambientSummary: summary
        )
    }

    func agentNote(instruction: String) -> String {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = [
            "User circled a screen region while speaking (\(points.count) path points, path length \(Int(pathLength.rounded())) pt).",
            "Bounding rect x:\(Int(captureRect.minX)) y:\(Int(captureRect.minY)) width:\(Int(captureRect.width)) height:\(Int(captureRect.height))."
        ]
        if let snap {
            parts.append("Snapped to \(snap.label) via \(snap.source).")
        }
        let ambientLine = ambient.summaryLine
        if !ambientLine.isEmpty {
            parts.append(ambientLine)
        }
        if !trimmedInstruction.isEmpty {
            parts.append("Instruction: \(trimmedInstruction)")
        }
        return parts.joined(separator: "\n")
    }
}

@MainActor
final class CircleSelectSession {
    nonisolated static let minimumPointCount = 8
    nonisolated static let minimumPathLength: CGFloat = 90
    nonisolated static let minimumCaptureSide: CGFloat = 24
    nonisolated static let capturePadding: CGFloat = 18
    nonisolated static let sampleMinDistance: CGFloat = 3.0
    nonisolated static let resampleSpacing: CGFloat = 4.0
    nonisolated static let smoothWindowRadius = 2

    nonisolated static let closeLoopDistance: CGFloat = 36
    nonisolated static let closeLoopMinPathLength: CGFloat = 140

    private(set) var isActive = false
    /// Raw samples (screen coords). Smoothing is applied when publishing/sealing.
    private(set) var livePoints: [CGPoint] = []
    /// Locked snap after a completed circle; held until PTT release.
    private(set) var lockedSnap: CircleSelectSnapResult?
    private var requireClick = false
    private var isPrimaryButtonDown = false
    /// CGEvent tap that can *consume* mouse events so the window under the
    /// trail does not receive clicks/drags/text selection during drawing.
    private var mouseEventTap: CFMachPort?
    private var mouseEventTapRunLoopSource: CFRunLoopSource?
    /// Fallback when the event tap cannot be created (still samples, but cannot swallow).
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var partialTranscriptProvider: (() -> String?)?
    private var onPointsChanged: (([CGPoint]) -> Void)?
    private var onSnapChanged: ((CircleSelectSnapResult?) -> Void)?

    func start(
        requireClick: Bool,
        partialTranscriptProvider: (() -> String?)? = nil,
        onPointsChanged: @escaping ([CGPoint]) -> Void,
        onSnapChanged: @escaping (CircleSelectSnapResult?) -> Void
    ) {
        stopSampling(clearPoints: true)
        self.requireClick = requireClick
        self.partialTranscriptProvider = partialTranscriptProvider
        self.onPointsChanged = onPointsChanged
        self.onSnapChanged = onSnapChanged
        isActive = true
        isPrimaryButtonDown = false
        livePoints = []
        lockedSnap = nil
        onPointsChanged([])
        onSnapChanged(nil)

        if !installMouseEventTap() {
            installFallbackNSEventMonitors()
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.circle_select.mouse_tap_unavailable",
                fields: ["fallback": "ns_event_monitor"]
            )
        }
    }

    @discardableResult
    func stop() -> CircleSelectSealedStroke? {
        // Final snap attempt if the user never lifted mid-hold.
        if lockedSnap == nil {
            attemptSnap(reason: "session_stop")
        }
        let sealed = sealIfValid()
        stopSampling(clearPoints: true)
        return sealed
    }

    func cancel() {
        stopSampling(clearPoints: true)
    }

    /// Re-score locked snap when live transcript updates (speech tokens improve match).
    func refreshSnapUsingLatestTranscript() {
        guard isActive, lockedSnap != nil else { return }
        // Keep the rect stable once locked; only improve the label if a better
        // speech-aware match shares essentially the same frame.
        guard let refreshed = resolveSnapFromCurrentPath() else { return }
        if framesRoughlyEqual(refreshed.rect, lockedSnap?.rect) {
            lockedSnap = refreshed
            onSnapChanged?(refreshed)
        }
    }

    private func stopSampling(clearPoints: Bool) {
        tearDownMouseEventTap()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        isActive = false
        isPrimaryButtonDown = false
        requireClick = false
        if clearPoints {
            livePoints = []
            lockedSnap = nil
            onPointsChanged?([])
            onSnapChanged?(nil)
        }
        onPointsChanged = nil
        onSnapChanged = nil
        partialTranscriptProvider = nil
    }

    // MARK: - Mouse event interception

    /// Installs a session-level CGEvent tap that samples the trail *and*
    /// swallows primary-button events so the underlying app never sees the
    /// click-drag used to draw the circle.
    @discardableResult
    private func installMouseEventTap() -> Bool {
        tearDownMouseEventTap()

        let monitoredTypes: [CGEventType] = [
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .mouseMoved
        ]
        let eventMask = monitoredTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let session = Unmanaged<CircleSelectSession>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            // Tap is installed on the main run loop; keep handling on MainActor.
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    session.handleMouseEventTap(eventType: eventType, event: event)
                }
            }
            var result: Unmanaged<CGEvent>? = Unmanaged.passUnretained(event)
            DispatchQueue.main.sync {
                result = session.handleMouseEventTap(eventType: eventType, event: event)
            }
            return result
        }

        // `.defaultTap` (not listen-only) so we can return nil and consume events.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        mouseEventTap = tap
        mouseEventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func tearDownMouseEventTap() {
        if let mouseEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseEventTapRunLoopSource, .commonModes)
            self.mouseEventTapRunLoopSource = nil
        }
        if let mouseEventTap {
            CGEvent.tapEnable(tap: mouseEventTap, enable: false)
            CFMachPortInvalidate(mouseEventTap)
            self.mouseEventTap = nil
        }
    }

    private func installFallbackNSEventMonitors() {
        let matching: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp
        ]

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: matching) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleNSEvent(event)
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: matching) { [weak self] event in
            // Local path can swallow events delivered to OpenClicky itself.
            guard let self else { return event }
            let consume = self.handleNSEvent(event)
            return consume ? nil : event
        }
    }

    /// CGEvent-tap entry. Returns `nil` to swallow the event (block the app under the cursor).
    private func handleMouseEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let mouseEventTap {
                CGEvent.tapEnable(tap: mouseEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isActive else {
            return Unmanaged.passUnretained(event)
        }

        let location = Self.appKitLocation(from: event)

        switch eventType {
        case .leftMouseDown:
            handlePrimaryDown(at: location)
            return nil // swallow — do not click/select under the trail
        case .leftMouseDragged:
            handlePrimaryDragged(at: location)
            return nil
        case .leftMouseUp:
            handlePrimaryUp(at: location)
            return nil
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            // Also block secondary/other buttons during circle mode so a
            // two-button gesture cannot still poke the window underneath.
            return nil
        case .mouseMoved:
            if !requireClick, lockedSnap == nil {
                append(point: location, force: false)
                if pathLooksClosed(Self.normalizedPath(livePoints)) {
                    attemptSnap(reason: "loop_closed")
                }
            }
            // Movement alone does not select; pass through.
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Fallback NSEvent path. Returns `true` when the local monitor should swallow.
    @discardableResult
    private func handleNSEvent(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        let location = NSEvent.mouseLocation

        switch event.type {
        case .leftMouseDown:
            handlePrimaryDown(at: location)
            return true
        case .leftMouseDragged:
            handlePrimaryDragged(at: location)
            return true
        case .leftMouseUp:
            handlePrimaryUp(at: location)
            return true
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return true
        case .mouseMoved:
            if !requireClick, lockedSnap == nil {
                append(point: location, force: false)
                if pathLooksClosed(Self.normalizedPath(livePoints)) {
                    attemptSnap(reason: "loop_closed")
                }
            }
            return false
        default:
            return false
        }
    }

    private func handlePrimaryDown(at location: CGPoint) {
        // A new drag after a locked snap starts a fresh circle.
        if lockedSnap != nil {
            livePoints = []
            lockedSnap = nil
            onSnapChanged?(nil)
            onPointsChanged?([])
        }
        isPrimaryButtonDown = true
        if requireClick {
            append(point: location, force: true)
        }
    }

    private func handlePrimaryDragged(at location: CGPoint) {
        guard isPrimaryButtonDown else { return }
        append(point: location, force: false)
        if lockedSnap == nil, pathLooksClosed(Self.normalizedPath(livePoints)) {
            attemptSnap(reason: "loop_closed")
        }
    }

    private func handlePrimaryUp(at location: CGPoint) {
        if isPrimaryButtonDown {
            append(point: location, force: false)
        }
        isPrimaryButtonDown = false
        // Click-drag completed: snap to the best target and hold until PTT release.
        attemptSnap(reason: "mouse_up")
    }

    /// CGEvent.location is Quartz global (bottom-left origin) — same space as NSEvent.mouseLocation.
    private nonisolated static func appKitLocation(from event: CGEvent) -> CGPoint {
        event.location
    }

    private func append(point: CGPoint, force: Bool) {
        // Once snapped, freeze the freehand trail until release or a new drag.
        guard lockedSnap == nil else { return }
        if let last = livePoints.last, !force {
            let dx = point.x - last.x
            let dy = point.y - last.y
            if (dx * dx + dy * dy) < (Self.sampleMinDistance * Self.sampleMinDistance) {
                return
            }
        }
        livePoints.append(point)
        onPointsChanged?(Self.normalizedPath(livePoints))
    }

    private func attemptSnap(reason: String) {
        guard lockedSnap == nil else { return }
        guard let snap = resolveSnapFromCurrentPath() else { return }
        lockedSnap = snap
        onSnapChanged?(snap)
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.circle_select.snapped",
            fields: [
                "reason": reason,
                "label": snap.label,
                "source": snap.source,
                "width": Int(snap.rect.width.rounded()),
                "height": Int(snap.rect.height.rounded())
            ]
        )
    }

    private func resolveSnapFromCurrentPath() -> CircleSelectSnapResult? {
        let smoothed = Self.normalizedPath(livePoints)
        guard smoothed.count >= Self.minimumPointCount else { return nil }
        let pathLength = Self.pathLength(of: smoothed)
        guard pathLength >= Self.minimumPathLength else { return nil }
        guard let bounds = Self.rawBounds(of: smoothed) else { return nil }
        return CircleSelectSnapResolver.resolveSnap(
            pathPoints: smoothed,
            pathBounds: bounds,
            partialTranscript: partialTranscriptProvider?()
        )
    }

    private func pathLooksClosed(_ points: [CGPoint]) -> Bool {
        guard points.count >= Self.minimumPointCount,
              let first = points.first,
              let last = points.last else { return false }
        let length = Self.pathLength(of: points)
        guard length >= Self.closeLoopMinPathLength else { return false }
        return hypot(last.x - first.x, last.y - first.y) <= Self.closeLoopDistance
    }

    private func framesRoughlyEqual(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.midX - b.midX) < 12
            && abs(a.midY - b.midY) < 12
            && abs(a.width - b.width) < 24
            && abs(a.height - b.height) < 24
    }

    private func sealIfValid() -> CircleSelectSealedStroke? {
        let smoothed = Self.normalizedPath(livePoints)
        guard smoothed.count >= Self.minimumPointCount else { return nil }

        let pathLength = Self.pathLength(of: smoothed)
        guard pathLength >= Self.minimumPathLength else { return nil }

        guard var bounds = Self.rawBounds(of: smoothed) else { return nil }
        if bounds.width < Self.minimumCaptureSide {
            let extra = (Self.minimumCaptureSide - bounds.width) / 2
            bounds = bounds.insetBy(dx: -extra, dy: 0)
        }
        if bounds.height < Self.minimumCaptureSide {
            let extra = (Self.minimumCaptureSide - bounds.height) / 2
            bounds = bounds.insetBy(dx: 0, dy: -extra)
        }
        bounds = bounds.insetBy(dx: -Self.capturePadding, dy: -Self.capturePadding)

        // Prefer locked intelligent snap for the capture region.
        if let snap = lockedSnap {
            bounds = snap.rect.insetBy(dx: -Self.capturePadding * 0.5, dy: -Self.capturePadding * 0.5)
        }

        let screen = NSScreen.screen(containingOrNearestTo: CGPoint(x: bounds.midX, y: bounds.midY))
            ?? NSScreen.main
        let screenFrame = screen?.frame ?? bounds
        let captureRect = bounds.intersection(screenFrame)
        guard captureRect.width >= Self.minimumCaptureSide, captureRect.height >= Self.minimumCaptureSide else {
            return nil
        }

        var ambient = Self.captureAmbientContext()
        if let snap = lockedSnap {
            // Surface the snapped item as ambient window/context when useful.
            if ambient.windowTitle == nil || ambient.windowTitle?.isEmpty == true {
                ambient.windowTitle = snap.label
            }
        }

        return CircleSelectSealedStroke(
            points: smoothed,
            screenFrame: screenFrame,
            captureRect: captureRect,
            pathLength: pathLength,
            ambient: ambient,
            sealedAt: Date(),
            snap: lockedSnap
        )
    }

    nonisolated private static func pathLength(of points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var length: CGFloat = 0
        for index in 1..<points.count {
            length += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        return length
    }

    nonisolated private static func rawBounds(of points: [CGPoint]) -> CGRect? {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return nil
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Even spacing + light moving-average smooth so freehand circles look intentional.
    nonisolated static func normalizedPath(_ rawPoints: [CGPoint]) -> [CGPoint] {
        guard rawPoints.count >= 2 else { return rawPoints }
        let resampled = resample(rawPoints, spacing: resampleSpacing)
        return smooth(resampled, windowRadius: smoothWindowRadius)
    }

    nonisolated static func resample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count >= 2, spacing > 0 else { return points }

        var cumulative: [CGFloat] = [0]
        cumulative.reserveCapacity(points.count)
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            cumulative.append(cumulative[index - 1] + hypot(current.x - previous.x, current.y - previous.y))
        }
        let totalLength = cumulative[cumulative.count - 1]
        guard totalLength >= spacing else { return points }

        var result: [CGPoint] = [points[0]]
        var target = spacing
        var segmentIndex = 0
        while target < totalLength - 0.001 {
            while segmentIndex < cumulative.count - 2, cumulative[segmentIndex + 1] < target {
                segmentIndex += 1
            }
            let startDistance = cumulative[segmentIndex]
            let endDistance = cumulative[segmentIndex + 1]
            let span = max(endDistance - startDistance, 0.0001)
            let t = (target - startDistance) / span
            let start = points[segmentIndex]
            let end = points[segmentIndex + 1]
            result.append(
                CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
            )
            target += spacing
        }
        if let last = points.last {
            result.append(last)
        }
        return result
    }

    nonisolated static func smooth(_ points: [CGPoint], windowRadius: Int) -> [CGPoint] {
        guard points.count > 2, windowRadius > 0 else { return points }
        var smoothed: [CGPoint] = []
        smoothed.reserveCapacity(points.count)
        for index in points.indices {
            let lower = max(0, index - windowRadius)
            let upper = min(points.count - 1, index + windowRadius)
            var sumX: CGFloat = 0
            var sumY: CGFloat = 0
            var weightSum: CGFloat = 0
            for neighbor in lower...upper {
                // Keep endpoints sticky so the stroke doesn't shrink.
                let weight: CGFloat = (index == 0 || index == points.count - 1) ? 1 : CGFloat(windowRadius + 1 - abs(neighbor - index))
                sumX += points[neighbor].x * weight
                sumY += points[neighbor].y * weight
                weightSum += weight
            }
            if index == 0 || index == points.count - 1 {
                smoothed.append(points[index])
            } else {
                smoothed.append(CGPoint(x: sumX / weightSum, y: sumY / weightSum))
            }
        }
        return smoothed
    }

    static func captureAmbientContext() -> CircleSelectAmbientContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownBundle = Bundle.main.bundleIdentifier
        let appName = frontmost?.bundleIdentifier == ownBundle ? nil : frontmost?.localizedName
        let bundleIdentifier = frontmost?.bundleIdentifier == ownBundle ? nil : frontmost?.bundleIdentifier

        var windowTitle: String?
        if let window = OpenClickyComputerUseWindowEnumerator.frontmostTargetWindow() {
            let title = window.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                windowTitle = title
            }
        }

        let skill = OpenClickyAppSkillContext.contextForFrontmostApplication(excluding: ownBundle)
        let skillSummary = skill.map { context in
            "Active app skill: \(context.appName) — \(context.tagline)"
        }

        return CircleSelectAmbientContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            documentPath: nil,
            pageURL: nil,
            appSkillSummary: skillSummary
        )
    }
}
