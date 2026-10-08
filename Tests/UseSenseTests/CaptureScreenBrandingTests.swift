import XCTest
import SwiftUI
import UIKit
@testable import UseSenseSDK

/// The capture screens (instructions, challenges, processing, result) colour
/// from `Color.UseSense.*`. Those tokens must follow the resolved white-label so
/// a branded Flow does not switch back to UseSense blue at the face step.
@MainActor
final class CaptureScreenBrandingTests: XCTestCase {

    override func tearDown() {
        FlowAppearanceResolver.reset()
        super.tearDown()
    }

    private func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    func testPrimaryDefaultsToDeepSenseBlue() {
        FlowAppearanceResolver.reset()
        XCTAssertEqual(hex(Color.UseSense.primary), "#4F7CFF")
        XCTAssertEqual(hex(Color.UseSense.primaryBg), "#EBF0FF")
    }

    func testPrimaryFollowsResolvedAppearance() {
        FlowAppearanceResolver.set(FlowAppearance(colors: AppearanceColors(primary: "#E4572E")))
        XCTAssertEqual(hex(Color.UseSense.primary), "#E4572E")
        XCTAssertEqual(hex(Color.UseSense.qualityInfo), "#E4572E")
    }

    func testStandaloneSessionSeedsAndClearsItsBranding() {
        FlowAppearanceResolver.reset()
        let config = UseSenseConfig(apiKey: "sk_test", branding: BrandingConfig(primaryColor: "#E4572E"))
        let session = UseSenseSession(config: config, sessionType: .enrollment)
        let vc = UseSenseViewController(session: session) { _ in }
        vc.loadViewIfNeeded()
        XCTAssertEqual(FlowAppearanceResolver.current?.colors?.primary, "#E4572E")
        vc.viewDidDisappear(false)
        XCTAssertNil(FlowAppearanceResolver.current)
    }

    func testStandaloneSessionLeavesAFlowRunnersBrandingAlone() {
        let flowBrand = FlowAppearance(colors: AppearanceColors(primary: "#00A86B"))
        FlowAppearanceResolver.set(flowBrand)
        let config = UseSenseConfig(apiKey: "sk_test", branding: BrandingConfig(primaryColor: "#E4572E"))
        let vc = UseSenseViewController(session: UseSenseSession(config: config, sessionType: .enrollment)) { _ in }
        vc.loadViewIfNeeded()
        vc.viewDidDisappear(false)
        XCTAssertEqual(FlowAppearanceResolver.current?.colors?.primary, "#00A86B")
    }
}
