#if canImport(SwiftUI)
import SwiftUI

struct InstructionsView: View {
    let challenge: ChallengeSpecWrapper
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.UseSense.instructionIconBg)
                        .frame(width: 72, height: 72)

                    Image(systemName: iconName)
                        .font(.system(size: 32))
                        .foregroundColor(Color.UseSense.primary)
                }

                // Title
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color.UseSense.instructionTitle)
                    .multilineTextAlignment(.center)

                // Instructions
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(Color.UseSense.challengeDot)
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)
                            Text(instruction)
                                .font(.system(size: 16))
                                .foregroundColor(Color.UseSense.instructionBody)
                        }
                    }
                }
                .padding(.horizontal, 8)

                // Continue button
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.UseSense.primary)
                        .cornerRadius(12)
                }
            }
            .padding(32)
            .background(Color.UseSense.surface)
            .cornerRadius(24)
            .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
            .padding(.horizontal, 20)

            Spacer()
                .frame(height: 40)
        }
        .background(Color.black.opacity(0.5))
    }

    private var iconName: String {
        switch challenge.challengeType {
        case .followDot: return "circle.dotted"
        case .headTurn: return "face.smiling"
        case .speakPhrase: return "mic.fill"
        }
    }

    private var title: String {
        switch challenge.challengeType {
        case .followDot: return "Follow the Dot"
        case .headTurn: return "Turn Your Head"
        case .speakPhrase: return "Speak the Phrase"
        }
    }

    private var instructions: [String] {
        switch challenge.challengeType {
        case .followDot:
            return [
                "A dot will appear on screen",
                "Follow it with your eyes while keeping your head still",
                "Stay centered in the frame"
            ]
        case .headTurn:
            return [
                "Turn your head in the direction shown",
                "Move slowly and deliberately",
                "Return to center when prompted"
            ]
        case .speakPhrase:
            if case .speakPhrase(let c) = challenge {
                return [
                    "Say the following phrase clearly:",
                    "\"\(c.phrase)\"",
                    "Speak at a normal pace"
                ]
            }
            return ["Say the phrase shown on screen clearly"]
        }
    }
}
#endif
