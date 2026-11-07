import XCTest
@testable import UseSenseSDK

/// Branding precedence v1 ("code wins"): per field, code beats the dashboard,
/// the dashboard beats the built-in defaults, and nothing counts unless it was
/// explicitly set.
final class BrandingPrecedenceTests: XCTestCase {

    private func response(branding: String?) throws -> CreateSessionResponse {
        let brandingField = branding.map { #","branding":\#($0)"# } ?? ""
        let json = #"""
        {"session_id":"sess_b","session_token":"tok","expires_at":"2099-01-01T00:00:00.000Z","nonce":"n",
         "policy":{"requires_audio":false,"requires_stepup":false,"challenge_type":"none"},
         "upload":{"max_frames":30,"target_fps":3,"capture_duration_ms":2500}\#(brandingField)}
        """#
        return try JSONDecoder().decode(CreateSessionResponse.self, from: Data(json.utf8))
    }

    private func session(branding: BrandingConfig? = nil) -> UseSenseSession {
        UseSenseSession(
            config: UseSenseConfig(apiEndpoint: "http://127.0.0.1:9/v1", apiKey: "sk_test", branding: branding),
            sessionType: .enrollment
        )
    }

    private let xtransfer = #"""
    {"display_name":"XTransfer","logo_url":"https://cdn.example/xt.png","primary_color":"#FF6A00",
     "appearance":{"colors":{"primaryForeground":"#FFFFFF"},"shape":{"buttonRadius":6}}}
    """#

    // MARK: Resolver: field by field

    func test_codeWinsPerField_dashboardShowsThroughWhereCodeIsUnset() {
        let code = FlowAppearance(colors: AppearanceColors(primary: "#111111"))
        let dashboard = FlowAppearance(
            colors: AppearanceColors(primary: "#FF6A00", primaryForeground: "#FFFFFF"),
            logo: AppearanceLogo(url: "https://cdn.example/xt.png")
        )
        let merged = BrandingResolver.resolve(code: code, dashboard: dashboard)
        XCTAssertEqual(merged?.colors?.primary, "#111111", "code wins")
        XCTAssertEqual(merged?.colors?.primaryForeground, "#FFFFFF", "unset in code: dashboard shows through")
        XCTAssertEqual(merged?.logo?.url, "https://cdn.example/xt.png", "a code colour must not hide the dashboard logo")
    }

    func test_unsetConfig_doesNotOverrideDashboard() {
        // BrandingConfig() still carries concrete legacy defaults for old
        // screens, but they must not occupy the code layer.
        let code = BrandingConfig().resolvedAppearance
        XCTAssertNil(code?.colors?.primary)
        XCTAssertNil(code?.shape?.buttonRadius, "the default radius (10) is not a code choice")
        let merged = BrandingResolver.resolve(
            code: code,
            dashboard: FlowAppearance(colors: AppearanceColors(primary: "#FF6A00"), shape: AppearanceShape(buttonRadius: 6))
        )
        XCTAssertEqual(merged?.colors?.primary, "#FF6A00")
        XCTAssertEqual(merged?.shape?.buttonRadius, 6)
    }

    func test_explicitConfig_beatsDashboard() {
        let code = BrandingConfig(primaryColor: "#222222", buttonRadius: 16).resolvedAppearance
        let merged = BrandingResolver.resolve(
            code: code,
            dashboard: FlowAppearance(colors: AppearanceColors(primary: "#FF6A00"), shape: AppearanceShape(buttonRadius: 6))
        )
        XCTAssertEqual(merged?.colors?.primary, "#222222")
        XCTAssertEqual(merged?.shape?.buttonRadius, 16)
    }

    func test_dashboardNullColour_fallsToBuiltInDefault() {
        let dashboard = ServerBranding(displayName: "XTransfer", primaryColor: nil).resolvedAppearance
        XCTAssertNil(dashboard?.colors?.primary, "no configured colour: the built-in default applies where tokens are read")
        XCTAssertNil(BrandingResolver.resolve(code: nil, dashboard: dashboard)?.colors?.primary)
    }

    // MARK: Wire

    func test_blankServerFields_areUnset() {
        let b = ServerBranding(displayName: "  ", logoUrl: "", primaryColor: "", redirectUrl: nil)
        XCTAssertNil(b.displayName)
        XCTAssertNil(b.logoUrl)
        XCTAssertNil(b.primaryColor)
        XCTAssertNil(b.resolvedAppearance)
    }

    func test_sessionResponse_decodesBranding() throws {
        let r = try response(branding: xtransfer)
        XCTAssertEqual(r.branding?.displayName, "XTransfer")
        XCTAssertEqual(r.branding?.primaryColor, "#FF6A00")
        let layer = r.branding?.resolvedAppearance
        XCTAssertEqual(layer?.colors?.primary, "#FF6A00", "legacy flat colour folds into the dashboard layer")
        XCTAssertEqual(layer?.colors?.primaryForeground, "#FFFFFF")
        XCTAssertEqual(layer?.logo?.url, "https://cdn.example/xt.png")
    }

    func test_sessionResponse_nullOrAbsentOrMalformedBranding_stillDecodes() throws {
        XCTAssertNil(try response(branding: nil).branding)
        XCTAssertNil(try response(branding: "null").branding)
        XCTAssertNil(try response(branding: #""oops""#).branding, "a malformed block never fails the session")
    }

    func test_flowRunView_unsetBrandingFields_areNil_notDefaults() throws {
        let json: [String: Any] = [
            "flowRun": ["id": "fr_1", "state": "in_progress", "environment": "sandbox"],
            "branding": ["primary_color": "", "logo_url": "https://cdn.example/xt.png"],
        ]
        let view = try FlowRunView.decode(json)
        XCTAssertNil(view.branding?.displayName, "no more \"Sense\" default in the model")
        XCTAssertNil(view.branding?.primaryColor, "no more #4F7CFF default in the model")
        XCTAssertEqual(view.branding?.logoURL?.absoluteString, "https://cdn.example/xt.png")
    }

    // MARK: Session mode

    func test_sessionMode_dashboardBrandingApplies_underCode() throws {
        let plain = session()
        plain.injectHostedSessionData(try response(branding: xtransfer))
        XCTAssertEqual(plain.brandingAppearance?.colors?.primary, "#FF6A00", "dashboard shows in session mode")
        XCTAssertEqual(plain.brandingAppearance?.logo?.url, "https://cdn.example/xt.png")

        let coded = session(branding: BrandingConfig(primaryColor: "#222222"))
        coded.injectHostedSessionData(try response(branding: xtransfer))
        XCTAssertEqual(coded.brandingAppearance?.colors?.primary, "#222222", "code wins")
        XCTAssertEqual(coded.brandingAppearance?.logo?.url, "https://cdn.example/xt.png", "per field")
    }

    func test_sessionMode_publishesBrandingWhenItArrives() throws {
        let s = session()
        let got = expectation(description: "branding published")
        s.onBrandingAvailable = { appearance in
            XCTAssertEqual(appearance?.colors?.primary, "#FF6A00")
            got.fulfill()
        }
        s.injectHostedSessionData(try response(branding: xtransfer))
        wait(for: [got], timeout: 2)
    }

    func test_traceNamesTheSourceOfEachField() {
        let line = BrandingResolver.describeSources(
            code: FlowAppearance(colors: AppearanceColors(primary: "#111111")),
            dashboard: FlowAppearance(colors: AppearanceColors(primary: "#FF6A00", primaryForeground: "#FFFFFF"))
        )
        XCTAssertTrue(line.contains("primary=#111111 (code)"))
        XCTAssertTrue(line.contains("primaryForeground=#FFFFFF (dashboard)"))
        XCTAssertTrue(line.contains("background=default"))
    }
}
