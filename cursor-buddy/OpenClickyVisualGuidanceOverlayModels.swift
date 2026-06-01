import AppKit
import Foundation

struct OpenClickyVisualGuidancePoint: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    func clamped(to rect: CGRect) -> OpenClickyVisualGuidancePoint {
        OpenClickyVisualGuidancePoint(
            x: min(max(x, Double(rect.minX)), Double(rect.maxX)),
            y: min(max(y, Double(rect.minY)), Double(rect.maxY))
        )
    }
}

struct OpenClickyVisualGuidanceRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var normalized: OpenClickyVisualGuidanceRect {
        let minX = min(x, x + width)
        let minY = min(y, y + height)
        return OpenClickyVisualGuidanceRect(
            x: minX,
            y: minY,
            width: abs(width),
            height: abs(height)
        )
    }

    func clamped(to bounds: CGRect) -> OpenClickyVisualGuidanceRect {
        let rect = normalized.cgRect.intersection(bounds)
        guard !rect.isNull else {
            return OpenClickyVisualGuidanceRect(x: bounds.minX, y: bounds.minY, width: 0, height: 0)
        }
        return OpenClickyVisualGuidanceRect(rect)
    }
}

enum OpenClickyVisualGuidanceOverlayKind: String, Codable, Equatable, Sendable {
    case scribble
    case rectangle
}

struct OpenClickyVisualGuidanceStyle: Codable, Equatable, Hashable, Sendable {
    var accentHex: String?
    var lineWidth: Double
    var fillOpacity: Double
    var caption: String?

    init(accentHex: String? = nil, lineWidth: Double = 5, fillOpacity: Double = 0.12, caption: String? = nil) {
        self.accentHex = accentHex
        self.lineWidth = max(1, min(lineWidth, 48))
        self.fillOpacity = max(0, min(fillOpacity, 0.65))
        self.caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct OpenClickyVisualGuidanceOverlay: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: OpenClickyVisualGuidanceOverlayKind
    var points: [OpenClickyVisualGuidancePoint]
    var rect: OpenClickyVisualGuidanceRect?
    var style: OpenClickyVisualGuidanceStyle
    var duration: TimeInterval
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: OpenClickyVisualGuidanceOverlayKind,
        points: [OpenClickyVisualGuidancePoint] = [],
        rect: OpenClickyVisualGuidanceRect? = nil,
        style: OpenClickyVisualGuidanceStyle = OpenClickyVisualGuidanceStyle(),
        duration: TimeInterval = 4,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.rect = rect
        self.style = style
        self.duration = max(0.2, min(duration, 60))
        self.createdAt = createdAt
    }

    var screenBounds: CGRect {
        switch kind {
        case .rectangle:
            return rect?.normalized.cgRect ?? .null
        case .scribble:
            guard let first = points.first else { return .null }
            return points.dropFirst().reduce(CGRect(origin: first.cgPoint, size: .zero)) { partial, point in
                partial.union(CGRect(origin: point.cgPoint, size: .zero))
            }
        }
    }

    func clamped(to desktopBounds: CGRect) -> OpenClickyVisualGuidanceOverlay {
        var overlay = self
        overlay.points = points.map { $0.clamped(to: desktopBounds) }
        overlay.rect = rect?.clamped(to: desktopBounds)
        return overlay
    }

    var isRenderable: Bool {
        switch kind {
        case .scribble:
            return points.count >= 2
        case .rectangle:
            guard let rect else { return false }
            let normalized = rect.normalized
            return normalized.width > 1 && normalized.height > 1
        }
    }
}

extension OpenClickyVisualGuidanceOverlay {
    static func scribble(
        points: [CGPoint],
        accentHex: String? = nil,
        lineWidth: Double = 5,
        caption: String? = nil,
        duration: TimeInterval = 4
    ) -> OpenClickyVisualGuidanceOverlay {
        OpenClickyVisualGuidanceOverlay(
            kind: .scribble,
            points: points.map { point in
                OpenClickyVisualGuidancePoint(x: Double(point.x), y: Double(point.y))
            },
            style: OpenClickyVisualGuidanceStyle(accentHex: accentHex, lineWidth: lineWidth, fillOpacity: 0, caption: caption),
            duration: duration
        )
    }

    static func rectangle(
        rect: CGRect,
        accentHex: String? = nil,
        lineWidth: Double = 4,
        fillOpacity: Double = 0.14,
        caption: String? = nil,
        duration: TimeInterval = 4
    ) -> OpenClickyVisualGuidanceOverlay {
        OpenClickyVisualGuidanceOverlay(
            kind: .rectangle,
            rect: OpenClickyVisualGuidanceRect(rect).normalized,
            style: OpenClickyVisualGuidanceStyle(accentHex: accentHex, lineWidth: lineWidth, fillOpacity: fillOpacity, caption: caption),
            duration: duration
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
