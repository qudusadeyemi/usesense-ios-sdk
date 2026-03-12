#if canImport(SwiftUI)
import SwiftUI

extension Color {
    public enum UseSense {
        // Brand & Primary
        public static let primary = Color(red: 0.31, green: 0.39, blue: 0.96)
        public static let primaryDark = Color(red: 0.31, green: 0.27, blue: 0.90)
        public static let primaryLight = Color(red: 0.39, green: 0.40, blue: 0.95)

        // Semantic Outcomes
        public static let success = Color(red: 0.06, green: 0.73, blue: 0.51)
        public static let error = Color(red: 0.94, green: 0.27, blue: 0.27)
        public static let manualReview = Color(red: 0.96, green: 0.62, blue: 0.04)

        // Neutrals
        public static let background = Color(red: 0.97, green: 0.98, blue: 0.98)
        public static let surface = Color.white
        public static let textPrimary = Color(red: 0.10, green: 0.10, blue: 0.10)
        public static let textSecondary = Color(red: 0.42, green: 0.45, blue: 0.50)
        public static let border = Color(red: 0.90, green: 0.91, blue: 0.92)

        // Quality Indicators (indigo guidance theme)
        public static let qualityCritical = Color(red: 0.49, green: 0.23, blue: 0.93)
        public static let qualityWarning = Color(red: 0.65, green: 0.55, blue: 0.98)
        public static let qualityInfo = Color(red: 0.39, green: 0.40, blue: 0.95)
        public static let criticalBannerText = Color(red: 0.43, green: 0.16, blue: 0.85)
        public static let warningBannerText = Color(red: 0.49, green: 0.23, blue: 0.93)

        // Challenge-specific
        public static let challengeDot = Color(red: 0.937, green: 0.267, blue: 0.267) // #EF4444
        public static let instructionIconBg = Color(red: 0.88, green: 0.91, blue: 1.0)
        public static let instructionTitle = Color(red: 0.12, green: 0.16, blue: 0.23)
        public static let instructionBody = Color(red: 0.39, green: 0.44, blue: 0.53)
    }
}
#endif
