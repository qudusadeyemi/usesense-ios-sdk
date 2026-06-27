#if canImport(SwiftUI)
import SwiftUI
import CoreText

// MARK: - Brand Font Registration
//
// The SDK bundles the UseSense brand fonts (Outfit / DM Sans / JetBrains Mono)
// so native screens match the hosted run page exactly instead of falling back to
// the system face. SwiftPM resource fonts are NOT auto-registered with the font
// manager, so `registerIfNeeded()` must run before any `Font.custom(...)` resolves.

public enum UseSenseFonts {
    private static let lock = NSLock()
    private static var registered = false

    /// PostScript names of the bundled faces (verified against the .ttf name tables).
    private static let faces = [
        "Outfit-Bold", "Outfit-ExtraBold",
        "DMSans-Regular", "DMSans-Medium", "DMSans-SemiBold",
        "JetBrainsMono-Regular", "JetBrainsMono-Medium",
    ]

    /// Register the bundled brand fonts with CoreText. Idempotent + thread-safe;
    /// the brand `Font` helpers below call this lazily on first use.
    public static func registerIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        for name in faces {
            // Bundle.useSenseResources resolves under BOTH SwiftPM (Bundle.module)
            // and CocoaPods (nested UseSenseSDK.bundle); Bundle.module alone fails
            // to compile in the CocoaPods build. The fonts may be flattened or keep
            // the Fonts/ subdir depending on the build system, so try both lookups.
            let url = Bundle.useSenseResources.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.useSenseResources.url(forResource: name, withExtension: "ttf")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Brand Font Helpers

public enum USFontWeightDisplay { case bold, extraBold }
public enum USFontWeightBody { case regular, medium, semibold }

public extension Font {
    /// Outfit — display / headings. Auto-registers bundled fonts on first use.
    /// When the resolved FlowAppearance sets `typography.displayFamily`, that
    /// family is used instead (the SwiftUI weight is applied on top), so a
    /// white-label run renders headings in the operator's font.
    static func usDisplay(_ size: CGFloat, _ weight: USFontWeightDisplay = .bold) -> Font {
        UseSenseFonts.registerIfNeeded()
        #if canImport(UIKit)
        if let family = FlowAppearanceResolver.displayFamily {
            return .custom(family, size: size).weight(weight == .extraBold ? .heavy : .bold)
        }
        #endif
        return .custom(weight == .extraBold ? "Outfit-ExtraBold" : "Outfit-Bold", size: size)
    }

    /// DM Sans — body, buttons, inputs. When the resolved FlowAppearance sets
    /// `typography.fontFamily`, that family is used instead.
    static func usBody(_ size: CGFloat, _ weight: USFontWeightBody = .regular) -> Font {
        UseSenseFonts.registerIfNeeded()
        #if canImport(UIKit)
        if let family = FlowAppearanceResolver.bodyFamily {
            let w: Font.Weight
            switch weight {
            case .regular:  w = .regular
            case .medium:   w = .medium
            case .semibold: w = .semibold
            }
            return .custom(family, size: size).weight(w)
        }
        #endif
        let name: String
        switch weight {
        case .regular:  name = "DMSans-Regular"
        case .medium:   name = "DMSans-Medium"
        case .semibold: name = "DMSans-SemiBold"
        }
        return .custom(name, size: size)
    }

    /// JetBrains Mono — codes, reference numbers, scores.
    static func usMono(_ size: CGFloat, medium: Bool = false) -> Font {
        UseSenseFonts.registerIfNeeded()
        return .custom(medium ? "JetBrainsMono-Medium" : "JetBrainsMono-Regular", size: size)
    }
}

// MARK: - Type Ramp (mirrors hosted theme.css on a 16pt base)

public enum USType {
    public static var h1: Font { .usDisplay(34, .extraBold) }   // Outfit 800, tracking -0.05em
    public static var h2: Font { .usDisplay(23, .bold) }        // Outfit 700, -0.03em
    public static var h3: Font { .usDisplay(17, .bold) }        // Outfit 700, -0.02em
    public static var h4: Font { .usDisplay(16, .bold) }        // Outfit 700
    public static var body: Font { .usBody(16, .regular) }      // DM Sans 400
    public static var bodyMedium: Font { .usBody(16, .medium) } // DM Sans 500
    public static var label: Font { .usBody(11, .semibold) }    // DM Sans 600, uppercase +0.06em
    public static var button: Font { .usBody(15, .semibold) }   // DM Sans 600
    public static var mono: Font { .usMono(14) }
}

// MARK: - Type View Modifiers (apply the hosted letter-spacing too)

private extension View {
    /// Letter-spacing is iOS 16+; on iOS 15 we keep the font without kerning.
    @ViewBuilder func usKern(_ value: CGFloat) -> some View {
        if #available(iOS 16.0, *) { self.kerning(value) } else { self }
    }
}

public extension View {
    func usTitle1() -> some View { font(USType.h1).usKern(-1.7) }
    func usTitle2() -> some View { font(USType.h2).usKern(-0.7) }
    func usTitle3() -> some View { font(USType.h3).usKern(-0.34) }
    func usBodyStyle() -> some View { font(USType.body) }
    /// Uppercase, letter-spaced kicker label (DM Sans 600).
    func usLabelStyle() -> some View { font(USType.label).usKern(0.66).textCase(.uppercase) }
}
#endif
