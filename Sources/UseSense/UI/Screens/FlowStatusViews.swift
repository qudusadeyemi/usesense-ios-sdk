#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - FlowLoadingView
//
// Branded loading screen (link resolution / busy), matching the hosted page's
// centered spinner + title.

public struct FlowLoadingView: View {
    private let title: String
    private let branding: USBrandingHeader?

    public init(title: String = "Loading", branding: USBrandingHeader? = nil) {
        self.title = title
        self.branding = branding
    }

    public var body: some View {
        USScreenScaffold(branding: branding) {
            VStack(spacing: 18) {
                Spacer()
                USBrandSpinner()
                Text(title)
                    .font(.usDisplay(20, .bold))
                    .foregroundColor(USColors.foreground)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - FlowErrorView
//
// Friendly terminal/error screen — never a raw stack or code.

public struct FlowErrorView: View {
    private let title: String
    private let message: String
    private let retryTitle: String?
    private let onRetry: (() -> Void)?
    private let branding: USBrandingHeader?

    public init(
        title: String = "Unavailable",
        message: String,
        retryTitle: String? = nil,
        onRetry: (() -> Void)? = nil,
        branding: USBrandingHeader? = nil
    ) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.onRetry = onRetry
        self.branding = branding
    }

    public var body: some View {
        USScreenScaffold(branding: branding) {
            VStack(spacing: 16) {
                Spacer()
                ZStack {
                    Circle().fill(USColors.warning.opacity(0.12)).frame(width: 88, height: 88)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundColor(USColors.warning)
                }
                Text(title)
                    .font(.usDisplay(22, .bold))
                    .foregroundColor(USColors.foreground)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(USType.body)
                    .foregroundColor(USColors.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } footer: {
            if let retryTitle, let onRetry {
                USButton(retryTitle, variant: .primary, size: .large, action: onRetry)
            }
        }
    }
}

// MARK: - USBrandSpinner

/// Brand-blue indeterminate ring used on loading / processing surfaces.
public struct USBrandSpinner: View {
    private let size: CGFloat
    @State private var spinning = false

    public init(size: CGFloat = 48) { self.size = size }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(USColors.border, lineWidth: 4)
                .frame(width: size, height: size)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(USColors.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
        }
        .onAppear { spinning = true }
    }
}

#if DEBUG
#Preview("Loading — Light") { FlowLoadingView() }
#Preview("Loading — Dark") { FlowLoadingView().preferredColorScheme(.dark) }
#Preview("Error — Light") { FlowErrorView(message: "This link is invalid or has expired.", retryTitle: "Try again", onRetry: {}) }
#Preview("Error — Dark") { FlowErrorView(message: "This link is invalid or has expired.", retryTitle: "Try again", onRetry: {}).preferredColorScheme(.dark) }
#endif
#endif
