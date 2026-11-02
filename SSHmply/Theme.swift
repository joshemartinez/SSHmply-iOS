import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Design tokens mirrored from the desktop app (light · dark · oled).
struct Palette {
    var window: Color
    var sidebar: Color
    var elevated: Color
    var input: Color
    var hover: Color
    var border: Color
    var borderStrong: Color
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var accent: Color
    var accentSoft: Color
    var success: Color
    var warning: Color
    var danger: Color
    var dangerSoft: Color
    var successSoft: Color
    var terminalBg: Color
    var overlay: Color

    private struct Tokens {
        var window: UIColor, sidebar: UIColor, elevated: UIColor, input: UIColor, hover: UIColor
        var border: UIColor, borderStrong: UIColor
        var textPrimary: UIColor, textSecondary: UIColor, textTertiary: UIColor
        var accent: UIColor, accentSoft: UIColor, success: UIColor, warning: UIColor, danger: UIColor
        var dangerSoft: UIColor, successSoft: UIColor, terminalBg: UIColor, overlay: UIColor
    }

    private static func tokens(_ theme: ResolvedTheme) -> Tokens {
        switch theme {
        case .light:
            return Tokens(
                window: UIColor(hex: 0xF5F5F7), sidebar: UIColor(hex: 0xEBEBEF), elevated: UIColor(hex: 0xFFFFFF),
                input: UIColor(white: 0, alpha: 0.05), hover: UIColor(white: 0, alpha: 0.045),
                border: UIColor(white: 0, alpha: 0.09), borderStrong: UIColor(white: 0, alpha: 0.16),
                textPrimary: UIColor(hex: 0x1D1D1F), textSecondary: UIColor(hex: 0x5E5E63), textTertiary: UIColor(hex: 0x86868B),
                accent: UIColor(hex: 0x007AFF), accentSoft: UIColor(hex: 0x007AFF, alpha: 0.12),
                success: UIColor(hex: 0x1FA84A), warning: UIColor(hex: 0xD97A00), danger: UIColor(hex: 0xE0301E),
                dangerSoft: UIColor(hex: 0xE0301E, alpha: 0.10), successSoft: UIColor(hex: 0x1FA84A, alpha: 0.12),
                terminalBg: UIColor(hex: 0xFFFFFF), overlay: UIColor(white: 0, alpha: 0.32)
            )
        case .dark:
            return Tokens(
                window: UIColor(hex: 0x1C1C1E), sidebar: UIColor(hex: 0x252528), elevated: UIColor(hex: 0x2C2C2F),
                input: UIColor(white: 1, alpha: 0.07), hover: UIColor(white: 1, alpha: 0.06),
                border: UIColor(white: 1, alpha: 0.09), borderStrong: UIColor(white: 1, alpha: 0.18),
                textPrimary: UIColor(hex: 0xF5F5F7), textSecondary: UIColor(hex: 0xA8A8AE), textTertiary: UIColor(hex: 0x7D7D84),
                accent: UIColor(hex: 0x0A84FF), accentSoft: UIColor(hex: 0x0A84FF, alpha: 0.18),
                success: UIColor(hex: 0x32D74B), warning: UIColor(hex: 0xFF9F0A), danger: UIColor(hex: 0xFF5A4D),
                dangerSoft: UIColor(hex: 0xFF5A4D, alpha: 0.14), successSoft: UIColor(hex: 0x32D74B, alpha: 0.14),
                terminalBg: UIColor(hex: 0x18181A), overlay: UIColor(white: 0, alpha: 0.55)
            )
        case .oled:
            return Tokens(
                window: UIColor(hex: 0x000000), sidebar: UIColor(hex: 0x0B0B0C), elevated: UIColor(hex: 0x131315),
                input: UIColor(white: 1, alpha: 0.08), hover: UIColor(white: 1, alpha: 0.07),
                border: UIColor(white: 1, alpha: 0.12), borderStrong: UIColor(white: 1, alpha: 0.22),
                textPrimary: UIColor(hex: 0xFFFFFF), textSecondary: UIColor(hex: 0xACACB2), textTertiary: UIColor(hex: 0x7A7A81),
                accent: UIColor(hex: 0x0A84FF), accentSoft: UIColor(hex: 0x0A84FF, alpha: 0.20),
                success: UIColor(hex: 0x32D74B), warning: UIColor(hex: 0xFF9F0A), danger: UIColor(hex: 0xFF5A4D),
                dangerSoft: UIColor(hex: 0xFF5A4D, alpha: 0.16), successSoft: UIColor(hex: 0x32D74B, alpha: 0.16),
                terminalBg: UIColor(hex: 0x000000), overlay: UIColor(white: 0, alpha: 0.7)
            )
        }
    }

    /// Builds a palette. For `.system` every colour is dynamic and follows light/dark (never OLED).
    static func make(_ choice: ThemeChoice) -> Palette {
        func pick(_ key: KeyPath<Tokens, UIColor>) -> Color {
            switch choice {
            case .light: return Color(tokens(.light)[keyPath: key])
            case .dark: return Color(tokens(.dark)[keyPath: key])
            case .oled: return Color(tokens(.oled)[keyPath: key])
            case .system:
                let light = tokens(.light)[keyPath: key]
                let dark = tokens(.dark)[keyPath: key]
                return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
            }
        }
        return Palette(
            window: pick(\.window), sidebar: pick(\.sidebar), elevated: pick(\.elevated), input: pick(\.input),
            hover: pick(\.hover), border: pick(\.border), borderStrong: pick(\.borderStrong),
            textPrimary: pick(\.textPrimary), textSecondary: pick(\.textSecondary), textTertiary: pick(\.textTertiary),
            accent: pick(\.accent), accentSoft: pick(\.accentSoft), success: pick(\.success), warning: pick(\.warning),
            danger: pick(\.danger), dangerSoft: pick(\.dangerSoft), successSoft: pick(\.successSoft),
            terminalBg: pick(\.terminalBg), overlay: pick(\.overlay)
        )
    }
}

// MARK: - Terminal colours

struct TerminalColors {
    var background: UInt32
    var foreground: UInt32
    var cursor: UInt32
    var selection: UInt32
    var selectionAlpha: CGFloat
    var ansi: [UInt32] // 16 entries

    static func forTheme(_ theme: ResolvedTheme) -> TerminalColors {
        let darkAnsi: [UInt32] = [
            0x48484A, 0xFF6961, 0x4CD964, 0xFFD60A, 0x64A8FF, 0xD17CF5, 0x6FD8FF, 0xD1D1D6,
            0x8E8E93, 0xFF8A80, 0x7AE58A, 0xFFE45E, 0x8DBFFF, 0xE3A2FA, 0x9BE6FF, 0xFFFFFF,
        ]
        switch theme {
        case .light:
            return TerminalColors(
                background: 0xFFFFFF, foreground: 0x1D1D1F, cursor: 0x007AFF, selection: 0x007AFF, selectionAlpha: 0.24,
                ansi: [
                    0x1D1D1F, 0xD12F1F, 0x1C8F37, 0x9A6200, 0x0A5FD6, 0xA13BBD, 0x067F98, 0x8E8E93,
                    0x6E6E73, 0xE5483A, 0x24A844, 0xB87300, 0x2A7CF0, 0xB955D6, 0x0F98B5, 0x3A3A3C,
                ]
            )
        case .dark:
            return TerminalColors(
                background: 0x18181A, foreground: 0xE8E8EA, cursor: 0x0A84FF, selection: 0x0A84FF, selectionAlpha: 0.36, ansi: darkAnsi
            )
        case .oled:
            return TerminalColors(
                background: 0x000000, foreground: 0xF2F2F4, cursor: 0x0A84FF, selection: 0x0A84FF, selectionAlpha: 0.40, ansi: darkAnsi
            )
        }
    }
}

// MARK: - Reusable styling

struct CardBackground: ViewModifier {
    @EnvironmentObject var store: AppStore
    func body(content: Content) -> some View {
        content
            .background(store.pal.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(store.pal.border, lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var pal: Palette
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 16, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 7 : 12)
            .background(pal.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var pal: Palette
    var compact = false
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 16, weight: .medium))
            .foregroundColor(danger ? pal.danger : pal.textPrimary)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 7 : 12)
            .background((danger ? pal.dangerSoft : pal.input).opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous))
    }
}
