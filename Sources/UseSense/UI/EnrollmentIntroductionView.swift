#if canImport(SwiftUI)
import SwiftUI

/// Enrollment introduction screen per spec Section 11.5.
/// Hero icon, "What to expect" list, encryption badge, "Get Started" button.
struct EnrollmentIntroductionView: View {
    let branding: EffectiveBranding
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HostedPageHeader(branding: branding)

            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 24)

                    // Hero icon: camera in 96pt circle with primaryColor at 12% opacity
                    ZStack {
                        Circle()
                            .fill(Color(hex: branding.primaryColor).opacity(0.12))
                            .frame(width: 96, height: 96)

                        Image(systemName: "camera.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Color(hex: branding.primaryColor))
                    }

                    Text("Identity Verification")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))

                    Text("We need to verify your identity. This process is quick and secure.")
                        .font(.system(size: 16))
                        .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    // "What to expect" numbered list in gray container
                    VStack(alignment: .leading, spacing: 16) {
                        Text("What to expect")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))

                        expectationRow(number: "1", text: "Position your face in the camera frame")
                        expectationRow(number: "2", text: "Complete a short liveness check")
                        expectationRow(number: "3", text: "Get verified in seconds")
                    }
                    .padding(16)
                    .background(Color(red: 0.969, green: 0.973, blue: 0.976)) // Slate 50
                    .cornerRadius(12)
                    .padding(.horizontal, 24)

                    // Shield icon + "End-to-end encrypted" badge
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: branding.primaryColor))

                        Text("End-to-end encrypted")
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Color(hex: branding.primaryColor).opacity(0.08))
                    .cornerRadius(20)

                    // "Get Started" button
                    HostedPrimaryButton(
                        title: "Get Started",
                        branding: branding,
                        action: onGetStarted
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                    Spacer().frame(height: 16)
                }
            }

            HostedPageFooter()
        }
        .background(Color.white.ignoresSafeArea())
    }

    private func expectationRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color(hex: branding.primaryColor))
                .clipShape(Circle())

            Text(text)
                .font(.system(size: 15))
                .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                .padding(.top, 2)
        }
    }
}
#endif
