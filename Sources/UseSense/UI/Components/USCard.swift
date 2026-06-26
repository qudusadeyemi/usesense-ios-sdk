#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - USCard
//
// Soft elevated surface matching the hosted page cards: white/dark card token,
// large radius, gentle shadow.

public struct USCard<Content: View>: View {
    private let padding: CGFloat
    private let radius: CGFloat
    private let content: () -> Content

    public init(padding: CGFloat = 20, radius: CGFloat = 18, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.radius = radius
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(USColors.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 12, x: 0, y: 4)
    }
}
#endif
