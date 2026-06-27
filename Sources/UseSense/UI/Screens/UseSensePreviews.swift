#if DEBUG && canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - Shared sample data for the per-screen SwiftUI previews
//
// Each parity screen file has its own #Preview (light + dark) at the bottom, so
// opening any of them in Xcode renders it in the canvas — no live flow, device,
// or camera needed. They share this sample data. DEBUG-only; never shipped.

enum PreviewSamples {
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
#endif
