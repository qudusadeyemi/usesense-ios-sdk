#if canImport(SwiftUI)
import SwiftUI

struct ProcessingView: View {
    let label: String
    let progress: Double?

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)

            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(UseSenseTheme.Colors.indigo500)

                Text(label)
                    .font(.headline)
                    .foregroundColor(.white)

                if let progress = progress, progress > 0 && progress < 1 {
                    ProgressView(value: progress)
                        .tint(UseSenseTheme.Colors.indigo500)
                        .frame(width: 200)
                }
            }
        }
    }
}
#endif
