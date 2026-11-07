#if canImport(SwiftUI)
import SwiftUI

/// Multi-screen outcome view matching Android's success/denied/blocked/failure screens.
struct ResultView: View {
    let decision: RedactedDecisionObject
    /// Org lockup in a header bar, as Android's result screen: the logo alone
    /// when there is one, else the name. Both nil = no header.
    var headerLogoURL: URL? = nil
    var headerDisplayName: String? = nil
    let onDismiss: () -> Void
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            if headerLogoURL != nil || headerDisplayName != nil {
                ResultBrandHeader(logoURL: headerLogoURL, displayName: headerDisplayName)
            }
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
                    // `.multilineTextAlignment(.center)` centers each line
                    // within the text bounds when the title wraps (e.g.
                    // "Verification Unsuccessful" on narrow iPhone SE
                    // widths). Without this, wrapped lines left-align
                    // inside the Text widget and visually drift off-centre
                    // from the icon and subtitle above/below.
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Text(resultSubtitle)
                    .font(.system(size: 16))
                    .foregroundColor(Color.UseSense.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
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
        // Brand voice: precision of an engineer, clarity of a teacher
        switch decision.decision.uppercased() {
        case "APPROVE": return "Verification Successful"
        case "REJECT": return "Verification Unsuccessful"
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

/// 56pt white bar with a hairline: the logo alone, the name while it loads or
/// when there is no logo / it fails (HostedPageHeader's rule).
struct ResultBrandHeader: View {
    let logoURL: URL?
    let displayName: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if let logoURL {
                    AsyncImage(url: logoURL) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 32)
                        } else {
                            name
                        }
                    }
                } else {
                    name
                }
                Spacer()
            }
            .frame(height: 56)
            Rectangle().fill(Color.UseSense.border).frame(height: 1)
        }
        .background(Color.UseSense.surface)
        .accessibilityIdentifier("usesense.result.header")
    }

    @ViewBuilder private var name: some View {
        if let displayName {
            Text(displayName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Color.UseSense.primary)
        }
    }
}

/// Error/failure screen shown when the verification process fails.
///
/// The title and body are chosen from the error's code (`SubjectErrorCopy`),
/// never the server's or the system's raw text, which goes to the host
/// callback. When the capture is still usable, "Retry" finishes it on the same
/// session and "Start over" recaptures.
struct FailureView: View {
    let error: UseSenseError
    /// "Start over" (or "Try again" when the capture can't be reused).
    let onRetry: () -> Void
    let onCancel: (() -> Void)?
    /// "Retry": finish the same capture on the same session. Nil when the
    /// capture can't be reused.
    var onResume: (() -> Void)? = nil

    private var copy: SubjectErrorCopy { SubjectErrorCopy.forError(error) }

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

                Text(copy.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color.UseSense.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("usesense.error.title")

                Text(copy.body)
                    .font(.system(size: 16))
                    .foregroundColor(Color.UseSense.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("usesense.error.body")

                if error.isRetryable, let onResume = onResume {
                    primaryButton("Retry", action: onResume)
                        .padding(.top, 8)
                    secondaryButton("Start over", action: onRetry)
                } else if error.isRetryable {
                    primaryButton("Try Again", action: onRetry)
                        .padding(.top, 8)
                }

                if let onCancel = onCancel {
                    secondaryButton(error.isRetryable ? "Cancel" : "Close", action: onCancel)
                } else if !error.isRetryable {
                    primaryButton("Done", action: onRetry)
                        .padding(.top, 8)
                }

                // Stable code for support and the host app; never a stack.
                Text(SubjectErrorCopy.caption(for: error))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.UseSense.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("usesense.error.code")
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

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(USColors.primaryForeground)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.UseSense.primary)
                .cornerRadius(12)
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color.UseSense.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.UseSense.border)
                .cornerRadius(12)
        }
    }

    private var errorIcon: String {
        switch copy {
        case .connection: return "wifi.slash"
        case .capture: return "camera.viewfinder"
        case .expired: return "clock.fill"
        case .unavailable: return "hand.raised.fill"
        default:
            switch error.code {
            case .cameraUnavailable, .cameraPermissionDenied: return "camera.fill"
            default: return "exclamationmark.triangle.fill"
            }
        }
    }
}
#endif
