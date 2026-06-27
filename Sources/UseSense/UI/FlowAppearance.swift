import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - FlowAppearance: the white-label contract (Phase 1)
//
// FlowAppearance is the single customization schema shared across surfaces and
// SDKs. It mirrors the web SDK contract in packages/sdk/src/flows/theme.ts. It
// can be supplied two ways and is merged
//   SDK-init > server(branding.appearance) > legacy primaryColor/buttonRadius > built-in default
//   - by the developer at SDK init (`BrandingConfig.appearance`), and/or
//   - by the operator in the dashboard, delivered in the branding payload.
// Every field is optional; anything omitted falls back to the hosted-page tokens
// already encoded in USColors / the brand font ramp.

/// A palette layer. `dark` overrides apply only in dark mode.
public struct AppearanceColors: Codable, Equatable, Sendable {
    public var primary: String?
    public var primaryForeground: String?
    public var background: String?
    public var surface: String?
    public var foreground: String?
    public var muted: String?
    public var border: String?
    public var success: String?
    public var error: String?
    public var warning: String?
    /// Overrides applied on top of the dark base (e.g. a darker background).
    public var dark: DarkOverrides?

    /// The same field set as `AppearanceColors`, minus the nested `dark`, so the
    /// dark layer cannot recurse. (Swift can't express TS's `Omit`, so this is a
    /// hand-rolled mirror — keep the fields in sync.)
    public struct DarkOverrides: Codable, Equatable, Sendable {
        public var primary: String?
        public var primaryForeground: String?
        public var background: String?
        public var surface: String?
        public var foreground: String?
        public var muted: String?
        public var border: String?
        public var success: String?
        public var error: String?
        public var warning: String?

        public init(
            primary: String? = nil, primaryForeground: String? = nil, background: String? = nil,
            surface: String? = nil, foreground: String? = nil, muted: String? = nil,
            border: String? = nil, success: String? = nil, error: String? = nil, warning: String? = nil
        ) {
            self.primary = primary; self.primaryForeground = primaryForeground; self.background = background
            self.surface = surface; self.foreground = foreground; self.muted = muted
            self.border = border; self.success = success; self.error = error; self.warning = warning
        }
    }

    public init(
        primary: String? = nil, primaryForeground: String? = nil, background: String? = nil,
        surface: String? = nil, foreground: String? = nil, muted: String? = nil,
        border: String? = nil, success: String? = nil, error: String? = nil, warning: String? = nil,
        dark: DarkOverrides? = nil
    ) {
        self.primary = primary; self.primaryForeground = primaryForeground; self.background = background
        self.surface = surface; self.foreground = foreground; self.muted = muted
        self.border = border; self.success = success; self.error = error; self.warning = warning
        self.dark = dark
    }
}

public struct AppearanceTypography: Codable, Equatable, Sendable {
    /// Body font family name (the registered/installed family, e.g. "DM Sans").
    public var fontFamily: String?
    /// Heading/display font family; defaults to `fontFamily` when omitted.
    public var displayFamily: String?

    public init(fontFamily: String? = nil, displayFamily: String? = nil) {
        self.fontFamily = fontFamily
        self.displayFamily = displayFamily
    }
}

public struct AppearanceShape: Codable, Equatable, Sendable {
    /// Base corner radius in points (cards, inputs).
    public var radius: CGFloat?
    /// Button corner radius in points; defaults to `radius`.
    public var buttonRadius: CGFloat?
    public var buttonStyle: ButtonStyle?

    public enum ButtonStyle: String, Codable, Equatable, Sendable { case filled, outline }

    public init(radius: CGFloat? = nil, buttonRadius: CGFloat? = nil, buttonStyle: ButtonStyle? = nil) {
        self.radius = radius
        self.buttonRadius = buttonRadius
        self.buttonStyle = buttonStyle
    }
}

public struct AppearanceLogo: Codable, Equatable, Sendable {
    public var url: String?
    public var placement: Placement?
    public var height: CGFloat?

    public enum Placement: String, Codable, Equatable, Sendable { case header, center, none }

    public init(url: String? = nil, placement: Placement? = nil, height: CGFloat? = nil) {
        self.url = url
        self.placement = placement
        self.height = height
    }
}

public struct AppearanceBackground: Codable, Equatable, Sendable {
    public var color: String?
    public var imageUrl: String?

    public init(color: String? = nil, imageUrl: String? = nil) {
        self.color = color
        self.imageUrl = imageUrl
    }
}

/// Force a palette or follow the OS (default `.auto`).
public enum AppearanceMode: String, Codable, Equatable, Sendable { case light, dark, auto }

/// The white-label customization contract. Mirror of the web SDK `FlowAppearance`.
public struct FlowAppearance: Codable, Equatable, Sendable {
    public var colors: AppearanceColors?
    public var typography: AppearanceTypography?
    public var shape: AppearanceShape?
    public var logo: AppearanceLogo?
    public var background: AppearanceBackground?
    /// Force a palette or follow the OS (default `.auto`).
    public var mode: AppearanceMode?

    public init(
        colors: AppearanceColors? = nil,
        typography: AppearanceTypography? = nil,
        shape: AppearanceShape? = nil,
        logo: AppearanceLogo? = nil,
        background: AppearanceBackground? = nil,
        mode: AppearanceMode? = nil
    ) {
        self.colors = colors
        self.typography = typography
        self.shape = shape
        self.logo = logo
        self.background = background
        self.mode = mode
    }
}

// MARK: - Merge

public extension FlowAppearance {
    /// Deep-merge a higher-priority appearance over a lower one (SDK > server).
    /// Field-level: any value set on `high` wins; otherwise `low` shows through.
    static func merge(high: FlowAppearance?, low: FlowAppearance?) -> FlowAppearance? {
        guard let high else { return low }
        guard let low else { return high }
        return FlowAppearance(
            colors: mergeColors(high: high.colors, low: low.colors),
            typography: AppearanceTypography(
                fontFamily: high.typography?.fontFamily ?? low.typography?.fontFamily,
                displayFamily: high.typography?.displayFamily ?? low.typography?.displayFamily
            ),
            shape: AppearanceShape(
                radius: high.shape?.radius ?? low.shape?.radius,
                buttonRadius: high.shape?.buttonRadius ?? low.shape?.buttonRadius,
                buttonStyle: high.shape?.buttonStyle ?? low.shape?.buttonStyle
            ),
            logo: AppearanceLogo(
                url: high.logo?.url ?? low.logo?.url,
                placement: high.logo?.placement ?? low.logo?.placement,
                height: high.logo?.height ?? low.logo?.height
            ),
            background: AppearanceBackground(
                color: high.background?.color ?? low.background?.color,
                imageUrl: high.background?.imageUrl ?? low.background?.imageUrl
            ),
            mode: high.mode ?? low.mode
        )
    }

    private static func mergeColors(high: AppearanceColors?, low: AppearanceColors?) -> AppearanceColors? {
        guard let high else { return low }
        guard let low else { return high }
        let dark = AppearanceColors.DarkOverrides(
            primary: high.dark?.primary ?? low.dark?.primary,
            primaryForeground: high.dark?.primaryForeground ?? low.dark?.primaryForeground,
            background: high.dark?.background ?? low.dark?.background,
            surface: high.dark?.surface ?? low.dark?.surface,
            foreground: high.dark?.foreground ?? low.dark?.foreground,
            muted: high.dark?.muted ?? low.dark?.muted,
            border: high.dark?.border ?? low.dark?.border,
            success: high.dark?.success ?? low.dark?.success,
            error: high.dark?.error ?? low.dark?.error,
            warning: high.dark?.warning ?? low.dark?.warning
        )
        return AppearanceColors(
            primary: high.primary ?? low.primary,
            primaryForeground: high.primaryForeground ?? low.primaryForeground,
            background: high.background ?? low.background,
            surface: high.surface ?? low.surface,
            foreground: high.foreground ?? low.foreground,
            muted: high.muted ?? low.muted,
            border: high.border ?? low.border,
            success: high.success ?? low.success,
            error: high.error ?? low.error,
            warning: high.warning ?? low.warning,
            dark: dark
        )
    }
}

// MARK: - Legacy bridge

public extension FlowAppearance {
    /// Project a legacy `BrandingConfig` (primaryColor / buttonRadius / logoUrl /
    /// fontFamily) into the lowest-priority appearance layer, so the new
    /// resolution path subsumes the old fields without a behaviour change.
    static func fromLegacy(primaryColor: String?, buttonRadius: CGFloat?, logoUrl: String?, fontFamily: String?) -> FlowAppearance {
        FlowAppearance(
            colors: primaryColor.map { AppearanceColors(primary: $0) },
            typography: fontFamily.map { AppearanceTypography(fontFamily: $0, displayFamily: $0) },
            shape: buttonRadius.map { AppearanceShape(buttonRadius: $0) },
            logo: logoUrl.map { AppearanceLogo(url: $0) }
        )
    }
}

// MARK: - JSON decode (server payload)

public extension FlowAppearance {
    /// Decode a FlowAppearance from a JSONSerialization object (the heterogeneous
    /// branding payload is parsed with JSONSerialization upstream, so we re-encode
    /// the `appearance` sub-object and run it through Codable). The wire shape is
    /// camelCase (matching the web contract keys: primaryForeground, displayFamily,
    /// buttonRadius, imageUrl), which lines up 1:1 with these property names.
    /// Returns nil rather than throwing so a malformed payload degrades to the
    /// built-in tokens instead of failing the run.
    static func decodeFromJSONObject(_ object: [String: Any]) -> FlowAppearance? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(FlowAppearance.self, from: data)
    }
}

// MARK: - Hex parsing helper

extension FlowAppearance {
    /// Parse "#RGB", "#RRGGBB" or "#RRGGBBAA" (with or without the leading '#').
    /// Returns nil for unparseable strings so callers fall back to the default.
    static func parseHexComponents(_ raw: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        // Expand shorthand #RGB -> #RRGGBB.
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8 else { return nil }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        return (r, g, b, a)
    }
}
