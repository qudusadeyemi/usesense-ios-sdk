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
                USResultIcon(iconKind)
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

    private var iconKind: USResultIcon.Kind {
        switch kind {
        case .success: return .success
        case .review: return .review
        case .notVerified: return .error
        }
    }
    private var title: String {
        switch kind {
        case .success: return "Verification complete"
        case .review: return "Under review"
        case .notVerified: return "Not verified"
        }
    }
    private var subtitle: String {
        switch kind {
        case .success: return "Thank you. You can close this page."
        case .review: return "Your details are being reviewed."
        case .notVerified: return "We could not complete your verification."
        }
    }
}
#endif
