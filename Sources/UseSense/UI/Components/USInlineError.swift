#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - USInlineError
//
// Concise inline error chip — critical-red tint background, never a raw stack/code.

public struct USInlineError: View {
    private let message: String
    private let icon: String

    public init(_ message: String, icon: String = "exclamationmark.triangle.fill") {
        self.message = message
        self.icon = icon
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
            Text(message).font(.usBody(14, .medium))
        }
        .foregroundColor(USColors.criticalText)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(USColors.criticalBg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
#endif
