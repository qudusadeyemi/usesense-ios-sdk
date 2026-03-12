#if canImport(SwiftUI)
import SwiftUI

/// Compact quality indicator overlay shown inside the camera preview.
/// FULL mode: shows text badge at top. COMPACT mode: shows colored dot.
/// Matches Android's QualityIndicatorView with indigo guidance colors.
struct QualityIndicatorView: View {
    enum Mode { case full, compact }

    let mode: Mode
    let qualityLevel: QualityLevel
    let message: String?

    var body: some View {
        if mode == .compact {
            Circle()
                .fill(indicatorColor)
                .frame(width: 12, height: 12)
                .animation(.linear(duration: 0.4), value: qualityLevel)
        } else {
            if qualityLevel != .good, let msg = message {
                Text(msg)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(indicatorColor.opacity(0.9))
                    )
                    .animation(.linear(duration: 0.4), value: qualityLevel)
            }
        }
    }

    private var indicatorColor: Color {
        switch qualityLevel {
        case .good: return Color.UseSense.qualityInfo       // indigo
        case .acceptable: return Color.UseSense.qualityWarning  // violet-400
        case .poor: return Color.UseSense.qualityCritical    // violet-700
        }
    }
}

/// Quality warning banner displayed below the video container.
/// Uses indigo guidance theme with severity-based icons and colors.
struct QualityWarningBanner: View {
    let guidance: QualityGuidance?
    let qualityLevel: QualityLevel

    var body: some View {
        if let guidance = guidance, qualityLevel != .good {
            HStack(spacing: 6) {
                Text(iconEmoji(guidance.icon))
                    .font(.system(size: 14))

                Text(guidance.message)
                    .font(.system(size: 12))
                    .foregroundColor(textColor(guidance.severity))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(bgColor(guidance.severity))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(borderColor(guidance.severity), lineWidth: 1)
                    )
            )
        }
    }

    private func iconEmoji(_ icon: GuidanceIcon?) -> String {
        switch icon {
        case .blur: return "\u{26A0}\u{FE0F}"
        case .dark: return "\u{1F4A1}"
        case .bright: return "\u{2600}\u{FE0F}"
        case .contrast: return "\u{1F4A1}"
        case .none: return "\u{26A0}\u{FE0F}"
        }
    }

    private func textColor(_ severity: GuidanceSeverity) -> Color {
        switch severity {
        case .critical: return Color.UseSense.criticalBannerText
        case .warning: return Color.UseSense.warningBannerText
        case .info: return Color.UseSense.qualityInfo
        }
    }

    private func bgColor(_ severity: GuidanceSeverity) -> Color {
        switch severity {
        case .critical: return Color.UseSense.qualityCritical.opacity(0.1)
        case .warning: return Color.UseSense.qualityWarning.opacity(0.1)
        case .info: return Color.UseSense.qualityInfo.opacity(0.1)
        }
    }

    private func borderColor(_ severity: GuidanceSeverity) -> Color {
        switch severity {
        case .critical: return Color.UseSense.qualityCritical.opacity(0.2)
        case .warning: return Color.UseSense.qualityWarning.opacity(0.2)
        case .info: return Color.UseSense.qualityInfo.opacity(0.2)
        }
    }
}

/// Baseline oval: subtle white 30% opacity oval border during baseline/countdown/challenge.
/// Uses the SAME dimensions and vertical offset as FaceGuideOverlay so the oval
/// does not shift when transitioning between phases.
struct BaselineOvalView: View {
    var body: some View {
        GeometryReader { geometry in
            // Match FaceGuideOverlay dimensions exactly
            let ovalWidth = min(geometry.size.width * 0.70, geometry.size.height * 0.45, 320)
            let ovalHeight = min(geometry.size.width * 0.93, geometry.size.height * 0.60, 420)

            Ellipse()
                .stroke(Color.white.opacity(0.3), lineWidth: 2)
                .frame(width: ovalWidth, height: ovalHeight)
                // Match FaceGuideOverlay's -10% vertical offset
                .position(x: geometry.size.width / 2,
                          y: geometry.size.height / 2 - geometry.size.height * 0.1)
        }
    }
}

/// Phase badge showing "BASELINE" or "CHALLENGE" during capture.
struct PhaseBadge: View {
    let phase: String

    var body: some View {
        Text(phase)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.UseSense.primary.opacity(0.8))
            )
    }
}

/// Progress bar for challenge phases.
struct ChallengeProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.UseSense.primary)
                    .frame(width: geometry.size.width * CGFloat(progress), height: 4)
                    .animation(.linear(duration: 0.3), value: progress)
            }
        }
        .frame(height: 4)
    }
}
#endif
