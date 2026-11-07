import XCTest
import SwiftUI
@testable import UseSenseSDK

/// Renders the guided capture screens to PNG for review (PR screenshots).
/// The simulator has no camera, so a drawn stand-in face and a synthetic
/// mesh replace them. Opt-in: runs only with USESENSE_SNAPSHOT_DIR set
/// (pass `TEST_RUNNER_USESENSE_SNAPSHOT_DIR=<dir>` to xcodebuild).
@MainActor
final class GuidedCaptureSnapshotTests: XCTestCase {
    private let size = CGSize(width: 393, height: 852)

    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["USESENSE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// A soft, lit face shape where the oval is, on a dim room background.
    private var standInCamera: some View {
        let oval = CaptureOvalLayout.ovalRect(in: size)
        return ZStack {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.18)], startPoint: .top, endPoint: .bottom)
            Ellipse()
                .fill(RadialGradient(colors: [Color(red: 0.86, green: 0.68, blue: 0.56), Color(red: 0.55, green: 0.38, blue: 0.29)],
                                     center: .init(x: 0.45, y: 0.4), startRadius: 10, endRadius: 170))
                .frame(width: oval.width * 0.78, height: oval.height * 0.86)
                .position(x: oval.midX, y: oval.midY + 6)
        }
        .frame(width: size.width, height: size.height)
    }

    /// A face-like relief: dome, nose ridge, eye sockets, lips.
    private func syntheticMesh(_ field: ContourDepthField) {
        let oval = CaptureOvalLayout.ovalRect(in: size)
        var points: [CGPoint] = []
        var z: [Double] = []
        for j in 0..<26 {
            for i in 0..<20 {
                let u = Double(i) / 19 * 2 - 1, v = Double(j) / 25 * 2 - 1
                guard u * u + v * v <= 1 else { continue }
                points.append(CGPoint(x: oval.midX + CGFloat(u) * oval.width * 0.38,
                                      y: oval.midY + 6 + CGFloat(v) * oval.height * 0.42))
                func bump(_ cu: Double, _ cv: Double, _ s: Double) -> Double {
                    exp(-((u - cu) * (u - cu) + (v - cv) * (v - cv)) / (2 * s * s))
                }
                let h = 0.55 * (1 - u * u - v * v)
                    + 0.55 * bump(0, 0.05, 0.13) + 0.3 * bump(0, -0.2, 0.1)
                    - 0.3 * bump(-0.38, -0.25, 0.15) - 0.3 * bump(0.38, -0.25, 0.15)
                    + 0.15 * bump(0, 0.5, 0.16)
                z.append(-0.1 * h)
            }
        }
        for _ in 0..<12 { field.update(points: points, z: z) }
    }

    private func render<V: View>(_ view: V, _ name: String) throws {
        guard let dir = outputDir else { throw XCTSkip("USESENSE_SNAPSHOT_DIR not set") }
        guard #available(iOS 16.0, *) else { throw XCTSkip("ImageRenderer needs iOS 16") }
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = 3
        guard let image = renderer.uiImage, let png = image.pngData() else { return XCTFail("render failed: \(name)") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func model(hint: GateHint?, allPass: Bool = false, fillLight: Bool = false,
                       shutter: Bool = false, scan: ScanProgress? = nil) -> UseSenseViewModel {
        let session = UseSenseSession(config: UseSenseConfig(apiKey: "sk_test"), sessionType: .enrollment)
        let vm = UseSenseViewModel(session: session)
        vm.guide = GuidedCaptureUpdate(
            snapshot: GuideSnapshot(allPass: allPass, hint: hint, fillLight: fillLight,
                                    failing: hint.map { [$0.check] } ?? []),
            shutterAvailable: shutter
        )
        if let scan { vm.scan = scan }
        return vm
    }

    private func screen(_ mode: GuidedCaptureView<AnyView>.Mode, _ vm: UseSenseViewModel) -> some View {
        GuidedCaptureView(mode: mode, camera: AnyView(standInCamera), viewModel: vm, onClose: {},
                          sweepStartedAt: Date().addingTimeInterval(-5), fixedDate: Date())
            .overlay(alignment: .bottom) { CaptureFooter() }
            .background(Color.black)
    }

    func testRenderGuidedScreens() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("ImageRenderer needs iOS 16") }
        try render(screen(.align, model(hint: .centre)), "2-align-centre")
        try render(screen(.align, model(hint: .brightening, fillLight: true)), "3-low-light-fill")
        try render(screen(.align, model(hint: .faceALight, fillLight: true)), "3b-low-light-hint")

        let scanning = model(hint: nil, allPass: true,
                             scan: ScanProgress(fraction: 0.45, paused: false, bankedSeconds: 4.5, totalSeconds: 10, completed: false))
        syntheticMesh(scanning.contourField)
        try render(screen(.scan, scanning), "4-scan")

        let paused = model(hint: .holdStill,
                           scan: ScanProgress(fraction: 0.45, paused: true, bankedSeconds: 4.5, totalSeconds: 10, completed: false))
        syntheticMesh(paused.contourField)
        try render(screen(.scan, paused), "4b-scan-paused")

        try render(screen(.align, model(hint: nil, shutter: true)), "6-shutter")

        let backdropRenderer = ImageRenderer(content: standInCamera)
        let backdrop = try XCTUnwrap(backdropRenderer.uiImage)
        try render(GuidedUploadView(backdrop: backdrop, progress: 0.55)
            .overlay(alignment: .bottom) { CaptureFooter() }, "7-upload")

        // A brand ring colour too dark for the scrim falls back to the default;
        // a readable one is used.
        FlowAppearanceResolver.set(FlowAppearance(capture: AppearanceCapture(ring: "#00D4AA", contourStart: "#00D4AA", contourEnd: "#7C5CFC")))
        defer { FlowAppearanceResolver.reset() }
        let branded = model(hint: nil, allPass: true,
                            scan: ScanProgress(fraction: 0.7, paused: false, bankedSeconds: 7, totalSeconds: 10, completed: false))
        syntheticMesh(branded.contourField)
        try render(screen(.scan, branded), "8-scan-custom-colours")
    }
}

