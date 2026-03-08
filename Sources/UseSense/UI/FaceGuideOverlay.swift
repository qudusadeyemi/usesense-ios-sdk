#if canImport(SwiftUI)
import SwiftUI

/// Face guide overlay with oval cutout, pulsing dashed border, and "My face is ready" button.
/// Matches Android's FaceGuideOvalView: 55% width, 3:4 AR, max 80% height, dashed border.
struct FaceGuideOverlay: View {
    let qualityGuidance: [QualityGuidance]
    let qualityLevel: QualityLevel
    var showReadyButton: Bool = true
    var onReady: (() -> Void)?

    @State private var isPulsing = false

    var body: some View {
        GeometryReader { geometry in
            let ovalWidth = geometry.size.width * 0.55
            let ovalHeight = min(ovalWidth * (4.0 / 3.0), geometry.size.height * 0.5)

            ZStack {
                // Dimmed background with cutout
                Color.black.opacity(0.5)
                    .mask(
                        Rectangle()
                            .overlay(
                                Ellipse()
                                    .frame(width: ovalWidth, height: ovalHeight)
                                    .offset(y: -geometry.size.height * 0.1)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )

                // Dashed oval border with pulse animation
                Ellipse()
                    .stroke(style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                    .foregroundColor(borderColor)
                    .frame(width: ovalWidth, height: ovalHeight)
                    .offset(y: -geometry.size.height * 0.1)
                    .scaleEffect(isPulsing ? 1.1 : 1.0)
                    .opacity(isPulsing ? 0.6 : 1.0)
                    .animation(
                        .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                        value: isPulsing
                    )

                // Content below the oval – pinned to the bottom so the button
                // is always reachable, even on smaller screens.
                VStack(spacing: 8) {
                    Spacer()

                    Text("Position your face in the oval")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)

                    // Quality indicator
                    QualityIndicatorView(
                        mode: .full,
                        qualityLevel: qualityLevel,
                        message: qualityGuidance.first?.message
                    )

                    // Quality warning banner
                    if let guidance = qualityGuidance.first {
                        QualityWarningBanner(guidance: guidance, qualityLevel: qualityLevel)
                            .padding(.horizontal, 24)
                    }

                    if showReadyButton {
                        Button(action: { onReady?() }) {
                            Text("My face is ready")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color.UseSense.primary)
                                .cornerRadius(12)
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                    }
                }
                .padding(.bottom, 48)
            }
            .onAppear {
                isPulsing = true
            }
        }
    }

    private var borderColor: Color {
        if qualityGuidance.contains(where: { $0.severity == .critical }) {
            return Color.UseSense.qualityCritical
        } else if qualityGuidance.contains(where: { $0.severity == .warning }) {
            return Color.UseSense.qualityWarning
        }
        return Color.UseSense.qualityInfo
    }
}
#endif
