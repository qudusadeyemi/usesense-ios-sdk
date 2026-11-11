import XCTest
import SwiftUI
import UIKit
@testable import UseSenseSDK

/// BRAND-v1 section 9: every capture element reads a token or is on the
/// fixed list; contrast gating and lightening; precedence per field;
/// `copy.capture` fallbacks, blanks and placeholders; retired contour keys.
@MainActor
final class CaptureBrandTests: XCTestCase {

    override func tearDown() {
        FlowAppearanceResolver.reset()
        FlowCopyResolver.reset()
        CaptureBrandSeed.flowRunActive = false
        super.tearDown()
    }

    // MARK: Fixtures (BRAND-v1 section 8)

    static let acme = FlowAppearance(
        colors: AppearanceColors(primary: "#1F7A4D", background: "#FFFFFF", surface: "#F3F6F4",
                                 foreground: "#13261C", muted: "#5B6B62", border: "#D8E0DB"),
        typography: AppearanceTypography(fontFamily: "Inter", displayFamily: "Georgia"),
        shape: AppearanceShape(radius: 12, buttonRadius: 999, buttonStyle: .filled),
        logo: AppearanceLogo(url: "https://cdn.example/acme.png", placement: .header, height: 28),
        mode: .light)

    static let nightPay = FlowAppearance(
        colors: AppearanceColors(primary: "#3A1D8F", dark: AppearanceColors.DarkOverrides(
            background: "#0B0B12", surface: "#16162A", foreground: "#EDEBFF", muted: "#9C98C9")),
        shape: AppearanceShape(buttonRadius: 4, buttonStyle: .outline),
        mode: .dark,
        capture: AppearanceCapture(challenge: "#FF4FA3"))

    private typealias RGB = CaptureColors.RGB

    // MARK: Literal colour guard

    /// Capture view files may only colour from `CaptureTheme` or the fixed
    /// `CaptureTokens`. A new literal colour here fails the build's tests.
    func testCaptureViewsHaveNoLiteralColours() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UseSense/UI")
        let files = ["GuidedCaptureView.swift", "ExtraCheckViews.swift", "GuidedScreens.swift", "CaptureCopy.swift"]
        let patterns = [
            #"Color\(\s*(red|white|hue|uiColor|hex|usHex|cgColor)"#,
            #"UIColor\s*[\(\.]"#,
            #"Color\.(white|black|gray|grey|red|green|blue|orange|yellow|purple|pink|primary|secondary|accentColor|UseSense)"#,
            #"[\(,:]\s*\.(white|black|gray|red|green|blue|orange|yellow|purple|pink)\b"#,
            #"USColors\."#,
            #"0x[0-9A-Fa-f]{6}"#,
            ##""#[0-9A-Fa-f]{3,8}""##,
        ].map { try! NSRegularExpression(pattern: $0) }
        var hits: [String] = []
        for name in files {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.components(separatedBy: "//").first ?? raw
                let range = NSRange(line.startIndex..., in: line)
                if patterns.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                    hits.append("\(name):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, "Literal colours in capture UI (use CaptureTheme or CaptureTokens):\n" + hits.joined(separator: "\n"))
    }

    // MARK: Camera accents: gating and lightening

    func testNightPayRingIsLightenedToPassOnTheCamera() throws {
        let primary = try XCTUnwrap(RGB(css: "#3A1D8F"))
        XCTAssertLessThan(primary.contrast(against: CaptureColors.scrim), 3, "fixture fails 3:1")
        let ring = CaptureColors.resolve(Self.nightPay).ring
        XCTAssertGreaterThanOrEqual(ring.contrast(against: CaptureColors.scrim), 3)
        XCTAssertNotEqual(ring, CaptureColors.senseRing, "lightened brand, not the Sense default")
        // Lightened in 5% HSL steps, at most 8.
        let steps = (ring.lightness - primary.lightness) / CaptureColors.lightenStep
        XCTAssertEqual(steps, steps.rounded(), accuracy: 0.02)
        XCTAssertLessThanOrEqual(steps.rounded(), 8)
        // The previous step did not pass (first passing step is taken).
        let previous = primary.withLightness(ring.lightness - CaptureColors.lightenStep)
        XCTAssertLessThan(previous.contrast(against: CaptureColors.scrim), 3)
        // Hue is kept: still a purple (blue channel highest).
        XCTAssertGreaterThan(ring.b, ring.g)
        XCTAssertGreaterThan(ring.b, ring.r)
    }

    func testRingResolutionOrder() {
        // capture.ring when it passes.
        XCTAssertEqual(CaptureColors.resolve(FlowAppearance(colors: AppearanceColors(primary: "#00D4AA"),
                                                            capture: AppearanceCapture(ring: "#FFB84D"))).ring,
                       RGB(hex: 0xFFB84D))
        // else a passing primary.
        XCTAssertEqual(CaptureColors.resolve(FlowAppearance(colors: AppearanceColors(primary: "#00D4AA"),
                                                            capture: AppearanceCapture(ring: "#111111"))).ring,
                       RGB(hex: 0x00D4AA))
        // a primary that can't be lightened enough (black) -> Sense blue.
        XCTAssertEqual(CaptureColors.resolve(FlowAppearance(colors: AppearanceColors(primary: "#000000"))).ring,
                       CaptureColors.senseRing)
        // nothing set -> Sense blue.
        XCTAssertEqual(CaptureColors.resolve(nil).ring, CaptureColors.senseRing)
    }

    func testChallengeWarningAndSuccessGating() {
        let night = CaptureColors.resolve(Self.nightPay)
        XCTAssertEqual(night.challenge, RGB(hex: 0xFF4FA3), "passing challenge colour is used")
        let darkChallenge = CaptureColors.resolve(FlowAppearance(capture: AppearanceCapture(challenge: "#220044")))
        XCTAssertEqual(darkChallenge.challenge, CaptureColors.senseChallenge)
        // warning: capture.warning, else colors.warning, else Sense amber.
        XCTAssertEqual(CaptureColors.resolve(FlowAppearance(colors: AppearanceColors(warning: "#FFD000"))).warning,
                       RGB(hex: 0xFFD000))
        XCTAssertEqual(CaptureColors.resolve(FlowAppearance(colors: AppearanceColors(warning: "#5A3A00"))).warning,
                       CaptureColors.senseWarning)
        XCTAssertEqual(CaptureColors.resolve(FlowAppearance(colors: AppearanceColors(warning: "#FFD000"),
                                                            capture: AppearanceCapture(warning: "#FF8800"))).warning,
                       RGB(hex: 0xFF8800))
        // success on the camera: colors.success when it passes.
        XCTAssertEqual(CaptureColors.resolve(FlowAppearance(colors: AppearanceColors(success: "#30E070"))).success,
                       RGB(hex: 0x30E070))
        XCTAssertEqual(CaptureColors.resolve(FlowAppearance(colors: AppearanceColors(success: "#0B3D20"))).success,
                       CaptureColors.senseSuccess)
    }

    func testRetiredContourKeysAreAcceptedAndIgnored() throws {
        let json: [String: Any] = ["capture": ["contourStart": "#FF0000", "contour_end": "#00FF00", "challenge": "#FF4FA3"]]
        let decoded = try XCTUnwrap(FlowAppearance.decodeFromJSONObject(json), "no decode error")
        XCTAssertEqual(decoded.capture?.challenge, "#FF4FA3")
        let colors = CaptureColors.resolve(decoded)
        XCTAssertEqual(colors.ring, CaptureColors.senseRing, "contour colours never change what is drawn")
        let wire = try JSONSerialization.jsonObject(with: Data(##"{"appearance":{"capture":{"contourStart":"#123456"}}}"##.utf8)) as? [String: Any]
        XCTAssertNotNil(ServerBranding.fromJSONObject(try XCTUnwrap(wire)).appearance)
    }

    // MARK: Page surface

    func testSenseDefaultsPerMode() {
        let unset = CaptureTheme.resolve(nil, systemDark: false)
        XCTAssertTrue(unset.isDark, "unset mode keeps capture pages dark")
        XCTAssertEqual(unset.page, CaptureTheme.senseDark)
        XCTAssertEqual(unset.page.background, RGB(hex: 0x12141B))
        XCTAssertEqual(unset.primary, RGB(hex: 0x4F7CFF))
        XCTAssertEqual(unset.primaryForeground, RGB(hex: 0xFFFFFF), "Sense blue keeps its white label")
        XCTAssertEqual(unset.buttonRadius, 14)
        XCTAssertEqual(unset.dialogRadius, 20)
        XCTAssertEqual(unset.sheetRadius, 28)
        XCTAssertEqual(unset.tileRadius, 12)
        XCTAssertEqual(unset.logoHeight, 28)

        let light = CaptureTheme.resolve(FlowAppearance(mode: .light), systemDark: true)
        XCTAssertFalse(light.isDark)
        XCTAssertEqual(light.page, CaptureTheme.senseLight)

        XCTAssertTrue(CaptureTheme.resolve(FlowAppearance(mode: .auto), systemDark: true).isDark)
        XCTAssertFalse(CaptureTheme.resolve(FlowAppearance(mode: .auto), systemDark: false).isDark)
    }

    func testAcmeBankLightTheme() {
        let t = CaptureTheme.resolve(Self.acme, systemDark: true, displayName: "Acme Bank")
        XCTAssertFalse(t.isDark)
        XCTAssertEqual(t.page.background, RGB(hex: 0xFFFFFF))
        XCTAssertEqual(t.page.surface, RGB(hex: 0xF3F6F4))
        XCTAssertEqual(t.page.foreground, RGB(hex: 0x13261C))
        XCTAssertEqual(t.page.muted, RGB(hex: 0x5B6B62))
        XCTAssertEqual(t.page.border, RGB(hex: 0xD8E0DB))
        XCTAssertEqual(t.primary, RGB(hex: 0x1F7A4D))
        XCTAssertEqual(t.primaryForeground, RGB(hex: 0xFFFFFF), "white reads better on the green")
        XCTAssertEqual(t.buttonRadius, 999)
        XCTAssertFalse(t.buttonOutlined)
        XCTAssertEqual(t.dialogRadius, 12)
        XCTAssertEqual(t.sheetRadius, 24, "min(2 x radius, 28)")
        XCTAssertEqual(t.tileRadius, 12)
        XCTAssertEqual(t.logoURL?.absoluteString, "https://cdn.example/acme.png")
        XCTAssertEqual(t.logoPlacement, .header)
        XCTAssertEqual(t.displayName, "Acme Bank")
        // Green fails 3:1 on the camera, so the ring is a lighter green.
        XCTAssertGreaterThanOrEqual(t.camera.ring.contrast(against: CaptureColors.scrim), 3)
        XCTAssertGreaterThan(t.camera.ring.g, t.camera.ring.r)
    }

    func testNightPayDarkThemeUsesOnlyTheDarkLayerForNeutrals() {
        let t = CaptureTheme.resolve(Self.nightPay, systemDark: false)
        XCTAssertTrue(t.isDark)
        XCTAssertEqual(t.page.background, RGB(hex: 0x0B0B12))
        XCTAssertEqual(t.page.surface, RGB(hex: 0x16162A))
        XCTAssertEqual(t.page.foreground, RGB(hex: 0xEDEBFF))
        XCTAssertEqual(t.page.muted, RGB(hex: 0x9C98C9))
        XCTAssertEqual(t.page.border, CaptureTheme.senseDark.border, "unset dark key: Sense dark default")
        XCTAssertEqual(t.primary, RGB(hex: 0x3A1D8F), "brand primary carries into dark mode")
        XCTAssertTrue(t.buttonOutlined)
        XCTAssertEqual(t.buttonRadius, 4)
        // A light-palette neutral never leaks into dark mode.
        let mixed = CaptureTheme.resolve(FlowAppearance(colors: AppearanceColors(background: "#FFFFFF", surface: "#EEEEEE"),
                                                        background: AppearanceBackground(color: "#FAFAFA"), mode: .dark),
                                         systemDark: true)
        XCTAssertEqual(mixed.page.background, CaptureTheme.senseDark.background)
        XCTAssertEqual(mixed.page.surface, CaptureTheme.senseDark.surface)
    }

    func testLightBackgroundColourWinsAndPrimaryForegroundPicksContrast() {
        let t = CaptureTheme.resolve(FlowAppearance(colors: AppearanceColors(primary: "#FFD000", background: "#EEEEEE"),
                                                    background: AppearanceBackground(color: "#FAFAF0"), mode: .light),
                                     systemDark: false)
        XCTAssertEqual(t.page.background, RGB(hex: 0xFAFAF0))
        XCTAssertEqual(t.primaryForeground, RGB(hex: 0x1C1A17), "dark ink on a yellow primary")
    }

    func testShapeFallbacksAndImageSchemes() {
        let t = CaptureTheme.resolve(FlowAppearance(shape: AppearanceShape(radius: 8),
                                                    logo: AppearanceLogo(url: "http://insecure.example/logo.png", placement: AppearanceLogo.Placement.none),
                                                    background: AppearanceBackground(imageUrl: "data:image/png;base64,AAAA")),
                                     systemDark: true)
        XCTAssertEqual(t.buttonRadius, 8, "buttonRadius falls back to radius")
        XCTAssertEqual(t.sheetRadius, 16)
        XCTAssertNil(t.logoURL, "only https and data images")
        XCTAssertEqual(t.logoPlacement, AppearanceLogo.Placement.none)
        XCTAssertNotNil(t.backgroundImageURL)
    }

    func testThemeFollowsTheResolvers() {
        FlowAppearanceResolver.set(Self.acme)
        FlowCopyResolver.setDisplayName("Acme Bank")
        let t = CaptureTheme.current(systemDark: true)
        XCTAssertEqual(t.primary, RGB(hex: 0x1F7A4D))
        XCTAssertEqual(t.displayName, "Acme Bank")
        FlowAppearanceResolver.reset()
        FlowCopyResolver.reset()
        XCTAssertEqual(CaptureTheme.current(systemDark: true), CaptureTheme.sense)
    }

    // MARK: Precedence per field

    func testCodeLegacyPrimaryColourBeatsDashboardAppearance() throws {
        let json = #"""
        {"session_id":"s","session_token":"t","expires_at":"2099-01-01T00:00:00.000Z","nonce":"n",
         "policy":{"requires_audio":false,"requires_stepup":false,"challenge_type":"none"},
         "upload":{"max_frames":30,"target_fps":3,"capture_duration_ms":2500},
         "branding":{"display_name":"XT","appearance":{"colors":{"primary":"#FF6A00","surface":"#EEEEEE"},
           "capture":{"challenge":"#FF4FA3"}},
           "copy":{"capture":{"result":{"approvedTitle":"All set","approvedBody":"Back to {app}"}}}}}
        """#
        let response = try JSONDecoder().decode(CreateSessionResponse.self, from: Data(json.utf8))
        let session = UseSenseSession(
            config: UseSenseConfig(apiEndpoint: "http://127.0.0.1:9/v1", apiKey: "sk",
                                   branding: BrandingConfig(primaryColor: "#123456",
                                                            copy: FlowCopy(capture: CaptureCopy(result: {
                                                                var r = CaptureCopy.Result(); r.approvedTitle = "Code title"; return r
                                                            }())))),
            sessionType: .enrollment)
        session.injectHostedSessionData(response)
        let appearance = session.brandingAppearance
        XCTAssertEqual(appearance?.colors?.primary, "#123456", "code legacy primaryColor beats dashboard appearance")
        XCTAssertEqual(appearance?.colors?.surface, "#EEEEEE", "dashboard shows through")
        XCTAssertEqual(appearance?.capture?.challenge, "#FF4FA3")
        XCTAssertEqual(session.brandingCopy?.capture?.result?.approvedTitle, "Code title", "code copy wins")
        XCTAssertEqual(session.brandingCopy?.capture?.result?.approvedBody, "Back to {app}", "dashboard copy shows through")
        XCTAssertEqual(session.brandDisplayName, "XT")
    }

    func testStandaloneControllerSeedsCopyAndDisplayName() throws {
        var copy = CaptureCopy.Leave(); copy.title = "Stop now?"
        let config = UseSenseConfig(apiKey: "sk", branding: BrandingConfig(copy: FlowCopy(capture: CaptureCopy(leave: copy))))
        let vc = UseSenseViewController(session: UseSenseSession(config: config, sessionType: .enrollment)) { _ in }
        vc.loadViewIfNeeded()
        XCTAssertEqual(CaptureScreenCopy.leaveTitle, "Stop now?")
        vc.viewDidDisappear(false)
        XCTAssertEqual(CaptureScreenCopy.leaveTitle, "Leave verification?")
    }

    func testAFlowRunOwnsTheResolvers() {
        CaptureBrandSeed.flowRunActive = true
        let seed = CaptureBrandSeed()
        XCTAssertFalse(seed.seed(appearance: Self.acme, copy: nil, displayName: "X"))
        XCTAssertNil(FlowAppearanceResolver.current)
        CaptureBrandSeed.flowRunActive = false
        XCTAssertTrue(seed.seed(appearance: Self.acme, copy: nil, displayName: "X"))
        seed.clear()
        XCTAssertNil(FlowAppearanceResolver.current)
    }

    func testHostedLayersPutCodeAboveTheDashboard() {
        let server = ServerBranding(displayName: "Org", logoUrl: "https://cdn.example/org.png", primaryColor: "#FF6A00",
                                    appearance: FlowAppearance(colors: AppearanceColors(surface: "#EEEEEE"), mode: .light))
        let layers = CaptureBrandSeed.hostedLayers(
            config: UseSenseConfig(apiKey: "sk", branding: BrandingConfig(appearance: FlowAppearance(shape: AppearanceShape(radius: 6)))),
            sdk: UseSenseBranding(displayName: "App", primaryColor: "#00A86B"),
            server: server)
        XCTAssertEqual(layers.appearance?.colors?.primary, "#00A86B")
        XCTAssertEqual(layers.appearance?.colors?.surface, "#EEEEEE")
        XCTAssertEqual(layers.appearance?.shape?.radius, 6)
        XCTAssertEqual(layers.appearance?.logo?.url, "https://cdn.example/org.png")
        XCTAssertEqual(layers.appearance?.mode, .light)
        XCTAssertEqual(layers.displayName, "App")
    }

    // MARK: copy.capture

    func testCaptureCopyDefaultsAreTodaysStrings() {
        FlowCopyResolver.reset()
        let approved = GuidedScreen.approved.content(appName: "Acme")
        XCTAssertEqual(approved.title, "You're verified")
        XCTAssertEqual(approved.body, "Thanks. You can carry on in Acme.")
        XCTAssertEqual(GuidedScreen.review.content(appName: "acme").body, "This can take a few minutes. Acme will let you know.")
        XCTAssertEqual(GateHint.moveCloser.title, "Move a little closer")
        XCTAssertEqual(GateHint.faceALight.subtitle, "Face a window or lamp")
        XCTAssertEqual(ExtraCheckCopy.sheetTitle, "One more quick check")
        XCTAssertEqual(ExtraCheckCopy.headTurnTitle(.left, first: true), "Turn your head to the left")
        XCTAssertEqual(CaptureCopyText.uploadTitle, "Checking it's you")
        XCTAssertEqual(CaptureCopyText.uploadCaption, "Usually under 10 seconds")
        XCTAssertEqual(CaptureCopyText.shutter, "Tap the button when you're ready")
        XCTAssertEqual(CaptureScreenCopy.keepGoing, "Keep going")
        XCTAssertEqual(GuidedScreen.primerTwoSteps(digits: false).content().tips.count, 3)
    }

    func testCaptureCopyOverridesBlanksAndPlaceholders() {
        var result = CaptureCopy.Result()
        result.approvedTitle = "Welcome to {app}"
        result.approvedBody = "   "
        result.retryTips = ["", "  "]
        var guidance = CaptureCopy.Guidance()
        guidance.closer = "Come closer"
        guidance.ready = "Stay {unknown}"
        var xc = CaptureCopy.ExtraCheck()
        xc.headTurn = "Look {side} please"
        xc.sheetBody = "Turn {side} first."
        FlowCopyResolver.set(FlowCopy(capture: CaptureCopy(guidance: guidance, extraCheck: xc, result: result)))
        FlowCopyResolver.setDisplayName("Acme Bank")

        let approved = GuidedScreen.approved.content()
        XCTAssertEqual(approved.title, "Welcome to Acme Bank", "{app} = display_name")
        XCTAssertEqual(approved.body, "Thanks. You can carry on in Acme Bank.", "blank override = default")
        XCTAssertEqual(GuidedScreen.rejected(canRetry: true, onceMore: false).content().tips,
                       ["Face a window or a lamp", "Hold your phone at eye level"], "all-blank list = default")
        XCTAssertEqual(GateHint.moveCloser.title, "Come closer")
        XCTAssertEqual(CaptureCopyText.ready, "Stay {unknown}", "unknown placeholders stay literal")
        XCTAssertEqual(ExtraCheckCopy.headTurnTitle(.right, first: false), "Look to the right please")
        XCTAssertEqual(ExtraCheckCopy.headTurnTitle(.up, first: true), "Look up please")
        XCTAssertEqual(ExtraCheckCopy.headTurnTitle(.center, first: false), "Now look straight ahead", "centre has its own key")
        XCTAssertEqual(ExtraCheckCopy.sheetBody(for: DebugFixtures.headTurn(["right", "left"])), "Turn to the right first.")
    }

    func testPausedTurnCopyNamesTheSide() {
        XCTAssertEqual(ExtraCheckCopy.pausedTurn(.left), "Then keep turning to the left")
        XCTAssertEqual(ExtraCheckCopy.pausedTurn(.up), "Then keep tilting your head up")
        XCTAssertEqual(ExtraCheckCopy.pausedTurn(.down), "Then keep tilting your head down")
        XCTAssertEqual(ExtraCheckCopy.pausedTurn(.center), "Then look straight ahead")
        var xc = CaptureCopy.ExtraCheck()
        xc.pausedTurnSide = "Keep going {side}"
        xc.pausedLookCentre = "Back to the middle"
        FlowCopyResolver.set(FlowCopy(capture: CaptureCopy(extraCheck: xc)))
        XCTAssertEqual(ExtraCheckCopy.pausedTurn(.right), "Keep going to the right")
        XCTAssertEqual(ExtraCheckCopy.pausedTurn(.center), "Back to the middle")
    }

    func testCaptureCopyMergeAndDecode() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"""
        {"capture":{"primer":{"twoStepsTips":["A","B"],"start":"Go"},"leave":{"title":"Leave?"},"upload":{"title":5}}}
        """#.utf8)) as? [String: Any])
        let dashboard = try XCTUnwrap(FlowCopy.decodeFromJSONObject(json))
        XCTAssertEqual(dashboard.capture?.primer?.twoStepsTips, ["A", "B"])
        XCTAssertNil(dashboard.capture?.upload, "a malformed group is dropped, not the whole copy")
        var leave = CaptureCopy.Leave(); leave.title = " "; leave.body = "Code body"
        let code = FlowCopy(capture: CaptureCopy(leave: leave))
        let merged = FlowCopy.merge(high: code, low: dashboard)
        XCTAssertEqual(merged?.capture?.leave?.title, "Leave?", "blank code value: dashboard shows through")
        XCTAssertEqual(merged?.capture?.leave?.body, "Code body")
        XCTAssertEqual(merged?.capture?.primer?.start, "Go")
    }
}

/// Spec fixtures for copy tests.
enum DebugFixtures {
    static func headTurn(_ sides: [String]) -> ChallengeSpecWrapper {
        let seq = sides.enumerated().map { #"{"direction":"\#($1)","duration_ms":2000,"index":\#($0)}"# }.joined(separator: ",")
        let json = #"{"type":"head_turn","seed":"t","total_duration_ms":4000,"sequence":[\#(seq)]}"#
        return try! JSONDecoder().decode(ChallengeSpecWrapper.self, from: Data(json.utf8))
    }
}
