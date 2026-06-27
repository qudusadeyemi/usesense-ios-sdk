#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - IdNumberView
//
// "Select an option" — the ID-number step, matching the hosted run page's
// IdNumberFlow (ID-type chooser + a typed value field). Pure presentation.

public struct IdTypeOption: Identifiable {
    public let id = UUID()
    public let value: String
    public let label: String
    public let hint: String?
    public let field: String
    public let maxLength: Int?
    public let numeric: Bool

    public init(value: String, label: String, hint: String? = nil, field: String, maxLength: Int? = nil, numeric: Bool = false) {
        self.value = value
        self.label = label
        self.hint = hint
        self.field = field
        self.maxLength = maxLength
        self.numeric = numeric
    }
}

public struct IdNumberView: View {
    private let idTypes: [IdTypeOption]
    private let isBusy: Bool
    private let brandColor: Color
    private let branding: USBrandingHeader?
    private let onSubmit: (_ idType: String, _ field: String, _ value: String) -> Void

    @State private var chosen: String?
    @State private var value: String = ""

    public init(
        idTypes: [IdTypeOption],
        isBusy: Bool = false,
        brandColor: Color = USColors.primary,
        branding: USBrandingHeader? = nil,
        onSubmit: @escaping (_ idType: String, _ field: String, _ value: String) -> Void
    ) {
        self.idTypes = idTypes
        self.isBusy = isBusy
        self.brandColor = brandColor
        self.branding = branding
        self.onSubmit = onSubmit
        _chosen = State(initialValue: idTypes.count == 1 ? idTypes.first?.value : nil)
    }

    private var selected: IdTypeOption? { idTypes.first { $0.value == chosen } }

    private var tooShort: Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let maxLength = selected?.maxLength { return trimmed.count < maxLength }
        return trimmed.isEmpty
    }

    public var body: some View {
        USScreenScaffold(branding: branding) {
            VStack(alignment: .leading, spacing: 0) {
                Text(FlowCopyResolver.text(\.idNumber?.title, default: "Select an option"))
                    .font(.usDisplay(24, .bold))
                    .foregroundColor(USColors.foreground)
                Text(FlowCopyResolver.text(\.idNumber?.body, default: "Choose the type of ID to validate."))
                    .font(USType.body)
                    .foregroundColor(USColors.mutedForeground)
                    .padding(.top, 6)

                VStack(spacing: 8) {
                    ForEach(idTypes) { option in
                        typeRow(option)
                    }
                }
                .padding(.top, 24)

                if let selected {
                    USTextField(
                        text: $value,
                        label: "Enter your \(selected.label)",
                        placeholder: selected.hint ?? "",
                        keyboard: selected.numeric ? .numberPad : .default
                    )
                    .padding(.top, 20)
                    .onChange(of: value) { newValue in
                        applyConstraints(newValue, option: selected)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } footer: {
            USButton(FlowCopyResolver.text(\.buttons?.continue, default: "Continue"), variant: .primary, size: .large, isLoading: isBusy) {
                submit()
            }
        }
    }

    private func typeRow(_ option: IdTypeOption) -> some View {
        let isSelected = option.value == chosen
        return Button {
            chosen = option.value
            value = ""
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(USColors.secondary)
                        .frame(width: 36, height: 36)
                    Image(systemName: "number")
                        .font(.system(size: 16))
                        .foregroundColor(USColors.mutedForeground)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.usBody(15, .medium))
                        .foregroundColor(USColors.foreground)
                    if let hint = option.hint {
                        Text(hint)
                            .font(.usBody(12))
                            .foregroundColor(USColors.mutedForeground)
                    }
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? brandColor : USColors.borderStrong, lineWidth: 2)
                        .frame(width: 20, height: 20)
                    if isSelected {
                        Circle().fill(brandColor).frame(width: 10, height: 10)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(isSelected ? brandColor.opacity(0.04) : USColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? brandColor : USColors.border, lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(USPressStyle())
    }

    private func applyConstraints(_ newValue: String, option: IdTypeOption) {
        var next = newValue
        if option.numeric {
            next = next.filter { $0.isNumber }
        }
        if let maxLength = option.maxLength, next.count > maxLength {
            next = String(next.prefix(maxLength))
        }
        if next != value { value = next }
    }

    private func submit() {
        guard let selected, !tooShort else { return }
        onSubmit(selected.value, selected.field, value.trimmingCharacters(in: .whitespaces))
    }
}

#if DEBUG
#Preview("ID number — Light") { IdNumberView(idTypes: PreviewSamples.idTypes, onSubmit: { _, _, _ in }) }
#Preview("ID number — Dark") { IdNumberView(idTypes: PreviewSamples.idTypes, onSubmit: { _, _, _ in }).preferredColorScheme(.dark) }
#endif
#endif
