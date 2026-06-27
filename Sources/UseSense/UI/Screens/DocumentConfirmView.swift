#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - DocumentConfirmView
//
// Post-capture confirm step matching the hosted run page's DocConfirm: a preview
// of the captured document plus a client-side quality check (DocumentQuality). A
// detected issue surfaces a warning and flips the CTAs to Retake / Use anyway.
// Pure presentation.

public struct DocumentConfirmView: View {
    private let image: UIImage
    private let brandColor: Color
    private let branding: USBrandingHeader?
    private let onUse: () -> Void
    private let onRetake: () -> Void
    private let onUploadInstead: (() -> Void)?

    @State private var checking = true
    @State private var issue: DocumentQualityIssue?

    public init(
        image: UIImage,
        brandColor: Color = USColors.primary,
        branding: USBrandingHeader? = nil,
        onUse: @escaping () -> Void,
        onRetake: @escaping () -> Void,
        onUploadInstead: (() -> Void)? = nil
    ) {
        self.image = image
        self.brandColor = brandColor
        self.branding = branding
        self.onUse = onUse
        self.onRetake = onRetake
        self.onUploadInstead = onUploadInstead
    }

    public var body: some View {
        USScreenScaffold(branding: branding) {
            VStack(spacing: 14) {
                Text(FlowCopyResolver.text(\.document?.confirmTitle, default: "Check your document is clear"))
                    .font(.usBody(15, .medium))
                    .foregroundColor(USColors.foreground)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)

                if let issue { issueBanner(issue) }

                ZStack {
                    Color.clear
                        .aspectRatio(3.0 / 2.0, contentMode: .fit)
                        .overlay(Image(uiImage: image).resizable().scaledToFit())
                        .background(USColors.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(USColors.border, lineWidth: 1)
                        )

                    if checking {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.4))
                            VStack(spacing: 8) {
                                ProgressView().tint(.white)
                                Text(FlowCopyResolver.text(\.loading?.checkingQuality, default: "Checking image quality…")).font(.usBody(13)).foregroundColor(.white)
                            }
                        }
                        .aspectRatio(3.0 / 2.0, contentMode: .fit)
                    }
                }

                Spacer(minLength: 0)
            }
        } footer: {
            VStack(spacing: 12) {
                if issue != nil {
                    USButton(FlowCopyResolver.text(\.buttons?.retake, default: "Retake"), variant: .primary, size: .large, action: onRetake)
                    USButton("Use anyway", variant: .secondary, size: .large, action: onUse)
                } else {
                    USButton(FlowCopyResolver.text(\.buttons?.useThisPhoto, default: "Use this photo"), variant: .primary, size: .large, isLoading: checking, action: onUse)
                    USButton(FlowCopyResolver.text(\.buttons?.retake, default: "Retake"), variant: .secondary, size: .large, action: onRetake)
                }
                if let onUploadInstead {
                    Button(action: onUploadInstead) {
                        Text(FlowCopyResolver.text(\.buttons?.uploadInstead, default: "Upload a different file"))
                            .font(.usBody(12))
                            .foregroundColor(USColors.mutedForeground)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(USPressStyle())
                }
            }
        }
        .onAppear(perform: runQualityCheck)
    }

    private func issueBanner(_ issue: DocumentQualityIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(USColors.destructive).frame(width: 20, height: 20)
                Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.usBody(14, .semibold)).foregroundColor(USColors.criticalText)
                Text(issue.detail).font(.usBody(12)).foregroundColor(USColors.criticalText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(USColors.criticalBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func runQualityCheck() {
        let img = image
        Task.detached(priority: .userInitiated) {
            let result = DocumentQuality.assess(img)
            await MainActor.run {
                self.issue = result
                self.checking = false
            }
        }
    }
}

#if DEBUG
#Preview("Doc confirm — Light") { DocumentConfirmView(image: PreviewSamples.placeholderImage, onUse: {}, onRetake: {}, onUploadInstead: {}) }
#Preview("Doc confirm — Dark") { DocumentConfirmView(image: PreviewSamples.placeholderImage, onUse: {}, onRetake: {}, onUploadInstead: {}).preferredColorScheme(.dark) }
#endif
#endif
