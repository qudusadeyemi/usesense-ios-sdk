#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

// MARK: - Adaptive Brand Colors (light + dark)
//
// `Color.UseSense.*` (UseSenseTheme.swift) are fixed light-mode tokens. For full
// dark-mode parity with the hosted page these resolve per `userInterfaceStyle`,
// matching theme.css :root vs .dark.

public enum USColors {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(usHex: dark) : UIColor(usHex: light) })
    }

    // Surfaces
    public static let background      = dyn(0xFDFCFA, 0x1C1A17)
    public static let foreground      = dyn(0x1C1A17, 0xF5F3EF)
    public static let card            = dyn(0xFFFFFF, 0x2A2723)
    public static let secondary       = dyn(0xF5F3EF, 0x3D3A35)
    public static let muted           = dyn(0xF5F3EF, 0x3D3A35)
    public static let mutedForeground = dyn(0x6B6760, 0x9E9A92)
    public static let border          = dyn(0xE8E5DE, 0x39352F)
    public static let borderStrong    = dyn(0xD0CCBF, 0x4A453E)

    // Brand (constant across schemes)
    public static let primary           = Color(usHex: 0x4F7CFF)
    public static let primaryForeground = Color.white
    public static let deepSense         = Color(usHex: 0x4F7CFF)
    public static let liveSense         = Color(usHex: 0x7C5CFC)
    public static let matchSense        = Color(usHex: 0x00D4AA)

    // Semantic outcomes
    public static let success     = Color(usHex: 0x00D4AA)
    public static let successText = dyn(0x008066, 0x33DFAF)
    public static let destructive = Color(usHex: 0xFF6B4A)
    public static let criticalText = dyn(0xB73520, 0xFF8867)
    public static let warning     = Color(usHex: 0xFFB84D)
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
