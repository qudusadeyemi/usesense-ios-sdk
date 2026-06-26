#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - USResultIcon
//
// Large animated outcome badge for result screens: success (green), error (red),
// review (gold). Draws on with the brand spring.

public struct USResultIcon: View {
    public enum Kind { case success, error, review }

    private let kind: Kind
    @State private var shown = false

    public init(_ kind: Kind) { self.kind = kind }

    public var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.12)).frame(width: 104, height: 104)
            Circle().fill(tint).frame(width: 68, height: 68)
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
        }
        .scaleEffect(shown ? 1 : 0.6)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(UseSenseMotion.ease.delay(0.05)) { shown = true }
        }
    }

    private var tint: Color {
        switch kind {
        case .success: return USColors.success
        case .error:   return USColors.destructive
        case .review:  return USColors.warning
        }
    }
    private var symbol: String {
        switch kind {
        case .success: return "checkmark"
        case .error:   return "xmark"
        case .review:  return "clock.fill"
        }
    }
}
#endif
