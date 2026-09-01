//
//  DesignSystem.swift
//  OCUI
//
//  Centralized design system using a blue accent palette on dark surfaces,
//  with a unified button style system. All colors, button styles, and
//  interaction states are defined here as the single source of truth.
//

import SwiftUI
import AppKit
import OCCore

public struct Triangle: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

public enum DS {

    // MARK: - Color Tokens

    public enum Colors {
        public static var isDarkMode: Bool {
            let theme = ClickyTheme.current
            switch theme {
            case .dark: return true
            case .light: return false
            case .system:
                // Package targets macOS 26.0; the macOS 10.14 availability
                // guard was dead code (always-taken branch).
                return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
        }

        // ── Backgrounds ──────────────────────────────────────────────
        // Layered surfaces from deepest to most elevated.
        // Higher surfaces are lighter, creating a sense of depth.

        /// The deepest background — used for the main app window fill.
        public static var background: Color {
            isDarkMode ? Color(hex: "#101211") : Color(hex: "#F8FAFC")
        }

        /// First elevation layer — used for cards, sidebar, top bar backgrounds.
        public static var surface1: Color {
            isDarkMode ? Color(hex: "#171918") : Color(hex: "#F1F5F9")
        }

        /// Second elevation layer — used for input fields, elevated cards, chat bubbles.
        public static var surface2: Color {
            isDarkMode ? Color(hex: "#202221") : Color(hex: "#E2E8F0")
        }

        /// Third elevation layer — used for hover backgrounds on interactive elements.
        public static var surface3: Color {
            isDarkMode ? Color(hex: "#272A29") : Color(hex: "#CBD5E1")
        }

        /// Fourth elevation layer — used for active/pressed states on interactive elements.
        public static var surface4: Color {
            isDarkMode ? Color(hex: "#2E3130") : Color(hex: "#94A3B8")
        }

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle edge highlight — used for card outlines, dividers, input field borders.
        /// Prefer this as a white inset edge rather than a flat gray 1px border.
        public static var borderSubtle: Color {
            edgeInset.opacity(isDarkMode ? 0.70 : 0.82)
        }

        /// Strong edge highlight — used for focused inputs, hovered card outlines.
        /// Prefer this as a white inset edge rather than a flat gray 1px border.
        public static var borderStrong: Color {
            edgeInset.opacity(isDarkMode ? 0.92 : 1.0)
        }

        /// Faint light edge — a restrained highlight for buttons and floating panels.
        public static var edgeLight: Color {
            edgeInset.opacity(isDarkMode ? 0.78 : 0.86)
        }

        /// One-pixel white inset edge used instead of gray outlines.
        public static var edgeInset: Color {
            Color.white.opacity(isDarkMode ? 0.20 : 0.82)
        }

        /// One-pixel black outer shadow used to sharpen dimensional edges.
        public static var edgeOuterShadow: Color {
            Color.black.opacity(0.04)
        }

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        public static var textPrimary: Color {
            isDarkMode ? Color(hex: "#ECEEED") : Color(hex: "#0F172A")
        }

        /// Secondary text — descriptions, hints, muted labels.
        public static var textSecondary: Color {
            isDarkMode ? Color(hex: "#ADB5B2") : Color(hex: "#475569")
        }

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        public static var textTertiary: Color {
            isDarkMode ? Color(hex: "#6B736F") : Color(hex: "#94A3B8")
        }

        /// Text used on top of the accent fill (#2563eb blue), like the primary button label.
        public static var textOnAccent: Color { ClickyAccentTheme.current.textOnAccent }

        // ── Tailwind Blue Scale ─────────────────────────────────────
        public static let blue50  = Color(hex: "#eff6ff")
        public static let blue100 = Color(hex: "#dbeafe")
        public static let blue200 = Color(hex: "#bfdbfe")
        public static let blue300 = Color(hex: "#93c5fd")
        public static let blue400 = Color(hex: "#60a5fa")
        public static let blue500 = Color(hex: "#3b82f6")
        public static let blue600 = Color(hex: "#2563eb")
        public static let blue700 = Color(hex: "#1d4ed8")
        public static let blue800 = Color(hex: "#1e40af")
        public static let blue900 = Color(hex: "#1e3a8a")
        public static let blue950 = Color(hex: "#172554")

        // ── Accent ───────────────────────────────────────────────────
        public static var accent: Color { ClickyAccentTheme.current.accent }
        public static var accentHover: Color { ClickyAccentTheme.current.accentHover }
        public static var accentText: Color { ClickyAccentTheme.current.accentText }
        public static var accentSubtle: Color { ClickyAccentTheme.current.accentSubtle }

        // ── Semantic Colors ──────────────────────────────────────────
        public static let destructive = Color(hex: "#E5484D")
        public static let destructiveHover = Color(hex: "#F2555A")
        public static let destructiveText = Color(hex: "#FF6369")
        public static let success = Color(hex: "#34D399")
        public static let warning = Color(hex: "#FFB224")
        public static let warningText = Color(hex: "#F1A10D")
        public static let info = Color(hex: "#70B8FF")
        public static let codeText = Color(hex: "#9DC2FF")

        // ── Overlay Cursor ───────────────────────────────────────────
        public static var overlayCursorBlue: Color { ClickyAccentTheme.current.cursorColor }

        // ── Floating Button Gradient ─────────────────────────────────
        public static let floatingGradientPurple = Color(hex: "#8F46EB")
        public static let floatingGradientPink = Color(hex: "#E84D9E")
        public static let floatingGradientOrange = Color(hex: "#FF8C33")

        // ── Help Chat ──────────────────────────────────────────────
        public static let helpChatUserBubble = blue800
        public static let helpChatUserBubbleHover = blue700
        public static let helpChatBackdrop = Color(hex: "#212121")

        // ── Disabled State ───────────────────────────────────────────
        public static var disabledBackground: Color { textPrimary.opacity(0.12) }
        public static var disabledText: Color { textPrimary.opacity(0.38) }
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
    }

    public enum CornerRadius {
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 8
        public static let large: CGFloat = 10
        public static let extraLarge: CGFloat = 12
        public static let pill: CGFloat = .infinity
    }

    public enum Animation {
        public static let fast: Double = 0.15
        public static let normal: Double = 0.25
        public static let slow: Double = 0.4
    }

    public enum StateLayer {
        public static let hover: Double = 0.08
        public static let focus: Double = 0.12
        public static let pressed: Double = 0.12
        public static let dragged: Double = 0.16
    }
}

// MARK: - Button Styles

public struct DSPrimaryButtonStyle: ButtonStyle {
    public var isFullWidth: Bool

    public init(isFullWidth: Bool = true) {
        self.isFullWidth = isFullWidth
    }

    @State private var isHovered = false

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, isFullWidth ? 0 : 20)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .strokeBorder(DS.Colors.edgeLight, lineWidth: 1)
                    .shadow(color: DS.Colors.edgeOuterShadow, radius: 0, x: 0, y: 1)
            )
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .shadow(
                color: DS.Colors.accent.opacity(isHovered ? 0.24 : 0),
                radius: isHovered ? 12 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.03 : 1.0))
            .animation(.easeInOut(duration: isHovered ? 0.6 : 0.3), value: isHovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

public struct DSSecondaryButtonStyle: ButtonStyle {
    public var isFullWidth: Bool

    public init(isFullWidth: Bool = true) {
        self.isFullWidth = isFullWidth
    }

    @State private var isHovered = false

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .strokeBorder(DS.Colors.edgeLight, lineWidth: 1)
                    .shadow(color: DS.Colors.edgeOuterShadow, radius: 0, x: 0, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

public struct DSTertiaryButtonStyle: ButtonStyle {
    public init() {}

    @State private var isHovered = false

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.accentHover
                    : isHovered
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .strokeBorder(DS.Colors.edgeLight.opacity(isHovered || configuration.isPressed ? 1.0 : 0.65), lineWidth: 1)
                    .shadow(color: DS.Colors.edgeOuterShadow, radius: 0, x: 0, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

public struct DSTextButtonStyle: ButtonStyle {
    public var fontSize: CGFloat

    public init(fontSize: CGFloat = 14) {
        self.fontSize = fontSize
    }

    @State private var isHovered = false

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

public struct DSOutlinedButtonStyle: ButtonStyle {
    public var isFullWidth: Bool

    public init(isFullWidth: Bool = true) {
        self.isFullWidth = isFullWidth
    }

    @State private var isHovered = false

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
                    .shadow(color: DS.Colors.edgeOuterShadow, radius: 0, x: 0, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.edgeInset.opacity(1.0)
        } else {
            return DS.Colors.edgeInset.opacity(0.78)
        }
    }
}

public struct DSDestructiveButtonStyle: ButtonStyle {
    public init() {}

    @State private var isHovered = false

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                isHovered || configuration.isPressed
                    ? .white
                    : DS.Colors.destructiveText
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
                    .shadow(color: DS.Colors.edgeOuterShadow, radius: 0, x: 0, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

public struct DSIconButtonStyle: ButtonStyle {
    public var size: CGFloat
    public var isDestructiveOnHover: Bool
    public var tooltipText: String?
    public var tooltipAlignment: Alignment

    public init(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltipText: String? = nil, tooltipAlignment: Alignment = .center) {
        self.size = size
        self.isDestructiveOnHover = isDestructiveOnHover
        self.tooltipText = tooltipText
        self.tooltipAlignment = tooltipAlignment
    }

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(circleBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Circle()
                    .strokeBorder(circleBorderColor(isPressed: configuration.isPressed), lineWidth: 1)
                    .shadow(color: DS.Colors.edgeOuterShadow, radius: 0, x: 0, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Circle())
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTooltipVisible = false
                    }
                }
            }
            .overlay(
                Group {
                    if isTooltipVisible, let text = tooltipText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DS.Colors.surface3.opacity(0.85))
                            )
                            .overlay(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.20), lineWidth: 0.8)

                                    RoundedRectangle(cornerRadius: 6)
                                        .trim(from: 0, to: 0.5)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.10),
                                                    Color.white.opacity(0.02)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                }
                            )
                            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 8)
                            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 2)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return .white
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.40)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.30)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.edgeInset.opacity(1.0)
        } else {
            return DS.Colors.edgeInset.opacity(0.58)
        }
    }
}

// MARK: - Convenience View Extensions

public extension View {
    func dsPrimaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    func dsSecondaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    func dsTertiaryButtonStyle() -> some View {
        self.buttonStyle(DSTertiaryButtonStyle())
    }

    func dsTextButtonStyle(fontSize: CGFloat = 14) -> some View {
        self.buttonStyle(DSTextButtonStyle(fontSize: fontSize))
    }

    func dsOutlinedButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSOutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    func dsDestructiveButtonStyle() -> some View {
        self.buttonStyle(DSDestructiveButtonStyle())
    }

    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Buddy Composer Visual Style

public enum BuddyComposerVisualStyle {
    public static let waveformLeadingColor = Color(hex: "#F3FBFF")
    public static let waveformTrailingColor = Color(hex: "#8FD2FF")
    public static let waveformGlowColor = Color(hex: "#AEE3FF")
}

// MARK: - Pointer Cursor (AppKit Bridge)

private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

public struct IBeamCursorView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Shared Chat Message Bubble

public struct OpenClickyChatMessageBubble: View {
    public let role: String
    public let text: String
    public let isUser: Bool
    public var metaLabel: String?
    public var maxBubbleWidth: CGFloat
    public var sideInset: CGFloat
    public var cornerRadius: CGFloat
    public var roleColor: Color?
    public var textColor: Color
    public var userFill: Color
    public var assistantFill: Color
    public var userBorder: Color
    public var assistantBorder: Color
    public var roleFont: Font
    public var metaFont: Font
    public var bodyFont: Font

    public init(
        role: String,
        text: String,
        isUser: Bool,
        metaLabel: String? = nil,
        maxBubbleWidth: CGFloat = 360,
        sideInset: CGFloat = 42,
        cornerRadius: CGFloat = 16,
        roleColor: Color? = nil,
        textColor: Color = DS.Colors.textPrimary,
        userFill: Color = DS.Colors.accent.opacity(0.18),
        assistantFill: Color = DS.Colors.surface2.opacity(0.42),
        userBorder: Color = DS.Colors.accent.opacity(0.32),
        assistantBorder: Color = Color.white.opacity(0.08),
        roleFont: Font = .caption.weight(.bold),
        metaFont: Font = .caption2.weight(.semibold),
        bodyFont: Font = .system(size: 13, weight: .medium)
    ) {
        self.role = role
        self.text = text
        self.isUser = isUser
        self.metaLabel = metaLabel
        self.maxBubbleWidth = maxBubbleWidth
        self.sideInset = sideInset
        self.cornerRadius = cornerRadius
        self.roleColor = roleColor
        self.textColor = textColor
        self.userFill = userFill
        self.assistantFill = assistantFill
        self.userBorder = userBorder
        self.assistantBorder = assistantBorder
        self.roleFont = roleFont
        self.metaFont = metaFont
        self.bodyFont = bodyFont
    }

    private var resolvedRoleColor: Color {
        if let roleColor { return roleColor }
        return isUser ? DS.Colors.accentText : DS.Colors.success
    }

    private var resolvedFill: Color {
        isUser ? userFill : assistantFill
    }

    private var resolvedBorder: Color {
        isUser ? userBorder : assistantBorder
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: sideInset) }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(role)
                        .font(roleFont)
                        .foregroundStyle(resolvedRoleColor)
                    if let metaLabel, !metaLabel.isEmpty {
                        Spacer(minLength: 8)
                        Text(metaLabel)
                            .font(metaFont)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }

                Text(text)
                    .font(bodyFont)
                    .foregroundStyle(textColor.opacity(0.90))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: maxBubbleWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(resolvedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(resolvedBorder, lineWidth: 1)
            )

            if !isUser { Spacer(minLength: sideInset) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

// MARK: - Native Tooltip

private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

public extension View {
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}
