#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

// MARK: - Capture brand theme (BRAND-v1 section 4)
//
// One resolved theme for every capture screen. Two surfaces:
//   - the page (primers, sheets, result and error pages, dialogs, loading):
//     the full palette, following `mode`;
//   - the camera (align, scan, challenges): always dark, brand only as
//     accents that reach 3:1 on #333333 (`CaptureColors`).
// Everything here is a pure function of the merged FlowAppearance, so the
// rules are unit tested apart from SwiftUI. Colours not in this file are on
// the fixed list (`CaptureTokens`): camera background, scan dim, blur, oval
// guide, ring track, guidance text, shutter, fill light veil, colour sequence
// tint, Flash Reflection, the Speak Digits pill and "Powered by Sense".

/// Camera accents (BRAND-v1 4.2).
struct CaptureColors: Equatable {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
        var a: Double = 1
        var color: Color { Color(red: r, green: g, blue: b).opacity(a) }
        func mix(_ o: RGB, _ t: Double) -> RGB {
            RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
        }
        init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
        init(hex: UInt32, alpha: Double = 1) {
            r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
            a = alpha
        }
        /// "#RGB", "#RRGGBB" or "#RRGGBBAA"; nil when it doesn't parse.
        init?(css raw: String?) {
            guard let raw, let c = FlowAppearance.parseHexComponents(raw) else { return nil }
            self.init(r: Double(c.r), g: Double(c.g), b: Double(c.b), a: Double(c.a))
        }
        /// WCAG relative luminance (alpha ignored).
        var luminance: Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        func contrast(against o: RGB) -> Double {
            let a = luminance, b = o.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        var hex: String {
            String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }

        /// HSL lightness, 0...1.
        var lightness: Double { (max(r, g, b) + min(r, g, b)) / 2 }

        /// The same hue and saturation with lightness `l` (HSL).
        func withLightness(_ l: Double) -> RGB {
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            var h = 0.0, s = 0.0
            let l0 = (mx + mn) / 2
            if d > 0 {
                s = l0 > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
                if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
                h /= 6
            }
            let L = min(1, max(0, l))
            guard s > 0 else { return RGB(r: L, g: L, b: L, a: a) }
            let q = L < 0.5 ? L * (1 + s) : L + s - L * s
            let p = 2 * L - q
            func hue(_ t0: Double) -> Double {
                var t = t0
                if t < 0 { t += 1 }
                if t > 1 { t -= 1 }
                if t < 1 / 6 { return p + (q - p) * 6 * t }
                if t < 1 / 2 { return q }
                if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
                return p
            }
            return RGB(r: hue(h + 1 / 3), g: hue(h), b: hue(h - 1 / 3), a: a)
        }
    }

    /// Contrast reference for every camera accent.
    static let scrim = RGB(hex: 0x333333)
    static let minimumContrast = 3.0
    static let lightenStep = 0.05
    static let lightenSteps = 8

    static let senseRing = RGB(hex: 0x4F7CFF)
    static let senseChallenge = RGB(hex: 0xA878FC)
    static let senseWarning = RGB(hex: 0xFFB84D)
    static let senseSuccess = RGB(hex: 0x00D4AA)

    static let `default` = CaptureColors(ring: senseRing, challenge: senseChallenge,
                                         warning: senseWarning, success: senseSuccess)

    /// Ready oval, scan ring, contour lines, upload bar.
    var ring: RGB
    /// Extra-check ring and sheet icon.
    var challenge: RGB
    /// Failing oval, paused ring, Follow Dot, warnings on the camera.
    var warning: RGB
    /// Done tick and ring, mic meter.
    var success: RGB

    static func resolve(_ appearance: FlowAppearance?) -> CaptureColors {
        let cap = appearance?.capture
        let colors = appearance?.colors
        let primary = colors?.primary ?? colors?.dark?.primary
        let ring = passing(cap?.ring) ?? passing(primary) ?? lightened(primary) ?? senseRing
        return CaptureColors(
            ring: ring,
            challenge: passing(cap?.challenge) ?? senseChallenge,
            warning: passing(cap?.warning) ?? passing(colors?.warning ?? colors?.dark?.warning) ?? senseWarning,
            success: passing(colors?.success ?? colors?.dark?.success) ?? senseSuccess
        )
    }

    /// The colour when it parses and reads on the camera (alpha dropped).
    static func passing(_ raw: String?) -> RGB? {
        guard var c = RGB(css: raw) else { return nil }
        c.a = 1
        return c.contrast(against: scrim) >= minimumContrast ? c : nil
    }

    /// HSL lightness +5% per step, up to 8 steps, until it reads on the camera.
    static func lightened(_ raw: String?) -> RGB? {
        guard var c = RGB(css: raw) else { return nil }
        c.a = 1
        let l = c.lightness
        for step in 1...lightenSteps {
            let next = c.withLightness(l + Double(step) * lightenStep)
            if next.contrast(against: scrim) >= minimumContrast { return next }
        }
        return nil
    }

    /// The custom colour when it parses and reads on the scrim; else `fallback`.
    static func pick(_ raw: String?, _ fallback: RGB) -> RGB { passing(raw) ?? fallback }

    /// The active capture accents.
    static var current: CaptureColors { resolve(FlowAppearanceResolver.current) }
}

/// The resolved capture theme: page surface + camera accents + shape, type,
/// logo, icons and loader.
struct CaptureTheme: Equatable {
    typealias RGB = CaptureColors.RGB

    struct Palette: Equatable {
        var background: RGB, surface: RGB, foreground: RGB, muted: RGB, border: RGB
    }

    /// Sense defaults per mode (BRAND-v1 4.1). Dark is today's capture look.
    static let senseDark = Palette(background: RGB(hex: 0x12141B), surface: RGB(hex: 0x1D2029),
                                   foreground: RGB(hex: 0xF4F5F8), muted: RGB(hex: 0xA3A9B8),
                                   border: RGB(hex: 0xFFFFFF, alpha: 0.08))
    static let senseLight = Palette(background: RGB(hex: 0xFDFCFA), surface: RGB(hex: 0xF5F3EF),
                                    foreground: RGB(hex: 0x1C1A17), muted: RGB(hex: 0x6B6760),
                                    border: RGB(hex: 0xE8E5DE))
    static let sensePrimary = RGB(hex: 0x4F7CFF)
    static let senseSuccess = RGB(hex: 0x00D4AA)
    static let senseError = RGB(hex: 0xFF6B4A)
    static let senseWarning = RGB(hex: 0xFFB84D)
    static let inkOnLight = RGB(hex: 0x1C1A17)
    static let white = RGB(hex: 0xFFFFFF)

    var isDark: Bool
    var page: Palette
    var primary: RGB
    var primaryForeground: RGB
    var success: RGB
    var error: RGB
    var warning: RGB
    var backgroundImageURL: URL?

    var buttonRadius: CGFloat
    var buttonOutlined: Bool
    var dialogRadius: CGFloat
    var sheetRadius: CGFloat
    var tileRadius: CGFloat

    var logoURL: URL?
    var logoPlacement: AppearanceLogo.Placement
    var logoHeight: CGFloat
    /// Shown as text in the header when there is no logo.
    var displayName: String?

    var icons: AppearanceIcons?
    var loaderStyle: AppearanceLoader.Style
    var loaderImageURL: URL?

    var camera: CaptureColors

    /// `systemDark`: the device setting, used only when `mode` is `auto`.
    /// Unset mode keeps capture pages dark (today's look).
    static func resolve(_ a: FlowAppearance?, systemDark: Bool, displayName: String? = nil) -> CaptureTheme {
        let dark: Bool
        switch a?.mode {
        case nil, .dark?: dark = true
        case .light?: dark = false
        case .auto?: dark = systemDark
        }
        let c = a?.colors
        let d = c?.dark
        let base = dark ? senseDark : senseLight
        // Page neutrals: in dark mode only the dark layer counts (nothing is
        // derived from the light palette); in light mode `background.color`
        // wins over `colors.background`.
        func neutral(_ light: String?, _ darkV: String?, _ def: RGB) -> RGB {
            (dark ? RGB(css: darkV) : RGB(css: light)) ?? def
        }
        let page = Palette(
            background: dark ? (RGB(css: d?.background) ?? base.background)
                : (RGB(css: a?.background?.color) ?? RGB(css: c?.background) ?? base.background),
            surface: neutral(c?.surface, d?.surface, base.surface),
            foreground: neutral(c?.foreground, d?.foreground, base.foreground),
            muted: neutral(c?.muted, d?.muted, base.muted),
            border: neutral(c?.border, d?.border, base.border)
        )
        // Brand colours carry into dark mode unless the dark layer sets them.
        func brand(_ light: String?, _ darkV: String?, _ def: RGB) -> RGB {
            (dark ? (RGB(css: darkV) ?? RGB(css: light)) : RGB(css: light)) ?? def
        }
        let brandPrimary = dark ? (RGB(css: d?.primary) ?? RGB(css: c?.primary)) : RGB(css: c?.primary)
        let primary = brandPrimary ?? sensePrimary
        // On a brand primary: white or #1C1A17, whichever reads better. The
        // Sense blue keeps today's white label (the rule alone would pick the
        // dark ink on #4F7CFF, 5.6:1 against white's 3.4:1).
        let onPrimary = (dark ? (RGB(css: d?.primaryForeground) ?? RGB(css: c?.primaryForeground)) : RGB(css: c?.primaryForeground))
            ?? brandPrimary.map { white.contrast(against: $0) >= inkOnLight.contrast(against: $0) ? white : inkOnLight }
            ?? white

        let radius = a?.shape?.radius
        let logo = a?.logo
        return CaptureTheme(
            isDark: dark,
            page: page,
            primary: primary,
            primaryForeground: onPrimary,
            success: brand(c?.success, d?.success, senseSuccess),
            error: brand(c?.error, d?.error, senseError),
            warning: brand(c?.warning, d?.warning, senseWarning),
            backgroundImageURL: a?.background?.imageUrl.flatMap(Self.imageURL),
            buttonRadius: a?.shape?.buttonRadius ?? radius ?? 14,
            buttonOutlined: a?.shape?.buttonStyle == .outline,
            dialogRadius: radius ?? 20,
            sheetRadius: radius.map { min(2 * $0, 28) } ?? 28,
            tileRadius: radius ?? 12,
            logoURL: logo?.url.flatMap(Self.imageURL),
            logoPlacement: logo?.placement ?? .header,
            logoHeight: logo?.height ?? 28,
            displayName: displayName,
            icons: a?.icons,
            loaderStyle: a?.loader?.style ?? .spinner,
            loaderImageURL: a?.loader?.imageUrl.flatMap(Self.imageURL),
            camera: CaptureColors.resolve(a)
        )
    }

    /// Images load from https or data URLs only.
    static func imageURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "data" else { return nil }
        return url
    }

    /// The theme for the active brand.
    static func current(systemDark: Bool) -> CaptureTheme {
        resolve(FlowAppearanceResolver.current, systemDark: systemDark, displayName: FlowCopyResolver.displayName)
    }

    static let sense = resolve(nil, systemDark: true)

    /// The result-page illustration override for a slot, if set.
    func icon(_ slot: String) -> URL? { icons?[slot].flatMap(Self.imageURL) }

    // Colours as SwiftUI values.
    var background: Color { page.background.color }
    var surface: Color { page.surface.color }
    var foreground: Color { page.foreground.color }
    var muted: Color { page.muted.color }
    var border: Color { page.border.color }
    var primaryColor: Color { primary.color }
    var onPrimary: Color { primaryForeground.color }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

// MARK: - Delivery to the views

/// Bumped whenever the resolvers change, so capture screens re-theme when the
/// dashboard branding arrives after the first frame.
final class CaptureBrandStore: ObservableObject {
    static let shared = CaptureBrandStore()
    @Published private(set) var revision = 0
    @MainActor func bump() { revision &+= 1 }
}

private struct CaptureThemeKey: EnvironmentKey {
    static let defaultValue = CaptureTheme.sense
}

extension EnvironmentValues {
    var captureTheme: CaptureTheme {
        get { self[CaptureThemeKey.self] }
        set { self[CaptureThemeKey.self] = newValue }
    }
}

/// Resolves the theme once at the root of the capture screens and hands it
/// down. Page system controls (pickers, alerts) follow the page mode.
struct CaptureThemeRoot<Content: View>: View {
    @ObservedObject private var store = CaptureBrandStore.shared
    @SwiftUI.Environment(\.colorScheme) private var systemScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        let theme = CaptureTheme.current(systemDark: systemScheme == .dark)
        content()
            .environment(\.captureTheme, theme)
            .environment(\.colorScheme, theme.colorScheme)
    }
}
#endif
