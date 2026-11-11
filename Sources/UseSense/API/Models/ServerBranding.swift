import Foundation

/// The dashboard (server) branding layer, delivered as `branding` with a Flow
/// run view, a session-create response and the init-session / hosted responses.
///
/// Precedence (docs: branding precedence v1, "code wins"): per field, a value
/// set in code (SDK init config / per-launch options) beats this layer, and this
/// layer beats the built-in defaults. Nothing here counts unless the operator
/// configured it, so every field is optional and blank strings decode as unset.
public struct ServerBranding: Codable, Equatable, Sendable {
    public let displayName: String?
    public let logoUrl: String?
    public let primaryColor: String?
    public let redirectUrl: String?
    public let appearance: FlowAppearance?
    public let copy: FlowCopy?

    public init(
        displayName: String? = nil,
        logoUrl: String? = nil,
        primaryColor: String? = nil,
        redirectUrl: String? = nil,
        appearance: FlowAppearance? = nil,
        copy: FlowCopy? = nil
    ) {
        self.displayName = Self.set(displayName)
        self.logoUrl = Self.set(logoUrl)
        self.primaryColor = Self.set(primaryColor)
        self.redirectUrl = Self.set(redirectUrl)
        self.appearance = appearance
        self.copy = copy
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case logoUrl = "logo_url"
        case primaryColor = "primary_color"
        case redirectUrl = "redirect_url"
        case appearance, copy
    }

    /// Lenient: a malformed block is dropped (treated as unset) rather than
    /// failing the session or run that carries it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displayName: (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil,
            logoUrl: (try? c.decodeIfPresent(String.self, forKey: .logoUrl)) ?? nil,
            primaryColor: (try? c.decodeIfPresent(String.self, forKey: .primaryColor)) ?? nil,
            redirectUrl: (try? c.decodeIfPresent(String.self, forKey: .redirectUrl)) ?? nil,
            appearance: (try? c.decodeIfPresent(FlowAppearance.self, forKey: .appearance)) ?? nil,
            copy: (try? c.decodeIfPresent(FlowCopy.self, forKey: .copy)) ?? nil
        )
    }

    /// From a JSONSerialization object (the Flow run view is parsed that way).
    static func fromJSONObject(_ b: [String: Any]) -> ServerBranding {
        ServerBranding(
            displayName: b["display_name"] as? String,
            logoUrl: b["logo_url"] as? String,
            primaryColor: b["primary_color"] as? String,
            redirectUrl: b["redirect_url"] as? String,
            appearance: (b["appearance"] as? [String: Any]).flatMap(FlowAppearance.decodeFromJSONObject),
            copy: (b["copy"] as? [String: Any]).flatMap(FlowCopy.decodeFromJSONObject)
        )
    }

    /// This layer as one appearance: the dashboard appearance over its own
    /// legacy flat primary colour / logo (field by field).
    public var resolvedAppearance: FlowAppearance? {
        let legacy: FlowAppearance? = (primaryColor == nil && logoUrl == nil)
            ? nil
            : FlowAppearance.fromLegacy(primaryColor: primaryColor, buttonRadius: nil, logoUrl: logoUrl, fontFamily: nil)
        return FlowAppearance.merge(high: appearance, low: legacy)
    }

    private static func set(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

/// Resolves the effective appearance for a surface: code (high) over the
/// dashboard (low), field by field. Built-in defaults fill whatever is still
/// unset when the tokens are read (USColors / FlowAppearanceResolver).
enum BrandingResolver {
    static func resolve(code: FlowAppearance?, dashboard: FlowAppearance?) -> FlowAppearance? {
        FlowAppearance.merge(high: code, low: dashboard)
    }

    /// One line per key field naming the layer that supplied it, for the
    /// USESENSE_DEBUG trace (e.g. `primary=#FF6A00 (dashboard)`).
    static func describeSources(code: FlowAppearance?, dashboard: FlowAppearance?, dashboardLabel: String = "dashboard") -> String {
        func pick(_ name: String, _ c: String?, _ d: String?) -> String {
            if let c { return "\(name)=\(c) (code)" }
            if let d { return "\(name)=\(d) (\(dashboardLabel))" }
            return "\(name)=default"
        }
        let fields: [String] = [
            pick("primary", code?.colors?.primary, dashboard?.colors?.primary),
            pick("primaryForeground", code?.colors?.primaryForeground, dashboard?.colors?.primaryForeground),
            pick("background", code?.colors?.background, dashboard?.colors?.background),
            pick("foreground", code?.colors?.foreground, dashboard?.colors?.foreground),
            pick("font", code?.typography?.fontFamily, dashboard?.typography?.fontFamily),
            pick("buttonRadius", code?.shape?.buttonRadius.map { "\($0)" }, dashboard?.shape?.buttonRadius.map { "\($0)" }),
            pick("logo", code?.logo?.url, dashboard?.logo?.url),
            pick("mode", code?.mode.map { "\($0)" }, dashboard?.mode.map { "\($0)" }),
            pick("surface", code?.colors?.surface, dashboard?.colors?.surface),
            pick("muted", code?.colors?.muted, dashboard?.colors?.muted),
            pick("border", code?.colors?.border, dashboard?.colors?.border),
            pick("success", code?.colors?.success, dashboard?.colors?.success),
            pick("error", code?.colors?.error, dashboard?.colors?.error),
            pick("warning", code?.colors?.warning, dashboard?.colors?.warning),
            pick("darkBackground", code?.colors?.dark?.background, dashboard?.colors?.dark?.background),
            pick("displayFont", code?.typography?.displayFamily, dashboard?.typography?.displayFamily),
            pick("radius", code?.shape?.radius.map { "\($0)" }, dashboard?.shape?.radius.map { "\($0)" }),
            pick("buttonStyle", code?.shape?.buttonStyle?.rawValue, dashboard?.shape?.buttonStyle?.rawValue),
            pick("logoPlacement", code?.logo?.placement?.rawValue, dashboard?.logo?.placement?.rawValue),
            pick("background.image", code?.background?.imageUrl, dashboard?.background?.imageUrl),
            pick("capture.ring", code?.capture?.ring, dashboard?.capture?.ring),
            pick("capture.challenge", code?.capture?.challenge, dashboard?.capture?.challenge),
            pick("capture.warning", code?.capture?.warning, dashboard?.capture?.warning),
            pick("loader", code?.loader?.style?.rawValue, dashboard?.loader?.style?.rawValue),
        ]
        return "branding " + fields.joined(separator: " ")
    }
}
