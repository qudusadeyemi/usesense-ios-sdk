#if canImport(UIKit) && canImport(SwiftUI)
import UIKit
import SwiftUI

// MARK: - FlowAppearanceResolver
//
// Holds the merged FlowAppearance for the active Flow run and resolves it into
// the concrete tokens the parity screens already read (USColors, the brand font
// ramp, button shape, background, logo). Because USColors / the font helpers ask
// the resolver each time they evaluate, setting the appearance on the resolver
// re-themes every screen automatically — no screen needs to change.
//
// This is presentation state only. The Flow runner sets it before presenting any
// surface and clears it on teardown. Reads happen on the main thread (SwiftUI
// body / UIColor providers), so a plain main-actor store is sufficient.

public enum FlowAppearanceResolver {
    // Presentation state, mutated and read only on the main thread (the runner
    // sets it before presenting; SwiftUI bodies and UIColor providers read it on
    // the main thread). `nonisolated(unsafe)` documents that main-thread-only
    // contract while keeping USColors / the font ramp callable from their
    // existing (non-isolated) static contexts.
    nonisolated(unsafe) private static var _current: FlowAppearance?

    /// The merged appearance currently driving the runner. `nil` = built-in tokens.
    public static var current: FlowAppearance? { _current }

    @MainActor public static func set(_ appearance: FlowAppearance?) {
        _current = appearance
    }

    @MainActor public static func reset() {
        _current = nil
    }

    // MARK: Mode resolution

    /// Whether the given trait collection should render dark, honouring the
    /// appearance `mode` override (light/dark force; auto follows the trait).
    static func isDark(for traits: UITraitCollection) -> Bool {
        switch current?.mode ?? .auto {
        case .light: return false
        case .dark: return true
        case .auto: return traits.userInterfaceStyle == .dark
        }
    }

    /// A SwiftUI ColorScheme override to force on the runner's root, or nil for
    /// `auto` (let the system decide).
    static var forcedColorScheme: ColorScheme? {
        switch current?.mode ?? .auto {
        case .light: return .light
        case .dark: return .dark
        case .auto: return nil
        }
    }

    // MARK: Color resolution

    /// Resolve a single appearance color slot to a UIColor, falling back to the
    /// built-in light/dark hex pair. The returned UIColor is dynamic: it re-reads
    /// the slot per trait collection so light/dark and the `mode` override both
    /// apply live.
    static func color(
        _ slot: KeyPath<AppearanceColors, String?>,
        darkSlot: KeyPath<AppearanceColors.DarkOverrides, String?>?,
        lightDefault: UInt32,
        darkDefault: UInt32,
        lightOverride: String? = nil
    ) -> Color {
        Color(UIColor { traits in
            let dark = isDark(for: traits)
            let colors = current?.colors
            // Dark-layer override wins in dark mode; else the base slot; else the
            // built-in default for the resolved scheme.
            if dark, let darkSlot, let raw = colors?.dark?[keyPath: darkSlot],
               let c = Self.uiColor(fromHex: raw) {
                return c
            }
            // A light-only override (e.g. `background.color`) applies in light mode
            // only; in dark mode it is skipped so the dark palette / default wins.
            if !dark, let raw = lightOverride, let c = Self.uiColor(fromHex: raw) {
                return c
            }
            if let raw = colors?[keyPath: slot], let c = Self.uiColor(fromHex: raw) {
                return c
            }
            return UIColor(usHex: dark ? darkDefault : lightDefault)
        })
    }

    /// A constant (scheme-independent) brand color slot with a single default.
    static func constantColor(_ slot: KeyPath<AppearanceColors, String?>, default def: UInt32) -> Color {
        Color(UIColor { traits in
            let dark = isDark(for: traits)
            let colors = current?.colors
            if dark, let raw = colors?.dark?[slotMirror: slot], let c = Self.uiColor(fromHex: raw) { return c }
            if let raw = colors?[keyPath: slot], let c = Self.uiColor(fromHex: raw) { return c }
            return UIColor(usHex: def)
        })
    }

    private static func uiColor(fromHex raw: String) -> UIColor? {
        guard let c = FlowAppearance.parseHexComponents(raw) else { return nil }
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    // MARK: Background

    /// Explicit background color from `background.color`, if set. This is a single
    /// LIGHT background color and must be applied in light mode only — USColors
    /// passes it as `color(..., lightOverride:)` so dark mode falls through to the
    /// dark palette. Returns the raw hex (not a resolved Color) so the dynamic
    /// UIColor resolver can gate it on the resolved trait. nil = no override.
    static var backgroundColorOverrideHex: String? {
        current?.background?.color
    }

    /// Background image URL, if the operator/developer set one.
    static var backgroundImageURL: URL? {
        current?.background?.imageUrl.flatMap { URL(string: $0) }
    }

    // MARK: Shape

    static var cardRadius: CGFloat { current?.shape?.radius ?? 12 }
    static var buttonRadius: CGFloat {
        current?.shape?.buttonRadius ?? current?.shape?.radius ?? UseSenseComponents.buttonRadius
    }
    static var buttonOutlined: Bool { current?.shape?.buttonStyle == .outline }

    // MARK: Typography

    /// The display (heading) font family override, if set.
    static var displayFamily: String? {
        current?.typography?.displayFamily ?? current?.typography?.fontFamily
    }
    /// The body font family override, if set.
    static var bodyFamily: String? {
        current?.typography?.fontFamily
    }

    // MARK: Logo

    static var logoURL: URL? { current?.logo?.url.flatMap { URL(string: $0) } }
    static var logoPlacement: AppearanceLogo.Placement? { current?.logo?.placement }
    static var logoHeight: CGFloat? { current?.logo?.height }

    // MARK: Loader

    /// Custom loader asset URL (`loader.imageUrl`), if set. When present the
    /// branded loading view renders this image in place of the built-in spinner.
    static var loaderImageURL: URL? {
        current?.loader?.imageUrl.flatMap { URL(string: $0) }
    }

    /// The built-in loader preset (`loader.style`), defaulting to `.spinner`.
    static var loaderStyle: AppearanceLoader.Style {
        current?.loader?.style ?? .spinner
    }

    // MARK: Icons / illustrations

    /// Custom illustration URL for a named slot (`icons.<slot>`), if set. Used by
    /// result screens to override the built-in glyph (slots: "success", "review",
    /// "notVerified").
    static func icon(for slot: String) -> URL? {
        current?.icons?[slot].flatMap { URL(string: $0) }
    }
}

// Sugar so `constantColor` can reach the matching dark-override slot by name.
private extension AppearanceColors.DarkOverrides {
    /// Mirror a base-layer KeyPath onto the dark-override field with the same
    /// semantic name. Only the slots `constantColor` is used with are mapped
    /// (primary / primaryForeground); the rest return nil.
    subscript(slotMirror base: KeyPath<AppearanceColors, String?>) -> String? {
        switch base {
        case \AppearanceColors.primary: return primary
        case \AppearanceColors.primaryForeground: return primaryForeground
        case \AppearanceColors.success: return success
        case \AppearanceColors.error: return error
        case \AppearanceColors.warning: return warning
        default: return nil
        }
    }
}
#endif
