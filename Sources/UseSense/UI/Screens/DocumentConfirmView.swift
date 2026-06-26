#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - DocumentConfirmView
//
// Post-capture confirm step matching the hosted run page's DocConfirm: a preview
// of the captured document with Use / Retake (and an optional upload-instead).
// Pure presentation.

public struct DocumentConfirmView: View {
    private let image: UIImage
    private let brandColor: Color
    private let branding: USBrandingHeader?
    private let onUse: () -> Void
    private let onRetake: () -> Void
    private let onUploadInstead: (() -> Void)?

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
                Text("Check your document is clear")
                    .font(.usBody(15, .medium))
                    .foregroundColor(USColors.foreground)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)

                Color.clear
                    .aspectRatio(3.0 / 2.0, contentMode: .fit)
                    .overlay(
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    )
                    .background(USColors.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(USColors.border, lineWidth: 1)
                    )

                Spacer(minLength: 0)
            }
        } footer: {
            VStack(spacing: 12) {
                USButton("Use this photo", variant: .primary, size: .large, action: onUse)
                USButton("Retake", variant: .secondary, size: .large, action: onRetake)
                if let onUploadInstead {
                    Button(action: onUploadInstead) {
                        Text("Upload a different file")
                            .font(.usBody(12))
                            .foregroundColor(USColors.mutedForeground)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(USPressStyle())
                }
            }
        }
    }
}
#endif
