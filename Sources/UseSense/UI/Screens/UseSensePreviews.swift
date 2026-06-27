#if DEBUG && canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - SwiftUI Previews for the UI-parity screens
//
// Lets every parity surface be eyeballed in the Xcode canvas (light + dark)
// without a live flow, device, or camera. DEBUG-only; never shipped in release.

private enum PreviewSamples {
    static let docTypes = ["Passport", "Driver's License", "National ID card"]

    static let idTypes: [IdTypeOption] = [
        IdTypeOption(value: "nin", label: "NIN", hint: "Your 11-digit National ID number", field: "id_number", maxLength: 11, numeric: true),
        IdTypeOption(value: "bvn", label: "BVN", hint: "Your 11-digit Bank Verification Number", field: "id_number", maxLength: 11, numeric: true),
    ]

    @MainActor static func formModel() -> FormModel {
        FormModel(fields: [
            FormField(key: "first_name", type: .text, label: "First name", hint: nil, placeholder: "Ada", required: true, initial: nil, validators: nil, options: nil, allowedCountries: nil),
            FormField(key: "country", type: .country, label: "Country", hint: nil, placeholder: nil, required: true, initial: nil, validators: nil, options: nil, allowedCountries: ["NG", "GH", "KE"]),
            FormField(key: "dob", type: .date, label: "Date of birth", hint: nil, placeholder: nil, required: true, initial: nil, validators: nil, options: nil, allowedCountries: nil),
            FormField(key: "consent", type: .checkbox, label: "I agree to the terms", hint: nil, placeholder: nil, required: true, initial: nil, validators: nil, options: nil, allowedCountries: nil),
        ])
    }

    static var placeholderImage: UIImage {
        let size = CGSize(width: 600, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.85, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            (UIImage(systemName: "doc.text") ?? UIImage()).withTintColor(.darkGray).draw(in: CGRect(x: 250, y: 150, width: 100, height: 100))
        }
    }
}

// FacePrimer
#Preview("Face primer — Light") { FacePrimerView(onStart: {}) }
#Preview("Face primer — Dark") { FacePrimerView(onStart: {}).preferredColorScheme(.dark) }

// Document primer
#Preview("Doc primer — Light") {
    DocumentPrimerView(documentType: "Passport", issuingCountries: ["NG", "GH"], onPrimary: {}, onSecondary: {})
}
#Preview("Doc primer — Dark") {
    DocumentPrimerView(documentType: "Passport", issuingCountries: ["NG", "GH"], onPrimary: {}, onSecondary: {}).preferredColorScheme(.dark)
}

// Document type select
#Preview("Doc type select — Light") { DocumentTypeSelectView(documentTypes: PreviewSamples.docTypes, onContinue: { _ in }) }
#Preview("Doc type select — Dark") { DocumentTypeSelectView(documentTypes: PreviewSamples.docTypes, onContinue: { _ in }).preferredColorScheme(.dark) }

// Document confirm
#Preview("Doc confirm — Light") { DocumentConfirmView(image: PreviewSamples.placeholderImage, onUse: {}, onRetake: {}, onUploadInstead: {}) }
#Preview("Doc confirm — Dark") { DocumentConfirmView(image: PreviewSamples.placeholderImage, onUse: {}, onRetake: {}, onUploadInstead: {}).preferredColorScheme(.dark) }

// ID number
#Preview("ID number — Light") { IdNumberView(idTypes: PreviewSamples.idTypes, onSubmit: { _, _, _ in }) }
#Preview("ID number — Dark") { IdNumberView(idTypes: PreviewSamples.idTypes, onSubmit: { _, _, _ in }).preferredColorScheme(.dark) }

// Form
#Preview("Form — Light") { FormScreen(model: PreviewSamples.formModel(), onContinue: {}) }
#Preview("Form — Dark") { FormScreen(model: PreviewSamples.formModel(), onContinue: {}).preferredColorScheme(.dark) }

// Results
#Preview("Result success — Light") { FlowResultView(kind: .success, continueTitle: "Continue", onContinue: {}) }
#Preview("Result success — Dark") { FlowResultView(kind: .success, continueTitle: "Continue", onContinue: {}).preferredColorScheme(.dark) }
#Preview("Result review") { FlowResultView(kind: .review) }
#Preview("Result not verified") { FlowResultView(kind: .notVerified) }

// Loading / error
#Preview("Loading — Light") { FlowLoadingView() }
#Preview("Loading — Dark") { FlowLoadingView().preferredColorScheme(.dark) }
#Preview("Error — Light") { FlowErrorView(message: "This link is invalid or has expired.", retryTitle: "Try again", onRetry: {}) }
#Preview("Error — Dark") { FlowErrorView(message: "This link is invalid or has expired.", retryTitle: "Try again", onRetry: {}).preferredColorScheme(.dark) }
#endif
