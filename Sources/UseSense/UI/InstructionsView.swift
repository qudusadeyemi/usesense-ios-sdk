#if canImport(SwiftUI)
import SwiftUI

/// Challenge primer page shown before capture begins.
/// Full-screen white layout matching the Web SDK and EnrollmentIntroductionView style.
struct InstructionsView: View {
    let challenge: ChallengeSpecWrapper
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 40)

                    // Hero icon in tinted circle
                    ZStack {
                        Circle()
                            .fill(Color.UseSense.primary.opacity(0.12))
                            .frame(width: 96, height: 96)

                        Image(systemName: iconName)
                            .font(.system(size: 40))
                            .foregroundColor(Color.UseSense.primary)
                    }

                    // Title
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))
                        .multilineTextAlignment(.center)

                    // Subtitle
                    Text(subtitle)
                        .font(.system(size: 16))
                        .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    // "What to expect" numbered list in gray container
                    VStack(alignment: .leading, spacing: 16) {
                        Text("What to expect")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))

                        ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Color.UseSense.primary)
                                    .clipShape(Circle())

                                Text(instruction)
                                    .font(.system(size: 15))
                                    .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                                    .padding(.top, 2)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(red: 0.969, green: 0.973, blue: 0.976))
                    .cornerRadius(12)
                    .padding(.horizontal, 24)

                    // Encryption badge
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color.UseSense.primary)

                        Text("End-to-end encrypted")
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Color.UseSense.primary.opacity(0.08))
                    .cornerRadius(20)

                    // Continue button
                    Button(action: onContinue) {
                        Text("Got it - Start")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.UseSense.primary)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                    Spacer().frame(height: 32)
                }
            }
        }
        .background(Color.white.ignoresSafeArea())
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
        case .followDot: return "Follow the Dot Challenge"
        case .headTurn: return "Head Turn Challenge"
        case .speakPhrase: return "Speak a Phrase Challenge"
        }
    }

    private var subtitle: String {
        switch challenge.challengeType {
        case .followDot:
            return "We'll ask you to follow a moving dot to verify your presence."
        case .headTurn:
            return "We'll ask you to turn your head to verify your presence."
        case .speakPhrase:
            return "We'll ask you to speak a phrase to verify your presence."
        }
    }

    private var instructions: [String] {
        switch challenge.challengeType {
        case .followDot:
            return [
                "Position your face in the camera frame",
                "A dot will appear on screen — follow it with your eyes",
                "Keep your head relatively still",
                "Make sure you're in a well-lit area"
            ]
        case .headTurn:
            return [
                "Position your face in the camera frame",
                "Turn your head in the directions shown on screen",
                "Follow the on-screen arrows smoothly",
                "Make sure you're in a well-lit area"
            ]
        case .speakPhrase:
            if case .speakPhrase(let c) = challenge {
                return [
                    "Position your face in the camera frame",
                    "Speak the phrase: \"\(c.phrase)\"",
                    "Make sure your environment is quiet",
                    "Make sure you're in a well-lit area"
                ]
            }
            return [
                "Position your face in the camera frame",
                "Speak the phrase shown on screen",
                "Make sure your environment is quiet",
                "Make sure you're in a well-lit area"
            ]
        }
    }
}
#endif
