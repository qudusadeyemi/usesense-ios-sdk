#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - FlowResultView
//
// Terminal outcome screen matching the hosted run page exactly (icon + title +
// subtitle + optional continue): APPROVE / MANUAL_REVIEW / not-verified.

public struct FlowResultView: View {
    public enum Kind { case success, review, notVerified }

    private let kind: Kind
    private let continueTitle: String?
    private let onContinue: (() -> Void)?
    private let branding: USBrandingHeader?

    public init(
        kind: Kind,
        continueTitle: String? = nil,
        onContinue: (() -> Void)? = nil,
        branding: USBrandingHeader? = nil
    ) {
        self.kind = kind
        self.continueTitle = continueTitle
        self.onContinue = onContinue
        self.branding = branding
    }

    public var body: some View {
        USScreenScaffold(branding: branding) {
            VStack(spacing: 16) {
                Spacer()
                resultIllustration
                Text(title)
                    .font(.usDisplay(24, .bold))
                    .foregroundColor(USColors.foreground)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(USType.body)
                    .foregroundColor(USColors.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } footer: {
            if let continueTitle, let onContinue {
                USButton(continueTitle, variant: .primary, size: .large, action: onContinue)
            }
        }
    }

    /// A custom result illustration (`icons.success`/`.review`/`.notVerified`)
    /// when the appearance sets one for this kind, else the built-in result glyph.
    /// Presentation-only white-label override (Phase 5).
    @ViewBuilder private var resultIllustration: some View {
        if let url = FlowAppearanceResolver.icon(for: iconSlot) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                USResultIcon(iconKind)
            }
            .frame(width: 104, height: 104)
        } else {
            USResultIcon(iconKind)
        }
    }

    private var iconSlot: String {
        switch kind {
        case .success: return "success"
        case .review: return "review"
        case .notVerified: return "notVerified"
        }
    }
    private var iconKind: USResultIcon.Kind {
        switch kind {
        case .success: return .success
        case .review: return .review
        case .notVerified: return .error
        }
    }
    private var title: String {
        switch kind {
        case .success: return FlowCopyResolver.text(\.result?.successTitle, default: "Verification complete")
        case .review: return FlowCopyResolver.text(\.result?.reviewTitle, default: "Under review")
        case .notVerified: return FlowCopyResolver.text(\.result?.notVerifiedTitle, default: "Not verified")
        }
    }
    private var subtitle: String {
        switch kind {
        case .success: return FlowCopyResolver.text(\.result?.successBody, default: "Thank you. You can close this page.")
        case .review: return FlowCopyResolver.text(\.result?.reviewBody, default: "Your details are being reviewed.")
        case .notVerified: return FlowCopyResolver.text(\.result?.notVerifiedBody, default: "We could not complete your verification.")
        }
    }
}

#if DEBUG
#Preview("Result success — Light") { FlowResultView(kind: .success, continueTitle: "Continue", onContinue: {}) }
#Preview("Result success — Dark") { FlowResultView(kind: .success, continueTitle: "Continue", onContinue: {}).preferredColorScheme(.dark) }
#Preview("Result review") { FlowResultView(kind: .review) }
#Preview("Result not verified") { FlowResultView(kind: .notVerified) }
#endif
#endif
