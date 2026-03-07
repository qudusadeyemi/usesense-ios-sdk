#if canImport(SwiftUI)
import SwiftUI

struct CountdownOverlay: View {
    let number: Int
    let label: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)

            VStack(spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 64, weight: .black))
                    .foregroundColor(UseSenseTheme.Colors.indigo600)
                    .frame(width: 112, height: 112)
                    .background(Circle().fill(Color.white.opacity(0.95)))
                    .shadow(radius: 12)
                    .scaleEffect(scaleForNumber)
                    .animation(.interpolatingSpring(stiffness: 200, damping: 12), value: number)

                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number). \(label)")
    }

    private var scaleForNumber: CGFloat {
        // Pop effect
        1.0
    }
}
#endif
