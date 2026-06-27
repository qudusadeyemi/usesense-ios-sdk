#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - USBrandingHeader
//
// Top-of-screen org lockup matching the hosted page: optional org logo + display
// name, with a "Secured by Sense" trust line.

public struct USBrandingHeader: View {
    private let displayName: String?
    private let logoURL: URL?

    public init(displayName: String? = nil, logoURL: URL? = nil) {
        self.displayName = displayName
        self.logoURL = logoURL
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let logoURL {
                AsyncImage(url: logoURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(USColors.secondary)
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                if let displayName {
                    Text(displayName).font(.usBody(15, .semibold)).foregroundColor(USColors.foreground)
                }
                Text("Secured by Sense")
                    .font(.usBody(11, .medium))
                    .foregroundColor(USColors.mutedForeground)
            }
            Spacer(minLength: 0)
        }
    }
}
#endif
