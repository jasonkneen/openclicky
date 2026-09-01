//
//  OpenClickyWindowInfrastructure.swift
//  cursor-buddy
//
//  Shared window-level constants and Liquid Glass backdrop plumbing used by
//  OpenClicky's various floating window managers (notch capture, settings,
//  log viewer, 3D viewer, mini chat, and the Agent Mode HUD).
//

import AppKit
import SwiftUI
import OCCore

enum OpenClickyWindowLevels {
    /// OpenClicky panels need to stay above normal apps, menu-bar popups, and
    /// full-screen auxiliary surfaces without sitting above macOS drag images.
    /// If a panel is above `.draggingWindow`, dragged files look and behave as
    /// if they are underneath OpenClicky's dialog, so SwiftUI drop targets can
    /// fail to become the active destination. Keep the whole OpenClicky stack
    /// just below the drag layer while still far above app/status/menu levels.
    private static let interactiveCeiling = CGWindowLevelForKey(.draggingWindow)

    /// The compact notch/dynamic-island status surface must stay above
    /// OpenClicky's own panels so the external fallback notch does not vanish
    /// when the main window opens, while still remaining below active drags.
    static let statusSurface = NSWindow.Level(rawValue: Int(interactiveCeiling) - 1)

    /// The passive cursor and visual-guidance overlay should remain visible
    /// over OpenClicky's main dialog, but it is click-through and must stay
    /// below active macOS drag images/drop previews.
    static let cursorOverlay = statusSurface

    /// The main OpenClicky panel stays below the compact notch surface but
    /// above normal app/menu/status surfaces.
    static let mainPanel = NSWindow.Level(rawValue: Int(interactiveCeiling) - 3)

    /// First-party dialogs and document windows float one step above the main
    /// panel while staying below the drag layer so file drops land on them.
    static let panelDialog = NSWindow.Level(rawValue: Int(interactiveCeiling) - 2)

    static func applyMainPanelLevel(to window: NSWindow?) {
        window?.level = mainPanel
    }

    static func applyPanelDialogLevel(to window: NSWindow?) {
        window?.level = panelDialog
    }

    static func applyCursorOverlayLevel(to window: NSWindow?) {
        window?.level = cursorOverlay
    }
}

final class OpenClickyLiquidGlassBackdropView: NSView {
    enum Strength {
        case compact
        case expanded
    }

    static var isLiquidGlassAvailable: Bool {
        true
    }

    private let glassContainerView = NSGlassEffectContainerView()
    private let glassContentView = NSView()
    private let glassView = NSGlassEffectView()
    private let persistentAccentView = OpenClickyLiquidGlassAccentWashView()
    private var defaultsObserver: NSObjectProtocol?
    private let maskLayer = CAShapeLayer()
    private var cornerRadius: CGFloat
    private var roundsTopCorners = true
    private var accentColor: NSColor = .systemBlue
    private var strength: Strength = .compact

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLiquidGlassState()
    }

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        glassContainerView.translatesAutoresizingMaskIntoConstraints = false
        glassContentView.translatesAutoresizingMaskIntoConstraints = false
        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassContainerView.contentView = glassContentView
        glassContainerView.spacing = 8
        glassView.style = .regular
        glassContentView.addSubview(glassView)
        addSubview(glassContainerView)

        persistentAccentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(persistentAccentView)

        NSLayoutConstraint.activate([
            glassContainerView.topAnchor.constraint(equalTo: topAnchor),
            glassContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            glassView.topAnchor.constraint(equalTo: glassContentView.topAnchor),
            glassView.leadingAnchor.constraint(equalTo: glassContentView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: glassContentView.trailingAnchor),
            glassView.bottomAnchor.constraint(equalTo: glassContentView.bottomAnchor),

            persistentAccentView.topAnchor.constraint(equalTo: topAnchor),
            persistentAccentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            persistentAccentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            persistentAccentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        applyShape()
        updateLiquidGlassState()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateLiquidGlassState()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func updateLiquidGlassState() {
        let opacity = UserDefaults.standard.object(forKey: AppBundleConfiguration.userGlassOpacityDefaultsKey) as? Double ?? 0.75
        let frosting = UserDefaults.standard.object(forKey: AppBundleConfiguration.userGlassFrostingDefaultsKey) as? Double ?? 0.20

        glassView.style = .regular
        glassView.cornerRadius = cornerRadius
        glassView.tintColor = nativeGlassTint(opacity: opacity, frosting: frosting)
        persistentAccentView.configure(
            accentColor: accentColor,
            opacity: opacity,
            frosting: frosting,
            cornerRadius: cornerRadius,
            roundsTopCorners: roundsTopCorners,
            strength: strength
        )
        needsDisplay = true
    }

    func configure(cornerRadius: CGFloat, roundsTopCorners: Bool, accentColor: NSColor, strength: Strength) {
        self.cornerRadius = cornerRadius
        self.roundsTopCorners = roundsTopCorners
        self.accentColor = accentColor
        self.strength = strength
        updateLiquidGlassState()
        applyShape()
    }

    override func layout() {
        super.layout()
        applyShape()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Native Liquid Glass rendering is handled by NSGlassEffectView.
    }

    private func applyShape() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        if roundsTopCorners {
            layer?.mask = nil
            layer?.cornerRadius = cornerRadius
            if #available(macOS 10.15, *) {
                layer?.cornerCurve = .continuous
            }
        } else {
            let path = cgPath(in: bounds)
            maskLayer.path = path
            layer?.mask = maskLayer
            if #available(macOS 10.15, *) {
                maskLayer.cornerCurve = .continuous
            }
        }
        layer?.backgroundColor = NSColor.clear.cgColor
        glassView.cornerRadius = cornerRadius
        persistentAccentView.cornerRadius = cornerRadius
        persistentAccentView.roundsTopCorners = roundsTopCorners
        persistentAccentView.needsDisplay = true
    }

    private func nativeGlassTint(opacity: Double, frosting: Double) -> NSColor? {
        let clampedFrosting = min(max(frosting, 0.0), 1.0)
        let clampedOpacity = min(max(opacity, 0.0), 1.0)
        let strengthBoost = strength == .expanded ? 0.012 : 0.0
        let alpha = CGFloat(0.006 + strengthBoost + clampedOpacity * 0.012 + clampedFrosting * 0.025)
        return accentColor.withAlphaComponent(alpha)
    }

    private func cgPath(in rect: NSRect) -> CGPath {
        if roundsTopCorners {
            return CGPath(
                roundedRect: rect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let filletRadius: CGFloat = 8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        path.addCurve(
            to: CGPoint(x: rect.maxX - filletRadius, y: rect.maxY - filletRadius),
            control1: CGPoint(x: rect.maxX - filletRadius * 0.5, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - filletRadius, y: rect.maxY - filletRadius * 0.5)
        )

        path.addLine(to: CGPoint(x: rect.maxX - filletRadius, y: rect.minY + radius))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - filletRadius - radius, y: rect.minY),
            control: CGPoint(x: rect.maxX - filletRadius, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX + filletRadius + radius, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + filletRadius, y: rect.minY + radius),
            control: CGPoint(x: rect.minX + filletRadius, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX + filletRadius, y: rect.maxY - filletRadius))

        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY),
            control1: CGPoint(x: rect.minX + filletRadius, y: rect.maxY - filletRadius * 0.5),
            control2: CGPoint(x: rect.minX + filletRadius * 0.5, y: rect.maxY)
        )

        path.closeSubpath()
        return path
    }
}

private final class OpenClickyLiquidGlassAccentWashView: NSView {
    var accentColor: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var glassOpacity: Double = 0.75 { didSet { needsDisplay = true } }
    var glassFrosting: Double = 0.20 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 28 { didSet { needsDisplay = true } }
    var roundsTopCorners: Bool = true { didSet { needsDisplay = true } }
    var strength: OpenClickyLiquidGlassBackdropView.Strength = .expanded { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    func configure(
        accentColor: NSColor,
        opacity: Double,
        frosting: Double,
        cornerRadius: CGFloat,
        roundsTopCorners: Bool,
        strength: OpenClickyLiquidGlassBackdropView.Strength
    ) {
        self.accentColor = accentColor
        self.glassOpacity = opacity
        self.glassFrosting = frosting
        self.cornerRadius = cornerRadius
        self.roundsTopCorners = roundsTopCorners
        self.strength = strength
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let clampedOpacity = min(max(glassOpacity, 0.0), 1.0)
        let clampedFrosting = min(max(glassFrosting, 0.0), 1.0)
        let baseAlpha = strength == .expanded ? 0.050 : 0.038
        let accentAlpha = CGFloat(baseAlpha + clampedOpacity * 0.018 + clampedFrosting * 0.020)

        NSGraphicsContext.saveGraphicsState()
        clippedPath().addClip()

        accentColor.withAlphaComponent(accentAlpha).setFill()
        bounds.fill()

        let gradient = NSGradient(colors: [
            accentColor.withAlphaComponent(accentAlpha * 0.95),
            accentColor.withAlphaComponent(accentAlpha * 0.32),
            NSColor.white.withAlphaComponent(strength == .expanded ? 0.014 : 0.010)
        ])
        gradient?.draw(
            from: NSPoint(x: bounds.minX, y: bounds.minY),
            to: NSPoint(x: bounds.maxX, y: bounds.maxY),
            options: []
        )

        NSGraphicsContext.restoreGraphicsState()
    }

    private func clippedPath() -> NSBezierPath {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard !roundsTopCorners else {
            return NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let filletRadius: CGFloat = 8
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))

        path.curve(
            to: NSPoint(x: rect.maxX - filletRadius, y: rect.minY + filletRadius),
            controlPoint1: NSPoint(x: rect.maxX - filletRadius * 0.5, y: rect.minY),
            controlPoint2: NSPoint(x: rect.maxX - filletRadius, y: rect.minY + filletRadius * 0.5)
        )

        path.line(to: NSPoint(x: rect.maxX - filletRadius, y: rect.maxY - radius))

        path.curve(
            to: NSPoint(x: rect.maxX - filletRadius - radius, y: rect.maxY),
            controlPoint1: NSPoint(x: rect.maxX - filletRadius, y: rect.maxY - radius * 0.45),
            controlPoint2: NSPoint(x: rect.maxX - filletRadius - radius * 0.45, y: rect.maxY)
        )

        path.line(to: NSPoint(x: rect.minX + filletRadius + radius, y: rect.maxY))

        path.curve(
            to: NSPoint(x: rect.minX + filletRadius, y: rect.maxY - radius),
            controlPoint1: NSPoint(x: rect.minX + filletRadius + radius * 0.45, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.minX + filletRadius, y: rect.maxY - radius * 0.45)
        )

        path.line(to: NSPoint(x: rect.minX + filletRadius, y: rect.minY + filletRadius))

        path.curve(
            to: NSPoint(x: rect.minX, y: rect.minY),
            controlPoint1: NSPoint(x: rect.minX + filletRadius, y: rect.minY + filletRadius * 0.5),
            controlPoint2: NSPoint(x: rect.minX + filletRadius * 0.5, y: rect.minY)
        )

        path.close()
        return path
    }
}

@MainActor
enum OpenClickyLiquidGlassWindowSurface {
    @discardableResult
    static func install<Content: View>(
        hostingView: NSHostingView<Content>,
        in window: NSWindow,
        frame: NSRect,
        cornerRadius: CGFloat,
        roundsTopCorners: Bool = true,
        accentColor: NSColor? = nil,
        strength: OpenClickyLiquidGlassBackdropView.Strength = .expanded
    ) -> OpenClickyLiquidGlassBackdropView {
        window.isOpaque = false
        window.backgroundColor = .clear

        let containerView = OpenClickyGlassContainerView(frame: frame)
        containerView.autoresizingMask = [.width, .height]
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        let backdrop = OpenClickyLiquidGlassBackdropView(cornerRadius: cornerRadius)
        backdrop.frame = containerView.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.configure(
            cornerRadius: cornerRadius,
            roundsTopCorners: roundsTopCorners,
            accentColor: accentColor ?? OpenClickyNotchCaptureWindowManager.nsAccentColor(for: nil),
            strength: strength
        )
        containerView.addSubview(backdrop)

        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)

        window.contentView = containerView
        return backdrop
    }

    static func hostingView<Content: View>(in window: NSWindow?) -> NSHostingView<Content>? {
        findHostingView(in: window?.contentView)
    }

    private static func findHostingView<Content: View>(in view: NSView?) -> NSHostingView<Content>? {
        guard let view else { return nil }
        if let hostingView = view as? NSHostingView<Content> {
            return hostingView
        }

        for subview in view.subviews {
            if let hostingView: NSHostingView<Content> = findHostingView(in: subview) {
                return hostingView
            }
        }
        return nil
    }
}

final class OpenClickyGlassContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}
