#if canImport(SwiftUI)
import SwiftUI

// MARK: - Color from Hex String

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 0.31; g = 0.27; b = 0.90
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Hosted Page Header (56pt, logo or text, bottom separator)

struct HostedPageHeader: View {
    let branding: EffectiveBranding

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if let logoUrl = branding.logoUrl, let url = URL(string: logoUrl) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 32)
                    } placeholder: {
                        Text(branding.displayName)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(Color(hex: branding.primaryColor))
                    }
                } else {
                    Text(branding.displayName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(hex: branding.primaryColor))
                }
                Spacer()
            }
            .frame(height: 56)

            // Bottom separator: 1pt hairline, Slate 200
            Rectangle()
                .fill(Color(red: 0.886, green: 0.910, blue: 0.878))
                .frame(height: 1)
        }
        .background(Color.white)
    }
}

// MARK: - Hosted Page Footer ("Powered by UseSense")

struct HostedPageFooter: View {
    var body: some View {
        VStack(spacing: 0) {
            // Top separator: 1pt hairline, Slate 100
            Rectangle()
                .fill(Color(red: 0.945, green: 0.961, blue: 0.976))
                .frame(height: 1)

            Button(action: {
                #if canImport(UIKit)
                if let url = URL(string: "https://usesense.ai") {
                    UIApplication.shared.open(url)
                }
                #endif
            }) {
                Text("Powered by UseSense")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.392, green: 0.455, blue: 0.545)) // Slate 500
            }
            .padding(.vertical, 12)
        }
        .background(Color.white)
    }
}

// MARK: - Hosted Loading Screen

struct HostedLoadingView: View {
    let branding: EffectiveBranding

    var body: some View {
        VStack {
            HostedPageHeader(branding: branding)
            Spacer()
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.5)
                    .tint(Color(hex: branding.primaryColor))
                Text("Loading...")
                    .font(.system(size: 16))
                    .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412)) // Slate 600
            }
            Spacer()
            HostedPageFooter()
        }
        .background(Color.white.ignoresSafeArea())
    }
}

// MARK: - Hosted Error Screen

struct HostedErrorView: View {
    let branding: EffectiveBranding
    let title: String
    let message: String

    var body: some View {
        VStack {
            HostedPageHeader(branding: branding)
            Spacer()

            VStack(spacing: 16) {
                // Red container per spec
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(Color(red: 0.863, green: 0.149, blue: 0.149)) // Red 600

                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165)) // Slate 900

                    Text(message)
                        .font(.system(size: 15))
                        .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(Color(red: 0.996, green: 0.949, blue: 0.949)) // red-50
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(red: 0.996, green: 0.792, blue: 0.792), lineWidth: 1) // red-200
                )
                .cornerRadius(12)
            }
            .padding(.horizontal, 24)

            Spacer()
            HostedPageFooter()
        }
        .background(Color.white.ignoresSafeArea())
    }
}

// MARK: - Primary Button (uses branding primaryColor)

struct HostedPrimaryButton: View {
    let title: String
    let branding: EffectiveBranding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(hex: branding.primaryColor))
                .cornerRadius(12)
        }
    }
}

// MARK: - Secondary Button (outline)

struct HostedSecondaryButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(color)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(12)
        }
    }
}
#endif
