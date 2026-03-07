#if canImport(SwiftUI)
import SwiftUI

struct FaceGuideOverlay: View {
    let label: String
    let buttonLabel: String
    let onReady: () -> Void
    @State private var pulseAnimation = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Semi-transparent background with oval cutout
                Color.black.opacity(0.6)
                    .mask {
                        Rectangle()
                            .overlay(
                                Ellipse()
                                    .frame(
                                        width: geo.size.width * 0.38,
                                        height: geo.size.height * 0.5
                                    )
                                    .offset(y: -geo.size.height * 0.04)
                                    .blendMode(.destinationOut)
                            )
                    }

                // Dashed oval border
                Ellipse()
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(
                        width: geo.size.width * 0.38,
                        height: geo.size.height * 0.5
                    )
                    .offset(y: -geo.size.height * 0.04)
                    .opacity(pulseAnimation ? 1.0 : 0.6)
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: pulseAnimation)

                // Top label
                VStack {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(.top, geo.size.height * 0.04)
                    Spacer()
                }

                // Bottom button
                VStack {
                    Spacer()
                    Button(action: onReady) {
                        Text(buttonLabel)
                            .font(.body.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(UseSenseTheme.Colors.indigo600)
                            )
                            .shadow(radius: 10)
                    }
                    .padding(.bottom, geo.size.height * 0.06)
                }
            }
            .onAppear { pulseAnimation = true }
        }
    }
}
#endif
