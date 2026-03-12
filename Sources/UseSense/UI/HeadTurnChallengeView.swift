#if canImport(SwiftUI)
import SwiftUI

struct HeadTurnChallengeView: View {
    let challenge: HeadTurnChallenge
    let onComplete: () -> Void
    let onStepReached: (Int) -> Void
    var onProgress: ((Double) -> Void)?

    @State private var currentStepIndex = 0
    @State private var isActive = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Direction indicator
            VStack(spacing: 16) {
                if currentStepIndex < challenge.sequence.count {
                    let step = challenge.sequence[currentStepIndex]

                    // Dark translucent rounded rect with direction arrow per spec
                    VStack(spacing: 12) {
                        Image(systemName: arrowIcon(for: step.direction))
                            .font(.system(size: 40, weight: .regular))
                            .foregroundColor(.white)
                    }
                    .padding(24)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(16)
                    .transition(.scale.combined(with: .opacity))

                    Text(directionText(for: step.direction))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentStepIndex)

            Spacer()

            Text("Turn your head slowly")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .padding(.bottom, 80)
        }
        .onAppear { startChallenge() }
    }

    private func startChallenge() {
        guard !isActive, !challenge.sequence.isEmpty else { return }
        isActive = true
        advanceStep()
    }

    private func advanceStep() {
        guard currentStepIndex < challenge.sequence.count else {
            onComplete()
            return
        }

        let step = challenge.sequence[currentStepIndex]
        onStepReached(step.index)
        let total = Double(challenge.sequence.count)
        onProgress?(Double(currentStepIndex + 1) / total)

        let delay = Double(step.durationMs) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            currentStepIndex += 1
            advanceStep()
        }
    }

    private func arrowIcon(for direction: HeadDirection) -> String {
        switch direction {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .center: return "scope"
        }
    }

    private func directionText(for direction: HeadDirection) -> String {
        switch direction {
        case .left: return "Turn LEFT"
        case .right: return "Turn RIGHT"
        case .up: return "Look UP"
        case .down: return "Look DOWN"
        case .center: return "Return to CENTER"
        }
    }
}
#endif
