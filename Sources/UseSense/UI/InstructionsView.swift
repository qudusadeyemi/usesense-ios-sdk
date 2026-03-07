#if canImport(SwiftUI)
import SwiftUI

struct InstructionsView: View {
    let theme: UseSenseTheme
    let challengeType: ChallengeType?
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 64))
                .foregroundColor(UseSenseTheme.Colors.indigo500)

            Text(theme.localization.instructionsTitle)
                .font(.title.weight(.bold))
                .foregroundColor(.white)

            Text(challengeDescription)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Button(action: onStart) {
                Text(theme.localization.instructionsButton)
                    .font(.body.weight(.bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: theme.buttonCornerRadius)
                            .fill(UseSenseTheme.Colors.indigo600)
                    )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .background(Color.black)
    }

    private var iconName: String {
        switch challengeType {
        case .followDot: return "eye.fill"
        case .headTurn: return "face.smiling.fill"
        case .speakPhrase: return "mic.fill"
        case nil: return "person.fill.viewfinder"
        }
    }

    private var challengeDescription: String {
        switch challengeType {
        case .followDot:
            return "You'll see a dot on screen. Follow it with your eyes while keeping your face visible to the camera."
        case .headTurn:
            return "You'll be asked to turn your head in different directions. Follow the arrows on screen."
        case .speakPhrase:
            return "You'll be asked to say a short phrase aloud. Make sure you're in a quiet environment."
        case nil:
            return theme.localization.instructionsBody
        }
    }
}
#endif
