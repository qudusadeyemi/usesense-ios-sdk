#if canImport(SwiftUI)
import SwiftUI

/// Result screens for hosted pages per spec Section 12.
/// Supports success, failed, and manual review outcomes.
struct HostedResultView: View {
    let branding: EffectiveBranding
    let decision: String  // "APPROVE" | "REJECT" | "MANUAL_REVIEW"
    let flowType: HostedFlowType
    let actionText: String?
    let successMessage: String?
    let errorMessage: String?
    let reviewMessage: String?
    let orgName: String?
    let onClose: () -> Void

    enum HostedFlowType {
        case enrollment
        case verificationPlain
        case verificationAction
    }

    var body: some View {
        VStack(spacing: 0) {
            HostedPageHeader(branding: branding)

            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 40)

                    // Icon in circle
                    ZStack {
                        Circle()
                            .fill(resultBgColor.opacity(0.15))
                            .frame(width: 80, height: 80)

                        Image(systemName: resultIcon)
                            .font(.system(size: 48))
                            .foregroundColor(resultColor)
                    }

                    Text(resultTitle)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))

                    // Result message in colored container
                    resultMessageView
                        .padding(.horizontal, 24)

                    // Action authorization confirmation
                    if case .verificationAction = flowType,
                       decision.uppercased() == "APPROVE",
                       let action = actionText {
                        VStack(spacing: 8) {
                            Text("You have authorised:")
                                .font(.system(size: 14))
                                .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                            Text(action)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(Color(red: 0.969, green: 0.973, blue: 0.976))
                        .cornerRadius(12)
                        .padding(.horizontal, 24)
                    }

                    // Close/Continue button
                    HostedPrimaryButton(
                        title: branding.redirectUrl != nil ? "Continue" : "Close",
                        branding: branding,
                        action: {
                            if let redirectUrl = branding.redirectUrl,
                               let url = URL(string: redirectUrl) {
                                #if canImport(UIKit)
                                UIApplication.shared.open(url)
                                #endif
                            }
                            onClose()
                        }
                    )
                    .padding(.horizontal, 24)

                    Spacer().frame(height: 24)
                }
            }

            HostedPageFooter()
        }
        .background(Color.white.ignoresSafeArea())
    }

    // MARK: - Result Styling

    private var resultColor: Color {
        switch decision.uppercased() {
        case "APPROVE": return Color(red: 0.086, green: 0.639, blue: 0.290) // Green 600
        case "REJECT": return Color(red: 0.863, green: 0.149, blue: 0.149) // Red 600
        case "MANUAL_REVIEW": return Color(red: 0.851, green: 0.467, blue: 0.024) // Amber 600
        default: return Color(red: 0.278, green: 0.333, blue: 0.412)
        }
    }

    private var resultBgColor: Color {
        switch decision.uppercased() {
        case "APPROVE": return Color(red: 0.086, green: 0.639, blue: 0.290)
        case "REJECT": return Color(red: 0.863, green: 0.149, blue: 0.149)
        case "MANUAL_REVIEW": return Color(red: 0.851, green: 0.467, blue: 0.024)
        default: return Color(red: 0.278, green: 0.333, blue: 0.412)
        }
    }

    private var resultIcon: String {
        switch decision.uppercased() {
        case "APPROVE": return "checkmark.circle.fill"
        case "REJECT": return "xmark.circle.fill"
        case "MANUAL_REVIEW": return "exclamationmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var resultTitle: String {
        switch decision.uppercased() {
        case "APPROVE":
            switch flowType {
            case .enrollment: return "Enrollment Successful"
            case .verificationPlain: return "Identity Verified"
            case .verificationAction: return "Verification Successful"
            }
        case "REJECT":
            switch flowType {
            case .enrollment: return "Enrollment Failed"
            default: return "Verification Failed"
            }
        case "MANUAL_REVIEW":
            return "Pending Review"
        default:
            return "Verification Complete"
        }
    }

    @ViewBuilder
    private var resultMessageView: some View {
        let message = resolvedMessage
        let (bgColor, borderColor) = messageContainerColors

        Text(message)
            .font(.system(size: 15))
            .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(bgColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: 1)
            )
            .cornerRadius(12)
    }

    private var resolvedMessage: String {
        switch decision.uppercased() {
        case "APPROVE":
            if let msg = successMessage, !msg.isEmpty { return msg }
            switch flowType {
            case .enrollment: return "Your identity has been enrolled successfully."
            case .verificationPlain: return "You may now close this page."
            case .verificationAction: return "Your authorization has been confirmed."
            }
        case "REJECT":
            if let msg = errorMessage, !msg.isEmpty { return msg }
            let org = orgName ?? "support"
            return "We could not verify your identity. Please contact \(org)."
        case "MANUAL_REVIEW":
            if let msg = reviewMessage, !msg.isEmpty { return msg }
            return "Your verification is being reviewed. You will be notified of the result."
        default:
            return "The verification process has been completed."
        }
    }

    private var messageContainerColors: (Color, Color) {
        switch decision.uppercased() {
        case "APPROVE":
            return (
                Color(red: 0.941, green: 0.992, blue: 0.957),
                Color(red: 0.733, green: 0.937, blue: 0.827)
            )
        case "REJECT":
            return (
                Color(red: 0.996, green: 0.949, blue: 0.949),
                Color(red: 0.996, green: 0.792, blue: 0.792)
            )
        case "MANUAL_REVIEW":
            return (
                Color(red: 1.0, green: 0.976, blue: 0.922),
                Color(red: 0.996, green: 0.902, blue: 0.624)
            )
        default:
            return (
                Color(red: 0.945, green: 0.961, blue: 0.976),
                Color(red: 0.886, green: 0.910, blue: 0.878)
            )
        }
    }
}
#endif
