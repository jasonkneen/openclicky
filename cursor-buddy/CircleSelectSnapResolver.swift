//
//  CircleSelectSnapResolver.swift
//  OpenClicky
//
//  After the user freehand-circles a region, resolve the tightest useful
//  target (AX element or CG window) inside that path so the selection can
//  snap and hold until push-to-talk is released.
//

import AppKit
import ApplicationServices
import Foundation

struct CircleSelectSnapResult: Equatable, Sendable {
    var rect: CGRect
    var label: String
    var source: String
    var role: String?
}

enum CircleSelectSnapResolver {
    private static let maxAXNodes = 400
    private static let maxAXDepth = 10
    private static let minElementSide: CGFloat = 18
    private static let maxElementAreaFraction: CGFloat = 0.92
    private static let minOverlapFraction: CGFloat = 0.22
    private static let snapPadding: CGFloat = 6

    /// Prefer a concrete UI target inside `pathBounds` (optionally guided by partial speech).
    static func resolveSnap(
        pathPoints: [CGPoint],
        pathBounds: CGRect,
        partialTranscript: String?
    ) -> CircleSelectSnapResult? {
        guard pathBounds.width >= minElementSide, pathBounds.height >= minElementSide else { return nil }

        let pathArea = max(pathBounds.width * pathBounds.height, 1)
        let speechTokens = meaningfulTokens(from: partialTranscript)

        var candidates: [ScoredCandidate] = []
        candidates.append(contentsOf: accessibilityCandidates(
            pathPoints: pathPoints,
            pathBounds: pathBounds,
            pathArea: pathArea,
            speechTokens: speechTokens
        ))
        candidates.append(contentsOf: windowCandidates(
            pathBounds: pathBounds,
            pathArea: pathArea,
            speechTokens: speechTokens
        ))

        guard let best = candidates.max(by: { $0.score < $1.score }), best.score >= 0.35 else {
            return nil
        }

        let padded = best.rect.insetBy(dx: -snapPadding, dy: -snapPadding)
        let screen = NSScreen.screen(containingOrNearestTo: CGPoint(x: padded.midX, y: padded.midY))
        let clamped = screen.map { padded.intersection($0.frame) } ?? padded
        guard clamped.width >= minElementSide, clamped.height >= minElementSide else { return nil }

        return CircleSelectSnapResult(
            rect: clamped,
            label: best.label,
            source: best.source,
            role: best.role
        )
    }

    // MARK: - Accessibility

    private struct ScoredCandidate {
        var rect: CGRect
        var label: String
        var source: String
        var role: String?
        var score: Double
    }

    private static func accessibilityCandidates(
        pathPoints: [CGPoint],
        pathBounds: CGRect,
        pathArea: CGFloat,
        speechTokens: Set<String>
    ) -> [ScoredCandidate] {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return []
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var nodesVisited = 0
        var results: [ScoredCandidate] = []

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maxAXDepth, nodesVisited < maxAXNodes else { return }
            nodesVisited += 1

            if let frame = axFrameInAppKitCoordinates(element),
               frame.width >= minElementSide,
               frame.height >= minElementSide {
                let intersection = frame.intersection(pathBounds)
                if !intersection.isNull, intersection.width > 1, intersection.height > 1 {
                    let elementArea = max(frame.width * frame.height, 1)
                    // Skip near-full-window chrome that just swallows the circle.
                    if elementArea / pathArea <= (1.0 / maxElementAreaFraction)
                        || pathArea / elementArea >= 0.15 {
                        let role = axString(element, attribute: kAXRoleAttribute as String) ?? ""
                        let title = [
                            axString(element, attribute: kAXTitleAttribute as String),
                            axString(element, attribute: kAXDescriptionAttribute as String),
                            axString(element, attribute: kAXValueAttribute as String)
                        ]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }

                        let score = scoreCandidate(
                            frame: frame,
                            pathPoints: pathPoints,
                            pathBounds: pathBounds,
                            pathArea: pathArea,
                            role: role,
                            title: title,
                            speechTokens: speechTokens
                        )
                        if score > 0 {
                            let label = title.map { shortLabel($0) }
                                ?? shortLabel(role.replacingOccurrences(of: "AX", with: ""))
                            results.append(
                                ScoredCandidate(
                                    rect: frame,
                                    label: label,
                                    source: "accessibility",
                                    role: role,
                                    score: score
                                )
                            )
                        }
                    }
                }
            }

            guard depth < maxAXDepth else { return }
            for child in axChildren(element) {
                visit(child, depth: depth + 1)
            }
        }

        // Prefer focused window first for speed/relevance.
        if let focused = axFocusedWindow(appElement) {
            visit(focused, depth: 0)
        } else {
            visit(appElement, depth: 0)
        }

        return results
    }

    private static func windowCandidates(
        pathBounds: CGRect,
        pathArea: CGFloat,
        speechTokens: Set<String>
    ) -> [ScoredCandidate] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = OpenClickyComputerUseWindowEnumerator.visibleWindows()
            .filter { $0.pid != ownPID && $0.isOnScreen && $0.layer == 0 }

        return windows.compactMap { window in
            // CGWindowList bounds use top-left origin; convert to AppKit.
            let frame = CGRect(
                x: window.bounds.x,
                y: globalAppKitY(fromAXY: CGFloat(window.bounds.y), height: CGFloat(window.bounds.height)),
                width: window.bounds.width,
                height: window.bounds.height
            )
            let intersection = frame.intersection(pathBounds)
            guard !intersection.isNull, intersection.width > 8, intersection.height > 8 else {
                return nil
            }
            let overlap = (intersection.width * intersection.height) / pathArea
            guard overlap >= minOverlapFraction else { return nil }

            let title = window.name
            var score = Double(overlap) * 0.55
            // Prefer windows that are smaller than the path (contained content)
            // over giant desktop windows that merely intersect.
            let windowArea = max(frame.width * frame.height, 1)
            if windowArea <= pathArea * 1.35 {
                score += 0.2
            } else {
                score -= 0.15
            }
            score += speechBoost(title: title, tokens: speechTokens)
            guard score >= 0.35 else { return nil }
            return ScoredCandidate(
                rect: intersection.width * intersection.height > pathArea * 0.5 ? frame.intersection(pathBounds.insetBy(dx: -4, dy: -4)) : frame,
                label: shortLabel(title.isEmpty ? window.owner : title),
                source: "window",
                role: "window",
                score: score
            )
        }
    }

    private static func scoreCandidate(
        frame: CGRect,
        pathPoints: [CGPoint],
        pathBounds: CGRect,
        pathArea: CGFloat,
        role: String,
        title: String?,
        speechTokens: Set<String>
    ) -> Double {
        let intersection = frame.intersection(pathBounds)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let elementArea = max(frame.width * frame.height, 1)

        let coverageOfPath = intersectionArea / pathArea
        let coverageOfElement = intersectionArea / elementArea
        guard coverageOfPath >= minOverlapFraction || coverageOfElement >= 0.45 else { return 0 }

        // Prefer elements mostly inside the freehand region.
        var score = Double(coverageOfElement) * 0.55 + Double(coverageOfPath) * 0.25

        let center = CGPoint(x: frame.midX, y: frame.midY)
        if pathContains(center, points: pathPoints) || pathBounds.insetBy(dx: 8, dy: 8).contains(center) {
            score += 0.18
        }

        let roleBoost: Double = {
            let r = role.lowercased()
            if r.contains("image") || r.contains("button") || r.contains("link") { return 0.16 }
            if r.contains("statictext") || r.contains("text") || r.contains("heading") { return 0.12 }
            if r.contains("group") || r.contains("cell") || r.contains("row") { return 0.08 }
            if r.contains("window") || r.contains("scrollarea") { return -0.08 }
            return 0.02
        }()
        score += roleBoost
        score += speechBoost(title: title, tokens: speechTokens)

        // Penalize enormous frames that dominate the screen.
        if elementArea > pathArea * 4 {
            score -= 0.25
        }

        return score
    }

    private static func speechBoost(title: String?, tokens: Set<String>) -> Double {
        guard !tokens.isEmpty, let title, !title.isEmpty else { return 0 }
        let titleTokens = meaningfulTokens(from: title)
        let overlap = tokens.intersection(titleTokens)
        if overlap.isEmpty { return 0 }
        return min(0.28, 0.08 * Double(overlap.count))
    }

    private static func meaningfulTokens(from text: String?) -> Set<String> {
        guard let text else { return [] }
        let stop: Set<String> = [
            "the", "a", "an", "this", "that", "these", "those", "what", "is", "are",
            "please", "show", "me", "look", "at", "about", "and", "or", "to", "of",
            "in", "on", "for", "with", "it", "my", "your", "can", "you", "here"
        ]
        return Set(
            text
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && !stop.contains($0) }
        )
    }

    private static func shortLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 42 { return trimmed }
        return String(trimmed.prefix(39)) + "..."
    }

    /// Ray-cast point-in-polygon for the freehand path (AppKit coords).
    ///
    /// This stays internal so the geometry can be exercised independently of
    /// Accessibility fixtures in focused tests.
    static func pathContains(_ point: CGPoint, points: [CGPoint]) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let pi = points[i]
            let pj = points[j]
            let crossesHorizontalRay = (pi.y > point.y) != (pj.y > point.y)
            // `crossesHorizontalRay` guarantees a non-zero denominator. Keep
            // its sign: replacing a descending edge's denominator with a
            // positive epsilon moves its intersection far off-screen.
            let intersects = crossesHorizontalRay
                && (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x)
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: - AX helpers

    private static func axFocusedWindow(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else {
            return []
        }
        return array
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String else {
            return nil
        }
        return string
    }

    private static func axFrameInAppKitCoordinates(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 1,
              size.height > 1 else {
            return nil
        }

        // Global AX Y increases downward from the top of the main display.
        // AppKit Y increases upward.
        let appKitY = globalAppKitY(fromAXY: position.y, height: size.height)
        return CGRect(x: position.x, y: appKitY, width: size.width, height: size.height)
    }

    /// Convert AX top-left Y + height into AppKit bottom-left Y using the
    /// menu-bar display as the shared global-coordinate origin.
    static func appKitY(
        fromAXY axY: CGFloat,
        height: CGFloat,
        menuBarScreenMaxY: CGFloat
    ) -> CGFloat {
        menuBarScreenMaxY - axY - height
    }

    /// Convert AX top-left Y + height into AppKit bottom-left Y.
    private static func globalAppKitY(fromAXY axY: CGFloat, height: CGFloat) -> CGFloat {
        // Accessibility coordinates use the top-left of the menu-bar display
        // as their global origin. AppKit's global origin is the lower-left of
        // that same display, so using the tallest/uppermost secondary screen
        // would offset every AX/CG window on asymmetric multi-display setups.
        let menuBarScreenMaxY = NSScreen.screens.first?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        return appKitY(
            fromAXY: axY,
            height: height,
            menuBarScreenMaxY: menuBarScreenMaxY
        )
    }
}
