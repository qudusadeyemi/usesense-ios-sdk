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
                    Text("A few details")
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
            USButton("Continue", variant: .primary, size: .large, isLoading: model.isBusy) {
                onContinue()
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: FormField) -> some View {
        if field.type == .checkbox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: boolBinding(field.key)) {
                    Text(field.label ?? humanise(field.key))
                        .font(.usBody(15))
                        .foregroundColor(USColors.foreground)
                }
                .tint(brandColor)
                if let err = model.errors[field.key] {
                    Text(err).font(.usBody(12)).foregroundColor(USColors.criticalText)
                }
            }
        } else {
            USTextField(
                text: stringBinding(field.key),
                label: field.label ?? humanise(field.key),
                placeholder: field.placeholder ?? "",
                error: model.errors[field.key],
                keyboard: keyboard(for: field.type)
            )
        }
    }

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
#endif
