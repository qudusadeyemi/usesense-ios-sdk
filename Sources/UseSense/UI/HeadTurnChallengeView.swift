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

                    Image(systemName: arrowIcon(for: step.direction))
                        .font(.system(size: 64, weight: .light))
                        .foregroundColor(.white)
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
        case .center: return "circle"
        }
    }

    private func directionText(for direction: HeadDirection) -> String {
        switch direction {
        case .left: return "Turn Left"
        case .right: return "Turn Right"
        case .up: return "Look Up"
        case .down: return "Look Down"
        case .center: return "Face Forward"
        }
    }
}
#endif
