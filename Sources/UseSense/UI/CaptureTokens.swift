#if canImport(SwiftUI)
import SwiftUI

// MARK: - Fixed capture tokens (BRAND-v1 4.2 "Fixed (not brandable)")
//
// The only literal colours the guided capture screens may use. Everything
// else comes from `CaptureTheme`. `CaptureBrandGuardTests` fails when a
// literal colour appears in a capture view file; add fixed colours here,
// and only when the brand contract lists them as fixed.

enum CaptureTokens {
    // Camera surface
    /// Camera background (#0D0F14).
    static let cam = Color(red: 13 / 255, green: 15 / 255, blue: 20 / 255)
    /// Fill light veil (#FFF4E2).
    static let fillVeil = Color(red: 1, green: 244 / 255, blue: 226 / 255)
    /// Guidance text and its shadow (white).
    static let guidanceInk = Color.white
    static let guidanceSubOpacity = 0.82
    static let guidanceShadow = Color.black
    /// Oval guide fill and the neutral (white) stroke; ring track.
    static let guideInk = Color.white
    /// Shutter button.
    static let shutter = Color.white
    /// Back / help circles on the camera: light glyph on the dimmed camera.
    static let chromeInk = Color(red: 244 / 255, green: 245 / 255, blue: 248 / 255)
    static let chromeFillOpacity = 0.55
    /// Speak Digits pill (monospace, white on the dimmed camera).
    static let digitsInk = Color.white
    static let digitsPillOpacity = 0.72
    /// The Head Turn arrow and the done tick's glyph read like guidance.
    static let arrowInk = Color.white
    static let tickInk = Color.white
    /// "Powered by Sense" on the camera.
    static let poweredByInk = Color.white
    static let poweredByOpacity = 0.5
    /// Behind a dialog.
    static let dialogScrim = Color.black.opacity(0.5)
    /// Neutral colour sequence fallback when a server colour doesn't parse.
    static let tintFallback = CaptureColors.RGB(r: 1, g: 1, b: 1)

    // DEBUG gate chips (USESENSE_DEBUG_GATE=1 only)
    static let debugBadInk = Color(red: 1, green: 0.8, blue: 0.48)
    static let debugGoodInk = Color(red: 0.37, green: 0.94, blue: 0.8)
    static let debugBadFill = Color(red: 1, green: 0.72, blue: 0.3).opacity(0.18)
    static let debugGoodFill = Color(red: 0, green: 0.83, blue: 0.67).opacity(0.16)

    // Geometry and opacities (not colours)
    /// Camera darkening under the lines during the scan.
    static let feedDimDuringScan = 0.12
    static let guideFill = 0.14
    static let guideStroke = 0.90
    static let guideWidth: CGFloat = 2
    static let ringTrack = 0.18
    static let ringWidth: CGFloat = 3
    static let ringGap: CGFloat = 6
    static let hintGapBelowOval: CGFloat = 28
    static let topBarTop: CGFloat = 54
    /// Tint behind an icon glyph (BRAND-v1: tile = colour at 16%).
    static let tileOpacity = 0.16
}
#endif
