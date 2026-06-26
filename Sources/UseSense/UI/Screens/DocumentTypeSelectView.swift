#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - DocumentTypeSelectView
//
// "Pick a document" — the document-type chooser, matching the hosted run page's
// select-type phase (selectable rows + Continue). Pure presentation.

public struct DocumentTypeSelectView: View {
    private let documentTypes: [String]
    private let brandColor: Color
    private let branding: USBrandingHeader?
    private let onContinue: (String) -> Void
    @State private var selected: String

    public init(
        documentTypes: [String],
        brandColor: Color = USColors.primary,
        branding: USBrandingHeader? = nil,
        onContinue: @escaping (String) -> Void
    ) {
        self.documentTypes = documentTypes
        self.brandColor = brandColor
        self.branding = branding
        self.onContinue = onContinue
        _selected = State(initialValue: documentTypes.first ?? "")
    }

    public var body: some View {
        USScreenScaffold(branding: branding) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Pick a document")
                    .font(.usDisplay(24, .bold))
                    .foregroundColor(USColors.foreground)
                Text("Choose a document to verify your identity. We don't accept scans or copies.")
                    .font(USType.body)
                    .foregroundColor(USColors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                VStack(spacing: 8) {
                    ForEach(documentTypes, id: \.self) { type in
                        typeRow(type)
                    }
                }
                .padding(.top, 24)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } footer: {
            USButton("Continue", variant: .primary, size: .large) {
                if !selected.isEmpty { onContinue(selected) }
            }
        }
    }

    private func typeRow(_ type: String) -> some View {
        let isSelected = type == selected
        return Button { selected = type } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(USColors.secondary)
                        .frame(width: 36, height: 36)
                    Image(systemName: "doc.text")
                        .font(.system(size: 16))
                        .foregroundColor(USColors.mutedForeground)
                }
                Text(type)
                    .font(.usBody(15, .medium))
                    .foregroundColor(USColors.foreground)
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
}

// MARK: - DocumentPrimerView
//
// The document-step primer ("Get your <type> ready"), matching the hosted copy.
// Thin convenience over PrimerView.

public struct DocumentPrimerView: View {
    private let documentType: String?
    private let categoryLabel: String
    private let issuingCountries: [String]
    private let allowCamera: Bool
    private let allowUpload: Bool
    private let isBusy: Bool
    private let brandColor: Color
    private let branding: USBrandingHeader?
    private let onPrimary: () -> Void
    private let onSecondary: (() -> Void)?

    public init(
        documentType: String?,
        categoryLabel: String = "document",
        issuingCountries: [String] = [],
        allowCamera: Bool = true,
        allowUpload: Bool = true,
        isBusy: Bool = false,
        brandColor: Color = USColors.primary,
        branding: USBrandingHeader? = nil,
        onPrimary: @escaping () -> Void,
        onSecondary: (() -> Void)? = nil
    ) {
        self.documentType = documentType
        self.categoryLabel = categoryLabel
        self.issuingCountries = issuingCountries
        self.allowCamera = allowCamera
        self.allowUpload = allowUpload
        self.isBusy = isBusy
        self.brandColor = brandColor
        self.branding = branding
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    public var body: some View {
        PrimerView(
            iconSystemName: "doc.text",
            title: documentType.map { "Get your \($0.lowercased()) ready" } ?? "Get your \(categoryLabel) ready",
            subtitle: "We'll capture it and check it's clear and readable.",
            points: [
                PrimerPoint(icon: "camera", text: "Place it on a flat, dark surface in good light."),
                PrimerPoint(icon: "sparkles", text: "Make sure all four corners are visible and details are sharp."),
            ],
            note: noteText,
            primaryTitle: allowCamera ? "Take a photo" : "Upload a file",
            primaryAction: onPrimary,
            secondaryTitle: (allowCamera && allowUpload) ? "Upload a file instead" : nil,
            secondaryAction: (allowCamera && allowUpload) ? onSecondary : nil,
            isBusy: isBusy,
            brandColor: brandColor,
            branding: branding
        )
    }

    private var noteText: String? {
        guard !issuingCountries.isEmpty else { return nil }
        let label = issuingCountries.count == 1 ? "country" : "countries"
        let list = issuingCountries.prefix(6).joined(separator: ", ")
        let ellipsis = issuingCountries.count > 6 ? "…" : ""
        return "Accepted issuing \(label): \(list)\(ellipsis)."
    }
}
#endif
