#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - USTextField
//
// Brand text input matching the hosted form fields: DM Sans, 12pt radius, warm
// border that turns brand-blue on focus (the hosted focus ring) and critical-red
// on error, with an optional label and inline error message.

public struct USTextField: View {
    private let label: String?
    @Binding private var text: String
    private let placeholder: String
    private let error: String?
    private let keyboard: UIKeyboardType

    @FocusState private var focused: Bool

    public init(
        text: Binding<String>,
        label: String? = nil,
        placeholder: String = "",
        error: String? = nil,
        keyboard: UIKeyboardType = .default
    ) {
        _text = text
        self.label = label
        self.placeholder = placeholder
        self.error = error
        self.keyboard = keyboard
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(.usBody(13, .medium))
                    .foregroundColor(USColors.foreground)
            }
            TextField(placeholder, text: $text)
                .font(.usBody(16))
                .foregroundColor(USColors.foreground)
                .keyboardType(keyboard)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(USColors.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: (focused || error != nil) ? 2 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .animation(UseSenseMotion.ease, value: focused)
            if let error {
                Text(error)
                    .font(.usBody(12))
                    .foregroundColor(USColors.criticalText)
            }
        }
    }

    private var borderColor: Color {
        if error != nil { return USColors.destructive }
        return focused ? USColors.primary : USColors.border
    }
}
#endif
