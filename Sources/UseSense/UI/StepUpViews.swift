#if canImport(SwiftUI)
import SwiftUI

// MARK: - Step-Up Intro View

/// "Additional Verification" intro screen with shield icon.
/// Displays for 1.5s before launching step-up challenges.
/// Brand: DeepSense Blue shield icon, Outfit bold title, DM Sans body.
struct StepUpIntroView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // Shield icon per brand manual: i-shield, DeepSense Blue
            Image(systemName: "shield.checkered")
                .font(.system(size: 48))
                .foregroundColor(Color.UseSense.primary)

            Text("Additional Verification")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text("We need a quick check to confirm you're really here.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            ProgressView()
                .tint(Color.UseSense.primary)
                .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
}

// MARK: - Flash Reflection Overlay View

/// Full-screen color overlay for Flash Reflection challenge.
/// 60% opacity, screen blend mode per spec.
struct FlashReflectionOverlayView: View {
    let color: Color
    let isActive: Bool

    var body: some View {
        if isActive {
            color
                .opacity(0.6)
                .blendMode(.screen)
                .ignoresSafeArea()
                .transition(.opacity)
        }
    }
}

// MARK: - RMAS Prompt View

/// Action prompt with countdown bar and step counter.
/// Brand: Outfit bold for action label, DM Sans for instructions.
struct RMASPromptView: View {
    let actionLabel: String
    let stepNumber: Int
    let totalSteps: Int
    let progress: Double

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // Step counter
            Text("\(stepNumber) of \(totalSteps)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.UseSense.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.UseSense.primary.opacity(0.15))
                .cornerRadius(UseSenseComponents.radiusSmall)

            // Action label
            Text(actionLabel)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            // Countdown progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.UseSense.primary)
                        .frame(width: geo.size.width * progress, height: 6)
                        .animation(UseSenseMotion.ease.speed(1.0 / UseSenseMotion.fast), value: progress)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 48)

            Spacer()
                .frame(height: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.7))
    }
}

// MARK: - Step-Up Complete View

/// Checkmark with "Verification complete" (0.5s display).
/// Brand: MatchSense Green for success checkmark.
struct StepUpCompleteView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.UseSense.success.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(Color.UseSense.success)
            }

            Text("Verification Complete")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
}

// Note: ChallengeProgressBar, BaselineOvalView, QualityWarningBanner,
// and QualityIndicatorView are defined in QualityIndicatorView.swift
#endif
