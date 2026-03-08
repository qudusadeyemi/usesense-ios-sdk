#if canImport(SwiftUI)
import SwiftUI

/// Multi-screen outcome view matching Android's success/denied/blocked/failure screens.
struct ResultView: View {
    let decision: RedactedDecisionObject
    let onDismiss: () -> Void
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(resultColor.opacity(0.15))
                        .frame(width: 96, height: 96)

                    Image(systemName: resultIcon)
                        .font(.system(size: 44))
                        .foregroundColor(resultColor)
                }

                Text(resultTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(Color.UseSense.textPrimary)

                Text(resultSubtitle)
                    .font(.system(size: 16))
                    .foregroundColor(Color.UseSense.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                Button(action: onDismiss) {
                    Text(primaryButtonTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(resultColor)
                        .cornerRadius(12)
                }
                .padding(.top, 8)

                if decision.isRejected, let retry = onRetry {
                    Button(action: retry) {
                        Text("Try Again")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color.UseSense.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.UseSense.border)
                            .cornerRadius(12)
                    }
                }
            }
            .padding(32)
            .background(Color.UseSense.surface)
            .cornerRadius(24)
            .shadow(color: .black.opacity(0.1), radius: 16, y: 4)
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(Color.UseSense.background.ignoresSafeArea())
    }

    private var resultColor: Color {
        switch decision.decision.uppercased() {
        case "APPROVE": return Color.UseSense.success
        case "REJECT": return Color.UseSense.error
        case "MANUAL_REVIEW": return Color.UseSense.manualReview
        default: return Color.UseSense.textSecondary
        }
    }

    private var resultIcon: String {
        switch decision.decision.uppercased() {
        case "APPROVE": return "checkmark.circle.fill"
        case "REJECT": return "xmark.circle.fill"
        case "MANUAL_REVIEW": return "clock.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var resultTitle: String {
        switch decision.decision.uppercased() {
        case "APPROVE": return "Verification Successful"
        case "REJECT": return "Verification Denied"
        case "MANUAL_REVIEW": return "Under Review"
        default: return "Verification Complete"
        }
    }

    private var resultSubtitle: String {
        switch decision.decision.uppercased() {
        case "APPROVE":
            return "Your identity has been verified successfully. You can now proceed."
        case "REJECT":
            return "We were unable to verify your identity. Please try again or contact support."
        case "MANUAL_REVIEW":
            return "Your verification is being reviewed. You will be notified of the result shortly."
        default:
            return "The verification process has been completed."
        }
    }

    private var primaryButtonTitle: String {
        switch decision.decision.uppercased() {
        case "APPROVE": return "Continue"
        case "REJECT": return "Done"
        case "MANUAL_REVIEW": return "Got It"
        default: return "Done"
        }
    }
}

/// Error/failure screen shown when the verification process fails.
struct FailureView: View {
    let error: UseSenseError
    let onRetry: () -> Void
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.UseSense.error.opacity(0.15))
                        .frame(width: 96, height: 96)

                    Image(systemName: errorIcon)
                        .font(.system(size: 44))
                        .foregroundColor(Color.UseSense.error)
                }

                Text(errorTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(Color.UseSense.textPrimary)

                Text(error.message)
                    .font(.system(size: 16))
                    .foregroundColor(Color.UseSense.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if error.isRetryable {
                    Button(action: onRetry) {
                        Text("Try Again")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.UseSense.primary)
                            .cornerRadius(12)
                    }
                    .padding(.top, 8)
                }

                if let onCancel = onCancel {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color.UseSense.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.UseSense.border)
                            .cornerRadius(12)
                    }
                } else if !error.isRetryable {
                    Button(action: onRetry) {
                        Text("Done")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.UseSense.primary)
                            .cornerRadius(12)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(32)
            .background(Color.UseSense.surface)
            .cornerRadius(24)
            .shadow(color: .black.opacity(0.1), radius: 16, y: 4)
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(Color.UseSense.background.ignoresSafeArea())
    }

    private var errorIcon: String {
        switch error.code {
        case .networkError, .networkTimeout: return "wifi.slash"
        case .cameraUnavailable, .cameraPermissionDenied: return "camera.fill"
        case .sessionExpired: return "clock.fill"
        case .quotaExceeded: return "hand.raised.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var errorTitle: String {
        switch error.code {
        case .networkError, .networkTimeout: return "Connection Error"
        case .cameraUnavailable, .cameraPermissionDenied: return "Camera Unavailable"
        case .sessionExpired: return "Session Expired"
        case .quotaExceeded: return "Rate Limited"
        case .userCancelled: return "Cancelled"
        default: return "Something Went Wrong"
        }
    }
}
#endif
