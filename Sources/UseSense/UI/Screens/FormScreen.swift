#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import Combine

// MARK: - FormScreen
//
// "A few details" — the typed-field form, matching the hosted run page's
// FieldForm on the Phase 0 kit (brand inputs + inline errors). Validation /
// coercion stays in the flow runner (single source); this screen collects values
// and renders errors via FormModel.

@MainActor public final class FormModel: ObservableObject {
    public let fields: [FormField]
    @Published public var values: [String: String] = [:]
    @Published public var booleans: [String: Bool] = [:]
    @Published public var errors: [String: String] = [:]
    @Published public var isBusy: Bool = false

    public init(fields: [FormField], serverErrors: [String: String] = [:]) {
        self.fields = fields
        self.errors = serverErrors
    }

    /// Raw value the runner validates/coerces: Bool for checkbox, String otherwise.
    public func rawValue(for field: FormField) -> Any {
        if field.type == .checkbox { return booleans[field.key] ?? false }
        return values[field.key] ?? ""
    }
}

public struct FormScreen: View {
    @ObservedObject private var model: FormModel
    private let brandColor: Color
    private let branding: USBrandingHeader?
    private let onContinue: () -> Void

    public init(
        model: FormModel,
        brandColor: Color = USColors.primary,
        branding: USBrandingHeader? = nil,
        onContinue: @escaping () -> Void
    ) {
        self.model = model
        self.brandColor = brandColor
        self.branding = branding
        self.onContinue = onContinue
    }

    public var body: some View {
        USScreenScaffold(branding: branding) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(FlowCopyResolver.text(\.form?.title, default: "A few details"))
                        .font(.usDisplay(24, .bold))
                        .foregroundColor(USColors.foreground)
                    ForEach(model.fields, id: \.key) { field in
                        fieldView(field)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        } footer: {
            USButton(FlowCopyResolver.text(\.buttons?.continue, default: "Continue"), variant: .primary, size: .large, isLoading: model.isBusy) {
                onContinue()
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: FormField) -> some View {
        switch field.type {
        case .checkbox:
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: boolBinding(field.key)) {
                    Text(field.label ?? humanise(field.key))
                        .font(.usBody(15))
                        .foregroundColor(USColors.foreground)
                }
                .tint(brandColor)
                fieldError(field.key)
            }
        case .select, .country:
            selectRow(field)
        case .date:
            dateRow(field)
        default:
            USTextField(
                text: stringBinding(field.key),
                label: field.label ?? humanise(field.key),
                placeholder: field.placeholder ?? "",
                error: model.errors[field.key],
                keyboard: keyboard(for: field.type)
            )
        }
    }

    @ViewBuilder private func fieldError(_ key: String) -> some View {
        if let err = model.errors[key] {
            Text(err).font(.usBody(12)).foregroundColor(USColors.criticalText)
        }
    }

    private func fieldLabel(_ field: FormField) -> some View {
        Text(field.label ?? humanise(field.key))
            .font(.usBody(13, .medium))
            .foregroundColor(USColors.foreground)
    }

    private func boxBorder(_ key: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(model.errors[key] != nil ? USColors.destructive : USColors.border, lineWidth: 1)
    }

    private func selectOptions(_ field: FormField) -> [FormField.Option] {
        if let options = field.options, !options.isEmpty { return options }
        if let countries = field.allowedCountries, !countries.isEmpty {
            return countries.map { FormField.Option(value: $0, label: $0) }
        }
        return []
    }

    private func selectRow(_ field: FormField) -> some View {
        let options = selectOptions(field)
        let current = options.first { $0.value == (model.values[field.key] ?? "") }
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel(field)
            Menu {
                ForEach(options, id: \.value) { opt in
                    Button(opt.label) { model.values[field.key] = opt.value }
                }
            } label: {
                HStack {
                    Text(current?.label ?? (field.placeholder ?? "Select"))
                        .font(.usBody(16))
                        .foregroundColor(current == nil ? USColors.mutedForeground : USColors.foreground)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(USColors.mutedForeground)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(USColors.card)
                .overlay(boxBorder(field.key))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            fieldError(field.key)
        }
    }

    private func dateRow(_ field: FormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(field)
            HStack {
                DatePicker("", selection: dateBinding(field.key), displayedComponents: .date)
                    .labelsHidden()
                    .tint(brandColor)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(USColors.card)
            .overlay(boxBorder(field.key))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            fieldError(field.key)
        }
    }

    private func dateBinding(_ key: String) -> Binding<Date> {
        Binding(
            get: { Self.dateFormatter.date(from: model.values[key] ?? "") ?? Date() },
            set: { model.values[key] = Self.dateFormatter.string(from: $0) }
        )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: { model.values[key] ?? "" }, set: { model.values[key] = $0 })
    }
    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { model.booleans[key] ?? false }, set: { model.booleans[key] = $0 })
    }

    private func keyboard(for type: FormFieldType) -> UIKeyboardType {
        switch type {
        case .number: return .numberPad
        case .email: return .emailAddress
        case .tel: return .phonePad
        default: return .default
        }
    }

    private func humanise(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

#if DEBUG
#Preview("Form — Light") { FormScreen(model: PreviewSamples.formModel(), onContinue: {}) }
#Preview("Form — Dark") { FormScreen(model: PreviewSamples.formModel(), onContinue: {}).preferredColorScheme(.dark) }
#endif
#endif
