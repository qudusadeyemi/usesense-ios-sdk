#if canImport(SwiftUI)
import SwiftUI

struct HeadTurnChallengeView: View {
    let sequence: [HeadTurnStep]
    @Binding var currentStepIndex: Int

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: currentDirection == .center
                                    ? [UseSenseTheme.Colors.indigo500, Color(red: 139/255, green: 92/255, blue: 246/255)]
                                    : [UseSenseTheme.Colors.indigo600, UseSenseTheme.Colors.indigo500],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 96, height: 96)
                        .shadow(color: UseSenseTheme.Colors.indigo500.opacity(0.5), radius: 15, x: 0, y: 4)

                    Image(systemName: arrowSystemName)
                        .font(.system(size: 56, weight: .bold))
                        .foregroundColor(.white)
                }
                .transition(.scale.combined(with: .opacity))
                .id(currentStepIndex)

                Text(instructionText)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.6))
                    )

                Spacer()

                Text("Step \(currentStepIndex + 1) of \(sequence.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(UseSenseTheme.Colors.indigo600.opacity(0.85))
                    )
                    .padding(.bottom, 16)
            }
        }
    }

    private var currentDirection: HeadDirection {
        guard currentStepIndex < sequence.count else { return .center }
        return sequence[currentStepIndex].direction
    }

    private var arrowSystemName: String {
        switch currentDirection {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .center: return "face.smiling"
        }
    }

    private var instructionText: String {
        switch currentDirection {
        case .left: return "Turn your head LEFT"
        case .right: return "Turn your head RIGHT"
        case .up: return "Look UP"
        case .down: return "Look DOWN"
        case .center: return "Look straight ahead"
        }
    }
}
#endif
