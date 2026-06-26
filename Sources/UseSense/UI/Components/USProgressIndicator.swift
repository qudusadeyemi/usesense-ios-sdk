#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - USProgressIndicator
//
// Slim stepped progress bar for multi-step flows — animated brand-blue fill,
// mirroring the hosted page's step chrome.

public struct USProgressIndicator: View {
    private let total: Int
    private let current: Int   // 1-based index of the active step

    public init(total: Int, current: Int) {
        self.total = max(total, 1)
        self.current = current
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i < current ? USColors.primary : USColors.border)
                    .frame(height: 4)
                    .animation(UseSenseMotion.ease, value: current)
            }
        }
    }
}
#endif
