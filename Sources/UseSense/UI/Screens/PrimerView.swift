#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - PrimerView
//
// Generic pre-step primer matching the hosted run page's `Primer` (icon tile,
// title, "why", concrete do's, optional note, primary + optional secondary CTA).
// Face and document steps both use it. Pure presentation.

public struct PrimerPoint: Identifiable {
    public let id = UUID()
    public let icon: String   // SF Symbol name
    public let text: String
    public init(icon: String, text: String) { self.icon = icon; self.text = text }
}

public struct PrimerView: View {
    private let iconSystemName: String
    private let title: String
    private let subtitle: String?
    private let points: [PrimerPoint]
    private let note: String?
    private let primaryTitle: String
    private let primaryAction: () -> Void
    private let secondaryTitle: String?
    private let secondaryAction: (() -> Void)?
    private let isBusy: Bool
    private let brandColor: Color
    private let branding: USBrandingHeader?

    public init(
        iconSystemName: String,
        title: String,
        subtitle: String? = nil,
        points: [PrimerPoint] = [],
        note: String? = nil,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        isBusy: Bool = false,
        brandColor: Color = USColors.primary,
        branding: USBrandingHeader? = nil
    ) {
        self.iconSystemName = iconSystemName
        self.title = title
        self.subtitle = subtitle
        self.points = points
        self.note = note
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
        self.isBusy = isBusy
        self.brandColor = brandColor
        self.branding = branding
    }

    public var body: some View {
        USScreenScaffold(branding: branding) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(brandColor.opacity(0.08))
                        .frame(width: 56, height: 56)
                    Image(systemName: iconSystemName)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(brandColor)
                }
                .padding(.bottom, 20)

                Text(title)
                    .font(.usDisplay(24, .bold))
                    .foregroundColor(USColors.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(USType.body)
                        .foregroundColor(USColors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }

                if !points.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(points) { point in
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    Circle().fill(USColors.secondary).frame(width: 32, height: 32)
                                    Image(systemName: point.icon)
                                        .font(.system(size: 14))
                                        .foregroundColor(USColors.mutedForeground)
                                }
                                Text(point.text)
                                    .font(.usBody(14))
                                    .foregroundColor(USColors.foreground)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, 28)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } footer: {
            VStack(spacing: 12) {
                if let note {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 14))
                            .foregroundColor(USColors.mutedForeground)
                        Text(note)
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
                }

                USButton(primaryTitle, variant: .primary, size: .large, isLoading: isBusy, action: primaryAction)

                if let secondaryTitle, let secondaryAction {
                    USButton(secondaryTitle, variant: .secondary, size: .large, action: secondaryAction)
                }
            }
        }
    }
}
#endif
