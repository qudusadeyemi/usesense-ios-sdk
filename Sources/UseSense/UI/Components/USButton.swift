#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - USButton
//
// Brand button matching the hosted page: DeepSense-blue primary, warm secondary,
// ghost; heights 36/44/52, 10pt radius, DM Sans 600 label, pressed scale + the
// brand spring, and an inline loading state.

public struct USButton: View {
    public enum Variant { case primary, secondary, ghost }
    public enum Size {
        case small, `default`, large
        var height: CGFloat { switch self { case .small: 36; case .default: 44; case .large: 52 } }
        var hPadding: CGFloat { switch self { case .small: 14; case .default: 18; case .large: 22 } }
    }

    private let title: String
    private let icon: String?
    private let variant: Variant
    private let size: Size
    private let fullWidth: Bool
    private let isLoading: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        icon: String? = nil,
        variant: Variant = .primary,
        size: Size = .default,
        fullWidth: Bool = true,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.size = size
        self.fullWidth = fullWidth
        self.isLoading = isLoading
        self.action = action
    }

    /// Resolved corner radius — appearance.shape.buttonRadius/radius, else 10pt.
    private var radius: CGFloat { FlowAppearanceResolver.buttonRadius }
    /// Whether the operator chose the outline button style for primary CTAs.
    private var primaryOutlined: Bool { FlowAppearanceResolver.buttonOutlined }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(foreground)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                }
                Text(title).font(USType.button)
            }
            .foregroundColor(foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: size.height)
            .padding(.horizontal, size.hPadding)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: hasBorder ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(USPressStyle())
        .disabled(isLoading)
    }

    /// In `outline` button style a primary CTA renders as an outlined chip
    /// (transparent fill, brand-tinted border + label) instead of a solid fill.
    private var isOutlinePrimary: Bool { variant == .primary && primaryOutlined }

    private var background: Color {
        switch variant {
        case .primary:   return isOutlinePrimary ? .clear : USColors.primary
        case .secondary: return USColors.secondary
        case .ghost:     return .clear
        }
    }
    private var foreground: Color {
        switch variant {
        case .primary:   return isOutlinePrimary ? USColors.primary : USColors.primaryForeground
        case .secondary: return USColors.foreground
        case .ghost:     return USColors.primary
        }
    }
    private var hasBorder: Bool { variant == .secondary || isOutlinePrimary }
    private var borderColor: Color {
        if isOutlinePrimary { return USColors.primary }
        return variant == .secondary ? USColors.border : .clear
    }
}

/// Press feedback shared by brand controls — subtle scale + dim on the brand spring.
public struct USPressStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(UseSenseMotion.ease, value: configuration.isPressed)
    }
}
#endif
