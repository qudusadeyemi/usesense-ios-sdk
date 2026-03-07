#if canImport(SwiftUI)
import SwiftUI

struct CountdownOverlay: View {
    let number: Int

    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            Text("\(number)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .scaleEffect(scale)
                .opacity(opacity)
                .onAppear {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                        scale = 1.0
                        opacity = 1.0
                    }
                }
                .onChange(of: number) { _ in
                    scale = 0.3
                    opacity = 0
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                        scale = 1.0
                        opacity = 1.0
                    }
                }
        }
    }
}
#endif
