#if canImport(SwiftUI)
import SwiftUI

struct SpeakPhraseChallengeView: View {
    let phrase: String
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundColor(UseSenseTheme.Colors.indigo500)
                .scaleEffect(isPulsing ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }

            Text("Say the following phrase:")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))

            Text("\"\(phrase)\"")
                .font(.title2.weight(.bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(UseSenseTheme.Colors.indigo600.opacity(0.85))
                )

            Spacer()

            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Recording")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.bottom, 24)
        }
    }
}
#endif
