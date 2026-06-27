#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

// MARK: - Adaptive Brand Colors (light + dark)
//
// `Color.UseSense.*` (UseSenseTheme.swift) are fixed light-mode tokens. For full
// dark-mode parity with the hosted page these resolve per `userInterfaceStyle`,
// matching theme.css :root vs .dark.

// The tokens below are now COMPUTED from the resolved FlowAppearance (Phase 1c
// white-label). When no appearance is set, `FlowAppearanceResolver.*` falls back
// to the exact built-in light/dark hex pairs that were hard-coded here before,
// so default behaviour is unchanged. The parity screens read these tokens, so
// setting the appearance on the resolver re-themes every screen automatically.
public enum USColors {
    /// A scheme-dynamic pair with no appearance slot (kept verbatim from the
    /// built-in ramp). Honours the appearance `mode` override (light/dark force).
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { tc in
            FlowAppearanceResolver.isDark(for: tc) ? UIColor(usHex: dark) : UIColor(usHex: light)
        })
    }

    // Surfaces — sourced from appearance.colors (with dark overrides)
    public static var background: Color {
        FlowAppearanceResolver.backgroundColorOverride
            ?? FlowAppearanceResolver.color(\.background, darkSlot: \.background, lightDefault: 0xFDFCFA, darkDefault: 0x1C1A17)
    }
    public static var foreground: Color {
        FlowAppearanceResolver.color(\.foreground, darkSlot: \.foreground, lightDefault: 0x1C1A17, darkDefault: 0xF5F3EF)
    }
    public static var card: Color {
        FlowAppearanceResolver.color(\.surface, darkSlot: \.surface, lightDefault: 0xFFFFFF, darkDefault: 0x2A2723)
    }
    public static var secondary: Color {
        FlowAppearanceResolver.color(\.surface, darkSlot: \.surface, lightDefault: 0xF5F3EF, darkDefault: 0x3D3A35)
    }
    public static var muted: Color {
        FlowAppearanceResolver.color(\.surface, darkSlot: \.surface, lightDefault: 0xF5F3EF, darkDefault: 0x3D3A35)
    }
    public static var mutedForeground: Color {
        FlowAppearanceResolver.color(\.muted, darkSlot: \.muted, lightDefault: 0x6B6760, darkDefault: 0x9E9A92)
    }
    public static var border: Color {
        FlowAppearanceResolver.color(\.border, darkSlot: \.border, lightDefault: 0xE8E5DE, darkDefault: 0x39352F)
    }
    public static var borderStrong: Color { dyn(0xD0CCBF, 0x4A453E) }

    // Brand
    public static var primary: Color {
        FlowAppearanceResolver.constantColor(\.primary, default: 0x4F7CFF)
    }
    public static var primaryForeground: Color {
        FlowAppearanceResolver.constantColor(\.primaryForeground, default: 0xFFFFFF)
    }
    public static let deepSense  = Color(usHex: 0x4F7CFF)
    public static let liveSense  = Color(usHex: 0x7C5CFC)
    public static let matchSense = Color(usHex: 0x00D4AA)

    // Semantic outcomes
    public static var success: Color {
        FlowAppearanceResolver.constantColor(\.success, default: 0x00D4AA)
    }
    public static let successText = dyn(0x008066, 0x33DFAF)
    public static var destructive: Color {
        FlowAppearanceResolver.constantColor(\.error, default: 0xFF6B4A)
    }
    public static let criticalText = dyn(0xB73520, 0xFF8867)
    public static var warning: Color {
        FlowAppearanceResolver.constantColor(\.warning, default: 0xFFB84D)
    }
    public static let warningText = dyn(0xB77829, 0xFFCF75)
    public static let magic       = Color(usHex: 0x7C5CFC)
    public static let magicText   = dyn(0x4C35B0, 0xB09FF9)

    // Subdued tint backgrounds (6% on light; deepened on dark)
    public static let brandBg    = dyn(0xEBF0FF, 0x232a3f)
    public static let successBg  = dyn(0xE6FBF5, 0x10322a)
    public static let criticalBg = dyn(0xFFF0EC, 0x3a1f18)
    public static let warningBg  = dyn(0xFFF7E8, 0x3a2f17)
    public static let magicBg    = dyn(0xF2EFFE, 0x261d3d)
}

extension UIColor {
    /// 0xRRGGBB initialiser (UseSense-namespaced to avoid collisions).
    convenience init(usHex hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue:  CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

extension Color {
    init(usHex hex: UInt32) { self.init(UIColor(usHex: hex)) }
}
#endif
