#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import Combine

// MARK: - FacePrimerView
//
// Pre-capture primer for the face/liveness step, matching the hosted run page's
// FacePrimer exactly (copy + layout): an icon tile, the "why", concrete do's, a
// privacy note, and a single primary CTA. Sets expectations before the camera
// opens. Pure presentation — no capture logic.

public struct FacePrimerView: View {
    private let brandColor: Color
    private let isBusy: Bool
    private let branding: USBrandingHeader?
    private let onStart: () -> Void

    public init(
        brandColor: Color = USColors.primary,
        isBusy: Bool = false,
        branding: USBrandingHeader? = nil,
        onStart: @escaping () -> Void
    ) {
        self.brandColor = brandColor
        self.isBusy = isBusy
        self.branding = branding
        self.onStart = onStart
    }

    public var body: some View {
        USScreenScaffold(branding: branding) {
            VStack(alignment: .leading, spacing: 0) {
                // Icon tile — 56pt rounded tile tinted with the brand colour.
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(brandColor.opacity(0.08))
                        .frame(width: 56, height: 56)
                    Image(systemName: "faceid")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(brandColor)
                }
                .padding(.bottom, 20)

                Text(FlowCopyResolver.text(\.face?.title, default: "Take a selfie"))
                    .font(.usDisplay(24, .bold))
                    .foregroundColor(USColors.foreground)

                Text(FlowCopyResolver.text(\.face?.body, default: "A quick, secure face scan confirms you're a real, live person."))
                    .font(USType.body)
                    .foregroundColor(USColors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 16) {
                    primerPoint(icon: "eye", text: "Face forward and make sure your eyes are clearly visible.")
                    primerPoint(icon: "eyeglasses", text: "Remove anything that covers your face. Eyeglasses are okay.")
                }
                .padding(.top, 28)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } footer: {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 14))
                        .foregroundColor(USColors.mutedForeground)
                    Text(FlowCopyResolver.text(\.privacy?.disclosure, default: "Your face and surroundings are captured during this check and processed securely."))
                        .font(.usBody(12))
                        .foregroundColor(USColors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(USColors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(USColors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                USButton(FlowCopyResolver.text(\.face?.start, default: "Start face scan"), variant: .primary, size: .large, isLoading: isBusy, action: onStart)
            }
        }
    }

    private func primerPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(USColors.secondary).frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(USColors.mutedForeground)
            }
            Text(text)
                .font(.usBody(14))
                .foregroundColor(USColors.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Flow integration

/// Drives the primer's CTA busy state while the flow runner mints the capture
/// session, so the button shows progress before the camera opens.
@MainActor public final class FacePrimerModel: ObservableObject {
    @Published public var isBusy = false
    public init() {}
}

/// Hostable wrapper (for UIHostingController) that binds [FacePrimerModel].
public struct FacePrimerContainer: View {
    @ObservedObject private var model: FacePrimerModel
    private let brandColor: Color
    private let branding: USBrandingHeader?
    private let onStart: () -> Void

    public init(model: FacePrimerModel, brandColor: Color = USColors.primary, branding: USBrandingHeader? = nil, onStart: @escaping () -> Void) {
        self.model = model
        self.brandColor = brandColor
        self.branding = branding
        self.onStart = onStart
    }

    public var body: some View {
        FacePrimerView(brandColor: brandColor, isBusy: model.isBusy, branding: branding, onStart: onStart)
    }
}

#if DEBUG
#Preview("Face primer — Light") { FacePrimerView(onStart: {}) }
#Preview("Face primer — Dark") { FacePrimerView(onStart: {}).preferredColorScheme(.dark) }
#endif
#endif
