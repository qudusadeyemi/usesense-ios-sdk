#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - USScreenScaffold
//
// Standard immersive screen container the rebuilt capture screens reuse: brand
// background, safe-area-aware padding, an optional branding header at the top and
// a pinned footer (e.g. the primary CTA).

public struct USScreenScaffold<Content: View, Footer: View>: View {
    private let branding: USBrandingHeader?
    private let content: () -> Content
    private let footer: () -> Footer

    public init(
        branding: USBrandingHeader? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.branding = branding
        self.content = content
        self.footer = footer
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let branding {
                branding.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
            footer()
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .background(backgroundLayer.ignoresSafeArea())
    }

    /// The brand background, with an optional appearance background image painted
    /// over the resolved background color (white-label Phase 1c). The image is
    /// scaled to fill; the color shows while it loads and as a fallback.
    @ViewBuilder private var backgroundLayer: some View {
        ZStack {
            USColors.background
            if let url = FlowAppearanceResolver.backgroundImageURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
    }
}
#endif
