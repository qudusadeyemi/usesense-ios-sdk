#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

public struct UseSenseTheme: Sendable {
    public var primaryColor: Color
    public var backgroundColor: Color
    public var buttonCornerRadius: CGFloat
    public var showResultScreen: Bool
    public var localization: Localization

    public init(
        primaryColor: Color = Colors.indigo600,
        backgroundColor: Color = .black,
        buttonCornerRadius: CGFloat = 16,
        showResultScreen: Bool = true,
        localization: Localization = Localization()
    ) {
        self.primaryColor = primaryColor
        self.backgroundColor = backgroundColor
        self.buttonCornerRadius = buttonCornerRadius
        self.showResultScreen = showResultScreen
        self.localization = localization
    }

    public struct Localization: Sendable {
        public var instructionsTitle: String
        public var instructionsBody: String
        public var instructionsButton: String
        public var faceGuideLabel: String
        public var faceGuideButton: String
        public var countdownLabel: String
        public var baselineLabel: String
        public var processingLabel: String
        public var successLabel: String
        public var failureLabel: String
        public var retryLabel: String

        public init(
            instructionsTitle: String = "Identity Verification",
            instructionsBody: String = "We need to verify you're a real person. Follow the on-screen instructions.",
            instructionsButton: String = "Got it - Start",
            faceGuideLabel: String = "Position your face in the oval",
            faceGuideButton: String = "My face is ready",
            countdownLabel: String = "Get ready...",
            baselineLabel: String = "Look straight ahead",
            processingLabel: String = "Verifying...",
            successLabel: String = "Verification successful",
            failureLabel: String = "Verification failed",
            retryLabel: String = "Try again"
        ) {
            self.instructionsTitle = instructionsTitle
            self.instructionsBody = instructionsBody
            self.instructionsButton = instructionsButton
            self.faceGuideLabel = faceGuideLabel
            self.faceGuideButton = faceGuideButton
            self.countdownLabel = countdownLabel
            self.baselineLabel = baselineLabel
            self.processingLabel = processingLabel
            self.successLabel = successLabel
            self.failureLabel = failureLabel
            self.retryLabel = retryLabel
        }
    }

    public struct Colors {
        public static let indigo500 = Color(red: 99/255, green: 102/255, blue: 241/255)
        public static let indigo600 = Color(red: 79/255, green: 70/255, blue: 229/255)
        public static let indigo700 = Color(red: 67/255, green: 56/255, blue: 202/255)
        public static let violet500 = Color(red: 139/255, green: 92/255, blue: 246/255)
    }

    public static let `default` = UseSenseTheme()
}
#endif
