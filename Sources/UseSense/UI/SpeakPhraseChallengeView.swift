#if canImport(SwiftUI)
import SwiftUI

struct SpeakPhraseChallengeView: View {
    let challenge: SpeakPhraseChallenge
    let onComplete: () -> Void

    @State private var timeRemaining: Double = 0
    @State private var isRecording = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Microphone icon with pulse
                ZStack {
                    Circle()
                        .fill(Color.UseSense.primary.opacity(0.15))
                        .frame(width: 100, height: 100)
                        .scaleEffect(pulseScale)

                    Circle()
                        .fill(Color.UseSense.primary.opacity(0.3))
                        .frame(width: 72, height: 72)

                    Image(systemName: "mic.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }

                Text("Say the following phrase:")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))

                Text("\"\(challenge.phrase)\"")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // Timer
                Text(String(format: "%.0fs remaining", max(0, timeRemaining)))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()
        }
        .onAppear {
            timeRemaining = Double(challenge.totalDurationMs) / 1000.0
            isRecording = true
            startTimer()
            startPulse()
        }
    }

    private func startTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            timeRemaining -= 1
            if timeRemaining <= 0 {
                timer.invalidate()
                onComplete()
            }
        }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulseScale = 1.15
        }
    }
}
#endif
