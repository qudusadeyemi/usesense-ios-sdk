#if canImport(SwiftUI)
import SwiftUI

struct FaceGuideOverlay: View {
    let qualityGuidance: [QualityGuidance]
    var pulseAnimation: Bool = true

    @State private var isPulsing = false

    var body: some View {
        GeometryReader { geometry in
            let ovalWidth = geometry.size.width * 0.55
            let ovalHeight = ovalWidth * (4.0 / 3.0)

            ZStack {
                // Dimmed background with cutout
                Color.black.opacity(0.5)
                    .mask(
                        Rectangle()
                            .overlay(
                                Ellipse()
                                    .frame(width: ovalWidth, height: ovalHeight)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )

                // Oval border
                Ellipse()
                    .stroke(borderColor, lineWidth: 3)
                    .frame(width: ovalWidth, height: ovalHeight)
                    .scaleEffect(isPulsing ? 1.02 : 1.0)
                    .animation(
                        pulseAnimation ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                        value: isPulsing
                    )

                // "Position your face" text
                VStack {
                    Spacer()
                        .frame(height: geometry.size.height / 2 + ovalHeight / 2 + 24)

                    Text("Position your face in the oval")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)

                    // Quality guidance messages
                    if !qualityGuidance.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(Array(qualityGuidance.prefix(2).enumerated()), id: \.offset) { _, guidance in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(guidanceColor(guidance.severity))
                                        .frame(width: 8, height: 8)
                                    Text(guidance.message)
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }

                    Spacer()
                }
            }
            .onAppear {
                if pulseAnimation {
                    isPulsing = true
                }
            }
        }
    }

    private var borderColor: Color {
        if qualityGuidance.contains(where: { $0.severity == .critical }) {
            return Color.UseSense.error
        } else if qualityGuidance.contains(where: { $0.severity == .warning }) {
            return Color.UseSense.manualReview
        }
        return Color.UseSense.success
    }

    private func guidanceColor(_ severity: QualityGuidance.Severity) -> Color {
        switch severity {
        case .critical: return Color.UseSense.qualityCritical
        case .warning: return Color.UseSense.qualityWarning
        case .info: return Color.UseSense.qualityInfo
        }
    }
}
#endif
