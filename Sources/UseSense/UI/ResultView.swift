#if canImport(SwiftUI)
import SwiftUI

struct ResultView: View {
    let decision: RedactedDecisionObject
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 20) {
                // Result icon
                ZStack {
                    Circle()
                        .fill(resultColor.opacity(0.15))
                        .frame(width: 80, height: 80)

                    Image(systemName: resultIcon)
                        .font(.system(size: 36))
                        .foregroundColor(resultColor)
                }

                Text(resultTitle)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color.UseSense.textPrimary)

                Text(resultSubtitle)
                    .font(.system(size: 16))
                    .foregroundColor(Color.UseSense.textSecondary)
                    .multilineTextAlignment(.center)

                Button(action: onDismiss) {
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
        default: return Color.UseSense.manualReview
        }
    }

    private var resultIcon: String {
        switch decision.decision.uppercased() {
        case "APPROVE": return "checkmark.circle.fill"
        case "REJECT": return "xmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var resultTitle: String {
        switch decision.decision.uppercased() {
        case "APPROVE": return "Verified"
        case "REJECT": return "Verification Failed"
        default: return "Under Review"
        }
    }

    private var resultSubtitle: String {
        switch decision.decision.uppercased() {
        case "APPROVE": return "Your identity has been verified successfully."
        case "REJECT": return "We could not verify your identity. Please try again."
        default: return "Your verification is being reviewed. You'll be notified of the result."
        }
    }
}
#endif
