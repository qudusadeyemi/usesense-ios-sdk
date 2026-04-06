#if canImport(SwiftUI)
import SwiftUI

// MARK: - UseSense Brand Colors
// Source: UseSense Brand Manual v3.0
// Naming: "UseSense" (one word, capital U, capital S, no space, no hyphen)

extension Color {
    public enum UseSense {
        // ── Pillar Colors (locked to their respective pillars) ──

        /// DeepSense Blue — Channel integrity, brand primary, CTAs
        public static let deepSenseBlue = Color(hex: 0x4F7CFF)
        /// LiveSense Purple — Multimodal liveness, AI features
        public static let liveSensePurple = Color(hex: 0x7C5CFC)
        /// MatchSense Green — Identity collision, verified states
        public static let matchSenseGreen = Color(hex: 0x00D4AA)

        // ── Brand Primary (alias for DeepSense Blue) ──

        public static let primary = deepSenseBlue
        public static let primaryDark = Color(hex: 0x3D63DB)    // Blue 600
        public static let primaryLight = Color(hex: 0xD6E0FF)   // Blue 100
        public static let primaryBg = Color(hex: 0xEBF0FF)      // Blue 000

        // ── Purple Scale ──

        public static let purpleDark = Color(hex: 0x6347D6)     // Purple 600
        public static let purpleLight = Color(hex: 0xE5DFFD)    // Purple 100
        public static let purpleBg = Color(hex: 0xF2EFFE)       // Purple 000

        // ── Green Scale ──

        public static let greenDark = Color(hex: 0x00AA88)      // Green 600
        public static let greenLight = Color(hex: 0xCCF7EB)     // Green 100
        public static let greenBg = Color(hex: 0xE6FBF5)        // Green 000

        // ── Semantic Outcomes ──

        /// Approved / Success state
        public static let success = matchSenseGreen
        /// Rejected / Error state
        public static let error = Color(hex: 0xFF6B4A)
        public static let errorDark = Color(hex: 0xDB4E33)
        public static let errorBg = Color(hex: 0xFFF0EC)
        /// Manual Review / Warning state
        public static let manualReview = Color(hex: 0xFFB84D)
        public static let warningDark = Color(hex: 0xDB973A)
        public static let warningBg = Color(hex: 0xFFF7E8)

        // ── Warm Neutrals ──

        public static let white = Color(hex: 0xFFFFFF)          // n0
        public static let background = Color(hex: 0xFDFCFA)     // n50
        public static let surface = Color(hex: 0xF5F3EF)        // n1
        public static let border = Color(hex: 0xE8E5DE)         // n2
        public static let borderStrong = Color(hex: 0xD0CCBF)   // n3
        public static let textTertiary = Color(hex: 0x9E9A92)   // n4
        public static let textSecondary = Color(hex: 0x6B6760)  // n5
        public static let textPrimary = Color(hex: 0x3D3A35)    // n6
        public static let textDark = Color(hex: 0x2A2723)       // n7
        public static let darkBg = Color(hex: 0x1C1A17)         // n8
        public static let darkest = Color(hex: 0x0C0B09)        // n9

        // ── Component Tokens ──

        /// Focus ring: 0 0 0 3px rgba(79,124,255,.15)
        public static let focusRing = Color(hex: 0x4F7CFF).opacity(0.15)

        // ── Quality Indicators ──

        public static let qualityCritical = liveSensePurple
        public static let qualityWarning = Color(hex: 0x967FF7)
        public static let qualityInfo = deepSenseBlue
        public static let criticalBannerText = Color(hex: 0x6347D6)
        public static let warningBannerText = liveSensePurple

        // ── Challenge-specific ──

        public static let challengeDot = Color(hex: 0xFF6B4A)
        public static let instructionIconBg = primaryBg
        public static let instructionTitle = textDark
        public static let instructionBody = textSecondary
    }
}

// MARK: - Brand Motion Constants

public enum UseSenseMotion {
    /// Brand easing curve: cubic-bezier(0.16, 1, 0.3, 1)
    public static let ease = Animation.timingCurve(0.16, 1, 0.3, 1)
    /// Fast: 150ms — hover, focus, toggle, color transitions
    public static let fast: Double = 0.15
    /// Normal: 250ms — expand, collapse, modals, panels
    public static let normal: Double = 0.25
    /// Slow: 400ms — page transitions, large movements
    public static let slow: Double = 0.40
}

// MARK: - Brand Component Constants

public enum UseSenseComponents {
    // Button dimensions per brand manual
    public static let buttonHeightSmall: CGFloat = 36
    public static let buttonHeightDefault: CGFloat = 44
    public static let buttonHeightLarge: CGFloat = 52
    public static let buttonRadius: CGFloat = 10

    // Border radii
    public static let radiusSmall: CGFloat = 6
    public static let radiusMedium: CGFloat = 10
    public static let radiusLarge: CGFloat = 14
    public static let radiusXL: CGFloat = 20
}

// MARK: - Hex Color Extension

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
#endif
