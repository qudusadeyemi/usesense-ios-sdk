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
                        .stroke(Color.UseSense.border, lineWidth: 4)
                        .frame(width: 56, height: 56)

                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.UseSense.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 56, height: 56)
                        .rotationEffect(.degrees(isAnimating ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
                }

                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color.UseSense.textPrimary)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundColor(Color.UseSense.textSecondary)
                        .multilineTextAlignment(.center)
                }

                if let progress = progress {
                    VStack(spacing: 8) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.UseSense.border)
                                    .frame(height: 8)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.UseSense.primary)
                                    .frame(width: geometry.size.width * CGFloat(progress), height: 8)
                            }
                        }
                        .frame(height: 8)

                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.UseSense.textSecondary)
                    }
                    .padding(.horizontal, 40)
                }
            }
            .padding(32)
            .background(Color.UseSense.surface)
            .cornerRadius(24)
            .shadow(color: .black.opacity(0.1), radius: 16, y: 4)
            .padding(.horizontal, 32)

            Spacer()
        }
        .background(Color.UseSense.background.ignoresSafeArea())
        .onAppear { isAnimating = true }
    }
}
#endif
