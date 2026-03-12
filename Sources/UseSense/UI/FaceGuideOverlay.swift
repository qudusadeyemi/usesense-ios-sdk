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
            let screenW = geometry.size.width
            let screenH = geometry.size.height
            // Spec: width = min(70% screenW, 45% screenH, 320pt)
            //        height = min(93% screenW, 60% screenH, 420pt)
            let ovalWidth = min(screenW * 0.70, screenH * 0.45, 320)
            let ovalHeight = min(screenW * 0.93, screenH * 0.60, 420)
            let ovalCenterY = screenH / 2 - screenH * 0.1

            ZStack {
                // Blurred background with oval cutout — blurs camera feed outside the oval
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        Rectangle()
                            .fill(Color.white)
                            .overlay(
                                Ellipse()
                                    .frame(width: ovalWidth, height: ovalHeight)
                                    .position(x: screenW / 2, y: ovalCenterY)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )

                // Oval border: 3pt white at 70% opacity per spec
                Ellipse()
                    .stroke(Color.white.opacity(0.7), lineWidth: 3)
                    .frame(width: ovalWidth, height: ovalHeight)
                    .position(x: screenW / 2, y: ovalCenterY)
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
                            Text("I'm Ready")
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
        .ignoresSafeArea()
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
