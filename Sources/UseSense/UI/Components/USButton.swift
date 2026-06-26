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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: variant == .secondary ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(USPressStyle())
        .disabled(isLoading)
    }

    private var background: Color {
        switch variant {
        case .primary:   return USColors.primary
        case .secondary: return USColors.secondary
        case .ghost:     return .clear
        }
    }
    private var foreground: Color {
        switch variant {
        case .primary:   return .white
        case .secondary: return USColors.foreground
        case .ghost:     return USColors.primary
        }
    }
    private var borderColor: Color { variant == .secondary ? USColors.border : .clear }
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
