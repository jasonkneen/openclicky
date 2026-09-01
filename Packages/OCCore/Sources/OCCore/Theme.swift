import SwiftUI
import AppKit

public enum ClickyAccentTheme: String, CaseIterable, Identifiable {
    case blue
    case cyan
    case mint
    case lime
    case amber
    case orange
    case rose
    case violet
    case white

    public static let userDefaultsKey = "clickyAccentTheme"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .mint: return "Mint"
        case .lime: return "Lime"
        case .amber: return "Amber"
        case .orange: return "Orange"
        case .rose: return "Rose"
        case .violet: return "Violet"
        case .white: return "White"
        }
    }

    public var spokenAgentColorName: String {
        switch self {
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .mint: return "Green"
        case .lime: return "Lime"
        case .amber: return "Amber"
        case .orange: return "Orange"
        case .rose: return "Red"
        case .violet: return "Purple"
        case .white: return "White"
        }
    }

    public var accent: Color {
        switch self {
        case .blue: return Color(hex: "#2563EB")
        case .cyan: return Color(hex: "#0891B2")
        case .mint: return Color(hex: "#059669")
        case .lime: return Color(hex: "#65A30D")
        case .amber: return Color(hex: "#D97706")
        case .orange: return Color(hex: "#EA580C")
        case .rose: return Color(hex: "#E11D48")
        case .violet: return Color(hex: "#7C3AED")
        case .white: return Color(hex: "#F8FAFC")
        }
    }

    public var accentHover: Color {
        switch self {
        case .blue: return Color(hex: "#1D4ED8")
        case .cyan: return Color(hex: "#0E7490")
        case .mint: return Color(hex: "#047857")
        case .lime: return Color(hex: "#4D7C0F")
        case .amber: return Color(hex: "#B45309")
        case .orange: return Color(hex: "#C2410C")
        case .rose: return Color(hex: "#BE123C")
        case .violet: return Color(hex: "#6D28D9")
        case .white: return Color(hex: "#E5E7EB")
        }
    }

    public var accentText: Color {
        switch self {
        case .blue: return Color(hex: "#60A5FA")
        case .cyan: return Color(hex: "#22D3EE")
        case .mint: return Color(hex: "#34D399")
        case .lime: return Color(hex: "#A3E635")
        case .amber: return Color(hex: "#FBBF24")
        case .orange: return Color(hex: "#FB923C")
        case .rose: return Color(hex: "#FB7185")
        case .violet: return Color(hex: "#A78BFA")
        case .white: return Color(hex: "#F8FAFC")
        }
    }

    public var textOnAccent: Color {
        switch self {
        case .white: return Color(hex: "#101211")
        case .blue, .cyan, .mint, .lime, .amber, .orange, .rose, .violet: return .white
        }
    }

    public var cursorColor: Color {
        switch self {
        case .blue: return Color(hex: "#3380FF")
        case .cyan: return Color(hex: "#22D3EE")
        case .mint: return Color(hex: "#35D39A")
        case .lime: return Color(hex: "#A3E635")
        case .amber: return Color(hex: "#FACC15")
        case .orange: return Color(hex: "#FF8A3D")
        case .rose: return Color(hex: "#FF4F5E")
        case .violet: return Color(hex: "#9B6DFF")
        case .white: return Color(hex: "#F8FAFC")
        }
    }

    public var nsColor: NSColor {
        switch self {
        case .blue:
            return NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
        case .cyan:
            return NSColor(calibratedRed: 0.13, green: 0.83, blue: 0.93, alpha: 1.0)
        case .mint:
            return NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1.0)
        case .lime:
            return NSColor(calibratedRed: 0.64, green: 0.90, blue: 0.21, alpha: 1.0)
        case .amber:
            return NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 1.0)
        case .orange:
            return NSColor(calibratedRed: 1.00, green: 0.54, blue: 0.24, alpha: 1.0)
        case .rose:
            return NSColor(calibratedRed: 1.00, green: 0.31, blue: 0.37, alpha: 1.0)
        case .violet:
            return NSColor(calibratedRed: 0.61, green: 0.43, blue: 1.00, alpha: 1.0)
        case .white:
            return NSColor(calibratedWhite: 0.97, alpha: 1.0)
        }
    }

    public var accentSubtle: Color {
        accent.opacity(0.12)
    }


    public static var current: ClickyAccentTheme {
        let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ClickyAccentTheme.blue.rawValue
        return ClickyAccentTheme(rawValue: rawValue) ?? .blue
    }
}

public enum OpenClickyDefaults {
    public static let userThemeDefaultsKey = "openClickyThemeAppearance"
    public static let userGlassOpacityDefaultsKey = "openClickyGlassOpacity"
    public static let userGlassFrostingDefaultsKey = "openClickyGlassFrosting"
}

public enum ClickyTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public static var current: ClickyTheme {
        let rawValue = UserDefaults.standard.string(forKey: OpenClickyDefaults.userThemeDefaultsKey) ?? ClickyTheme.system.rawValue
        return ClickyTheme(rawValue: rawValue) ?? .system
    }
}

extension Color {
    /// H11: non-failable initializer for known-valid hex literals used throughout
    /// the design system (89 call sites pass string literals). Returns black on
    /// parse failure, which is acceptable for compile-time-constant tokens. For
    /// DYNAMIC hex values (model output, external cursor state), use the failable
    /// `Color(optionalHex:)` initializer so a malformed string can fall back to
    /// the intended color instead of silently becoming black.
    public init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgbValue),
              hexSanitized.count == 6 || hexSanitized.count == 3,
              hexSanitized.allSatisfy({ $0.isHexDigit }) else {
            self.init(red: 0, green: 0, blue: 0)
            return
        }
        let normalized = hexSanitized.count == 3
            ? hexSanitized.map { String(repeating: $0, count: 2) }.joined()
            : hexSanitized
        _ = Scanner(string: normalized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Failable initializer for DYNAMIC hex values (model output, external
    /// cursor state, user input). Returns nil on parse failure so callers can
    /// fall back to their intended color rather than silently getting black.
    public init?(optionalHex: String) {
        let hexSanitized = optionalHex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard hexSanitized.count == 6 || hexSanitized.count == 3,
              hexSanitized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        let normalized = hexSanitized.count == 3
            ? hexSanitized.map { String(repeating: $0, count: 2) }.joined()
            : hexSanitized
        var rgbValue: UInt64 = 0
        guard Scanner(string: normalized).scanHexInt64(&rgbValue) else { return nil }

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    public func blendedWithWhite(fraction: Double) -> Color {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}
