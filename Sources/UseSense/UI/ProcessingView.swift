#if canImport(SwiftUI)
import SwiftUI

struct ProcessingView: View {
    let title: String
    let subtitle: String?
    let progress: Double?

    @State private var isAnimating = false

    init(title: String = "Processing", subtitle: String? = nil, progress: Double? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 20) {
                // Spinner
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 4)
                        .frame(width: 56, height: 56)

                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.UseSense.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 56, height: 56)
                        .rotationEffect(.degrees(isAnimating ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
                }

                Text(title)
                    .font(.usDisplay(20, .bold))
                    .foregroundColor(.white)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.usBody(15))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }

                if let progress = progress {
                    VStack(spacing: 8) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(0.2))
                                    .frame(height: 8)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.UseSense.primary)
                                    .frame(width: geometry.size.width * CGFloat(progress), height: 8)
                            }
                        }
                        .frame(height: 8)

                        Text("\(Int(progress * 100))%")
                            .font(.usMono(13, medium: true))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 40)
                }
            }
            .padding(32)

            Spacer()
        }
        .onAppear { isAnimating = true }
    }
}
#endif
