//
//  CircleSelectSnapGeometry.swift
//  OCComputerUseCore
//
//  Pure geometry and text scoring for circle-select snapping: ray-cast
//  containment, AX-to-AppKit Y conversion, candidate scoring and label
//  shaping. The Accessibility / CGWindowList probes that produce candidates
//  live in the host app (CircleSelectSnapResolver).
//

import CoreGraphics
import Foundation

public struct CircleSelectSnapResult: Equatable, Sendable {
    public var rect: CGRect
    public var label: String
    public var source: String
    public var role: String?

    public init(rect: CGRect, label: String, source: String, role: String?) {
        self.rect = rect
        self.label = label
        self.source = source
        self.role = role
    }
}

public enum CircleSelectSnapGeometry {
    public static let minElementSide: CGFloat = 18
    public static let maxElementAreaFraction: CGFloat = 0.92
    public static let minOverlapFraction: CGFloat = 0.22
    public static let snapPadding: CGFloat = 6

    public struct ScoredCandidate {
        public var rect: CGRect
        public var label: String
        public var source: String
        public var role: String?
        public var score: Double

        public init(rect: CGRect, label: String, source: String, role: String?, score: Double) {
            self.rect = rect
            self.label = label
            self.source = source
            self.role = role
            self.score = score
        }
    }

    public static func scoreCandidate(
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

    public static func speechBoost(title: String?, tokens: Set<String>) -> Double {
        guard !tokens.isEmpty, let title, !title.isEmpty else { return 0 }
        let titleTokens = meaningfulTokens(from: title)
        let overlap = tokens.intersection(titleTokens)
        if overlap.isEmpty { return 0 }
        return min(0.28, 0.08 * Double(overlap.count))
    }

    public static func meaningfulTokens(from text: String?) -> Set<String> {
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

    public static func shortLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 42 { return trimmed }
        return String(trimmed.prefix(39)) + "..."
    }

    /// Ray-cast point-in-polygon for the freehand path (AppKit coords).
    ///
    /// Internal so the geometry can be exercised independently of
    /// Accessibility fixtures in focused package tests.
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

    /// Convert AX top-left Y + height into AppKit bottom-left Y using the
    /// menu-bar display as the shared global-coordinate origin.
    public static func appKitY(
        fromAXY axY: CGFloat,
        height: CGFloat,
        menuBarScreenMaxY: CGFloat
    ) -> CGFloat {
        menuBarScreenMaxY - axY - height
    }
}
