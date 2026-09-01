//
//  CircleSelectSnapResolver.swift
//  OpenClicky
//
//  After the user freehand-circles a region, resolve the tightest useful
//  target (AX element or CG window) inside that path so the selection can
//  snap and hold until push-to-talk is released.
//
//  The pure scoring/geometry lives in OCComputerUseCore
//  (CircleSelectSnapGeometry / CircleSelectSnapResult); this file owns the
//  Accessibility, NSScreen and CGWindowList probes that feed it.
//

import AppKit
import ApplicationServices
import Foundation
import OCComputerUseCore

enum CircleSelectSnapResolver {
    private typealias Geometry = CircleSelectSnapGeometry
    private typealias ScoredCandidate = CircleSelectSnapGeometry.ScoredCandidate

    private static let maxAXNodes = 400
    private static let maxAXDepth = 10

    /// Prefer a concrete UI target inside `pathBounds` (optionally guided by partial speech).
    static func resolveSnap(
        pathPoints: [CGPoint],
        pathBounds: CGRect,
        partialTranscript: String?
    ) -> CircleSelectSnapResult? {
        guard pathBounds.width >= Geometry.minElementSide, pathBounds.height >= Geometry.minElementSide else { return nil }

        let pathArea = max(pathBounds.width * pathBounds.height, 1)
        let speechTokens = Geometry.meaningfulTokens(from: partialTranscript)

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

        let padded = best.rect.insetBy(dx: -Geometry.snapPadding, dy: -Geometry.snapPadding)
        let screen = NSScreen.screen(containingOrNearestTo: CGPoint(x: padded.midX, y: padded.midY))
        let clamped = screen.map { padded.intersection($0.frame) } ?? padded
        guard clamped.width >= Geometry.minElementSide, clamped.height >= Geometry.minElementSide else { return nil }

        return CircleSelectSnapResult(
            rect: clamped,
            label: best.label,
            source: best.source,
            role: best.role
        )
    }

    // MARK: - Accessibility

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
               frame.width >= Geometry.minElementSide,
               frame.height >= Geometry.minElementSide {
                let intersection = frame.intersection(pathBounds)
                if !intersection.isNull, intersection.width > 1, intersection.height > 1 {
                    let elementArea = max(frame.width * frame.height, 1)
                    // Skip near-full-window chrome that just swallows the circle.
                    if elementArea / pathArea <= (1.0 / Geometry.maxElementAreaFraction)
                        || pathArea / elementArea >= 0.15 {
                        let role = axString(element, attribute: kAXRoleAttribute as String) ?? ""
                        let title = [
                            axString(element, attribute: kAXTitleAttribute as String),
                            axString(element, attribute: kAXDescriptionAttribute as String),
                            axString(element, attribute: kAXValueAttribute as String)
                        ]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }

                        let score = Geometry.scoreCandidate(
                            frame: frame,
                            pathPoints: pathPoints,
                            pathBounds: pathBounds,
                            pathArea: pathArea,
                            role: role,
                            title: title,
                            speechTokens: speechTokens
                        )
                        if score > 0 {
                            let label = title.map { Geometry.shortLabel($0) }
                                ?? Geometry.shortLabel(role.replacingOccurrences(of: "AX", with: ""))
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
            guard overlap >= Geometry.minOverlapFraction else { return nil }

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
            score += Geometry.speechBoost(title: title, tokens: speechTokens)
            guard score >= 0.35 else { return nil }
            return ScoredCandidate(
                rect: intersection.width * intersection.height > pathArea * 0.5 ? frame.intersection(pathBounds.insetBy(dx: -4, dy: -4)) : frame,
                label: Geometry.shortLabel(title.isEmpty ? window.owner : title),
                source: "window",
                role: "window",
                score: score
            )
        }
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

    /// Convert AX top-left Y + height into AppKit bottom-left Y.
    private static func globalAppKitY(fromAXY axY: CGFloat, height: CGFloat) -> CGFloat {
        // Accessibility coordinates use the top-left of the menu-bar display
        // as their global origin. AppKit's global origin is the lower-left of
        // that same display, so using the tallest/uppermost secondary screen
        // would offset every AX/CG window on asymmetric multi-display setups.
        let menuBarScreenMaxY = NSScreen.screens.first?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        return Geometry.appKitY(
            fromAXY: axY,
            height: height,
            menuBarScreenMaxY: menuBarScreenMaxY
        )
    }
}
