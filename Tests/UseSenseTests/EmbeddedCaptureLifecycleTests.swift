import XCTest
import SwiftUI
import UIKit
@testable import UseSenseSDK

/// `UseSenseViewController` embedded as a child of the host's own screen (React
/// Native, Flutter, a container view), rather than presented by itself.
@MainActor
final class EmbeddedCaptureLifecycleTests: XCTestCase {

    override func tearDown() {
        FlowAppearanceResolver.reset()
        FlowCopyResolver.reset()
        CaptureBrandSeed.flowRunActive = false
        super.tearDown()
    }

    private func makeSession(primary: String = "#E4572E") -> UseSenseSession {
        UseSenseSession(config: UseSenseConfig(apiKey: "sk_test", branding: BrandingConfig(primaryColor: primary)),
                        sessionType: .enrollment)
    }

    private func embed(_ child: UIViewController, in host: UIViewController) {
        host.addChild(child)
        host.view.addSubview(child.view)
        child.didMove(toParent: host)
    }

    private func remove(_ child: UIViewController) {
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }

    // MARK: cancel()

    func testCancelReportsUserCancelledExactlyOnce() {
        var results: [Result<RedactedDecisionObject, UseSenseError>] = []
        let vc = UseSenseViewController(session: makeSession()) { results.append($0) }
        vc.loadViewIfNeeded()
        vc.cancel()
        vc.cancel()
        XCTAssertEqual(results.count, 1)
        if case .failure(let error) = results.first {
            XCTAssertEqual(error.code, .userCancelled)
        } else {
            XCTFail("expected a userCancelled failure")
        }
    }

    // MARK: removal mid-capture

    func testRemovingAnEmbeddedChildMidCaptureReportsOnceAndClearsItsBrand() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        var calls = 0
        var lastCode: UseSenseErrorCode?
        let vc = UseSenseViewController(session: makeSession()) { result in
            calls += 1
            if case .failure(let error) = result { lastCode = error.code }
        }
        embed(vc, in: host)
        vc.loadViewIfNeeded()
        XCTAssertEqual(FlowAppearanceResolver.current?.colors?.primary, "#E4572E")

        remove(vc)
        vc.viewDidDisappear(false)

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(lastCode, .userCancelled)
        XCTAssertNil(FlowAppearanceResolver.current)
    }

    func testRemovalAfterTheCaptureReportedDoesNotReportAgain() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        var calls = 0
        var vcRef: UseSenseViewController?
        let vc = UseSenseViewController(session: makeSession()) { _ in
            calls += 1
            // React Native / Flutter detach the child from inside the callback.
            if let vc = vcRef { self.remove(vc) }
        }
        vcRef = vc
        embed(vc, in: host)
        vc.loadViewIfNeeded()
        vc.cancel()
        vc.viewDidDisappear(false)
        XCTAssertEqual(calls, 1)
    }

    func testInsideAFlowRemovalStopsTheCameraWithoutReporting() {
        // The runner closed the capture itself; a report would cancel the run.
        let host = UIViewController()
        host.loadViewIfNeeded()
        var calls = 0
        let vc = UseSenseViewController(session: makeSession()) { _ in calls += 1 }
        vc.dismissesBeforeCallback = true
        embed(vc, in: host)
        vc.loadViewIfNeeded()
        remove(vc)
        vc.viewDidDisappear(false)
        XCTAssertEqual(calls, 0)
        vc.cancel()
        XCTAssertEqual(calls, 0, "cancel after the runner tore it down reports nothing")
    }

    // MARK: brand while covered

    func testAnEmbeddedChildKeepsItsBrandWhenTheHostIsCovered() {
        // Another screen pushed over the host: the child disappears but is not
        // being removed, so the brand must survive for when it comes back.
        let host = UIViewController()
        host.loadViewIfNeeded()
        var calls = 0
        let vc = UseSenseViewController(session: makeSession()) { _ in calls += 1 }
        embed(vc, in: host)
        vc.loadViewIfNeeded()
        vc.viewDidDisappear(false)
        XCTAssertEqual(FlowAppearanceResolver.current?.colors?.primary, "#E4572E")
        XCTAssertEqual(calls, 0)
    }

    // MARK: SwiftUI view

    func testSwiftUIViewSeedsCodeBrandingOnItsOwn() {
        FlowAppearanceResolver.reset()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let hosting = UIHostingController(rootView: UseSenseView(session: makeSession(primary: "#123456")) { _ in })
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(FlowAppearanceResolver.current?.colors?.primary, "#123456")

        window.rootViewController = UIViewController()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(FlowAppearanceResolver.current)
        window.isHidden = true
    }

    func testSwiftUIViewLeavesAFlowRunnersBrandAlone() {
        let flowBrand = FlowAppearance(colors: AppearanceColors(primary: "#00A86B"))
        FlowAppearanceResolver.set(flowBrand)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: UseSenseView(session: makeSession()) { _ in })
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(FlowAppearanceResolver.current?.colors?.primary, "#00A86B")
        window.rootViewController = UIViewController()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(FlowAppearanceResolver.current?.colors?.primary, "#00A86B")
        window.isHidden = true
    }
}
