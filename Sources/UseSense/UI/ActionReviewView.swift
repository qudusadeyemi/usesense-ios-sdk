#if canImport(SwiftUI)
import SwiftUI

/// Verification action review screen per spec Section 11.6.
/// Supports plain auth (no action) and action authorization (with action text + risk tier).
struct ActionReviewView: View {
    let branding: EffectiveBranding
    let actionContext: ActionContext?
    let onVerify: () -> Void
    let onDispute: (() -> Void)?

    private var isActionAuth: Bool {
        actionContext?.actionText != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HostedPageHeader(branding: branding)

            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 32)

                    if isActionAuth {
                        actionAuthContent
                    } else {
                        plainAuthContent
                    }

                    Spacer().frame(height: 16)
                }
            }

            HostedPageFooter()
        }
        .background(Color.white.ignoresSafeArea())
    }

    // MARK: - Plain Auth (no action context)

    private var plainAuthContent: some View {
        VStack(spacing: 24) {
            // Shield icon
            ZStack {
                Circle()
                    .fill(Color(hex: branding.primaryColor).opacity(0.12))
                    .frame(width: 80, height: 80)

                Image(systemName: "shield.checkered")
                    .font(.system(size: 36))
                    .foregroundColor(Color(hex: branding.primaryColor))
            }

            Text("Verify Your Identity")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))

            Text("Please complete a quick identity verification to continue.")
                .font(.system(size: 16))
                .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HostedPrimaryButton(
                title: "Verify My Identity",
                branding: branding,
                action: onVerify
            )
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Action Auth (with action context)

    private var actionAuthContent: some View {
        VStack(spacing: 24) {
            // Shield icon
            ZStack {
                Circle()
                    .fill(Color(hex: branding.primaryColor).opacity(0.12))
                    .frame(width: 80, height: 80)

                Image(systemName: "shield.checkered")
                    .font(.system(size: 36))
                    .foregroundColor(Color(hex: branding.primaryColor))
            }

            Text("Authorization Required")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))

            Text("You are being asked to authorize the following action:")
                .font(.system(size: 16))
                .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            // Action text in bordered card
            VStack(spacing: 12) {
                if let actionText = actionContext?.actionText {
                    Text(actionText)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))
                        .multilineTextAlignment(.center)
                }

                // Risk tier badge
                if let riskTier = actionContext?.riskTier {
                    riskBadge(tier: riskTier)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(red: 0.886, green: 0.910, blue: 0.878), lineWidth: 1)
            )
            .cornerRadius(12)
            .padding(.horizontal, 24)

            // "Verify and Authorise" button
            HostedPrimaryButton(
                title: "Verify and Authorise",
                branding: branding,
                action: onVerify
            )
            .padding(.horizontal, 24)

            // "This Is Not My Request" button
            if let onDispute = onDispute {
                HostedSecondaryButton(
                    title: "This Is Not My Request",
                    color: Color(red: 0.863, green: 0.149, blue: 0.149),
                    action: onDispute
                )
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Risk Tier Badge

    private func riskBadge(tier: String) -> some View {
        let (bgColor, textColor, label) = riskTierColors(tier)
        return Text(label.uppercased())
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(bgColor)
            .cornerRadius(8)
    }

    private func riskTierColors(_ tier: String) -> (Color, Color, String) {
        switch tier.lowercased() {
        case "critical":
            return (
                Color(red: 0.996, green: 0.949, blue: 0.949),
                Color(red: 0.863, green: 0.149, blue: 0.149),
                tier
            )
        case "high":
            return (
                Color(red: 1.0, green: 0.976, blue: 0.922),
                Color(red: 0.851, green: 0.467, blue: 0.024),
                tier
            )
        case "medium":
            return (
                Color(red: 0.937, green: 0.949, blue: 1.0),
                Color(red: 0.227, green: 0.384, blue: 0.835),
                tier
            )
        case "low":
            return (
                Color(red: 0.941, green: 0.992, blue: 0.957),
                Color(red: 0.086, green: 0.639, blue: 0.290),
                tier
            )
        default:
            return (
                Color(red: 0.945, green: 0.961, blue: 0.976),
                Color(red: 0.278, green: 0.333, blue: 0.412),
                tier
            )
        }
    }
}
#endif
