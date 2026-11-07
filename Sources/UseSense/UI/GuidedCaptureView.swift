#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit

// MARK: - Colours

/// Capture screen colours: FlowAppearance `capture` over the Sense defaults.
/// A colour under 3:1 contrast on the dark camera scrim (#333333, the same
/// reference Android uses) falls back to the default, so a brand colour can
/// never make the guide unreadable.
struct CaptureColors: Equatable {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
        var color: Color { Color(red: r, green: g, blue: b) }
        func mix(_ o: RGB, _ t: Double) -> RGB {
            RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
        }
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        init(hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
        }
        /// WCAG relative luminance.
        var luminance: Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        func contrast(against o: RGB) -> Double {
            let a = luminance, b = o.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    static let scrim = RGB(hex: 0x333333)
    static let minimumContrast = 3.0
    static let `default` = CaptureColors(
        ring: RGB(hex: 0x4F7CFF), contourStart: RGB(hex: 0x7A96FF),
        contourEnd: RGB(hex: 0xA878FC), warning: RGB(hex: 0xFFB84D)
    )

    var ring: RGB
    var contourStart: RGB
    var contourEnd: RGB
    var warning: RGB

    static func resolve(_ capture: AppearanceCapture?) -> CaptureColors {
        let d = CaptureColors.default
        return CaptureColors(
            ring: pick(capture?.ring, d.ring),
            contourStart: pick(capture?.contourStart, d.contourStart),
            contourEnd: pick(capture?.contourEnd, d.contourEnd),
            warning: pick(capture?.warning, d.warning)
        )
    }

    /// The custom colour when it parses and reads on the scrim; else `fallback`.
    static func pick(_ raw: String?, _ fallback: RGB) -> RGB {
        guard let raw, let c = FlowAppearance.parseHexComponents(raw) else { return fallback }
        let rgb = RGB(r: Double(c.r), g: Double(c.g), b: Double(c.b))
        return rgb.contrast(against: scrim) >= minimumContrast ? rgb : fallback
    }

    /// The active capture colours (Flow / session appearance).
    static var current: CaptureColors { resolve(FlowAppearanceResolver.current?.capture) }
}

// MARK: - Screen fill light

/// Turns the screen into a fill light (brightness to max) and puts the
/// user's brightness back afterwards. Main thread only.
final class ScreenFillLight {
    private var saved: CGFloat?
    var isActive: Bool { saved != nil }

    private var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }

    func activate() {
        guard saved == nil, let screen else { return }
        saved = screen.brightness
        screen.brightness = 1.0
    }

    func restore() {
        guard let value = saved else { return }
        saved = nil
        screen?.brightness = value
    }

    deinit {
        if let value = saved {
            DispatchQueue.main.async { UIScreen.main.brightness = value }
        }
    }
}

// MARK: - Align + scan screen

/// Screens 2-6 of the capture redesign: align (one hint at a time, auto
/// start), low light (fill light), scan (contour lines + ring that pauses),
/// shutter fallback.
struct GuidedCaptureView<Camera: View>: View {
    enum Mode { case align, scan }

    let mode: Mode
    let camera: Camera
    @ObservedObject var viewModel: UseSenseViewModel
    let onClose: () -> Void

    @State private var pulse = false
    @State private var scanStartedAt: Date
    private let fixedDate: Date?

    init(mode: Mode, camera: Camera, viewModel: UseSenseViewModel, onClose: @escaping () -> Void,
         sweepStartedAt: Date = Date(), fixedDate: Date? = nil) {
        self.fixedDate = fixedDate
        self.mode = mode
        self.camera = camera
        self.viewModel = viewModel
        self.onClose = onClose
        self._scanStartedAt = State(initialValue: sweepStartedAt)
    }

    private var colors: CaptureColors { .current }
    private var hint: GateHint? { viewModel.guide.snapshot.hint }
    private var failingHintShown: Bool { hint != nil }
    private var paused: Bool { mode == .scan && viewModel.scan.paused }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let oval = CaptureOvalLayout.ovalRect(in: size)
            ZStack {
                camera

                // Dark scrim with the oval cut out.
                Rectangle()
                    .fill(Color.black.opacity(0.62))
                    .mask(
                        Rectangle().fill(Color.white)
                            .overlay(
                                Ellipse()
                                    .frame(width: oval.width, height: oval.height)
                                    .position(x: oval.midX, y: oval.midY)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )
                    .allowsHitTesting(false)

                if mode == .scan {
                    ContourScanView(
                        field: viewModel.contourField,
                        colors: colors,
                        startedAt: scanStartedAt,
                        dimmed: paused,
                        fixedDate: fixedDate
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                ovalStroke(oval)

                if viewModel.guide.snapshot.fillLight {
                    FillLightBorder().allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    Spacer().frame(height: oval.maxY + 28)
                    hintCard
                        .padding(.horizontal, 24)
                    Spacer()
                    if mode == .align && viewModel.guide.shutterAvailable {
                        shutter
                    }
                    if USTrace.enabled { debugChips.padding(.bottom, 6) }
                }
                .padding(.bottom, CaptureFooter.clearance + 8)

                VStack {
                    HStack {
                        Spacer()
                        closeButton
                    }
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    Spacer()
                }
            }
            .onAppear {
                viewModel.setViewport(size)
                if fixedDate == nil { scanStartedAt = Date() }
                pulse = true
            }
            .onChange(of: size) { viewModel.setViewport($0) }
        }
        .ignoresSafeArea()
    }

    // MARK: Oval + ring

    @ViewBuilder
    private func ovalStroke(_ oval: CGRect) -> some View {
        let failing = failingHintShown && !(mode == .scan && !paused)
        ZStack {
            TopStartEllipse()
                .stroke(failing ? colors.warning.color : Color.white.opacity(mode == .scan ? 0.22 : 0.85),
                        lineWidth: mode == .scan ? 5 : 3)
                .opacity(failing && pulse ? 0.55 : 1)
                .animation(failing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)

            if mode == .scan {
                TopStartEllipse()
                    .trim(from: 0, to: viewModel.scan.fraction)
                    .stroke(paused ? colors.warning.color : colors.ring.color,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .animation(.linear(duration: 0.1), value: viewModel.scan.fraction)
            }
        }
        .frame(width: oval.width, height: oval.height)
        .position(x: oval.midX, y: oval.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Hint

    private var hintCard: some View {
        let shown: (title: String, subtitle: String?, icon: String, warning: Bool)?
        if let hint, mode == .align || paused || hint.check == .light {
            shown = (hint.title, hint.subtitle, Self.symbol(hint.icon), true)
        } else if mode == .scan {
            let total = max(1, Int(viewModel.scan.totalSeconds.rounded()))
            let done = min(total, Int(viewModel.scan.bankedSeconds.rounded(.down)))
            shown = (GateHint.holdStill.title, "Scanning · \(done) of \(total) s", "scope", false)
        } else {
            shown = nil
        }
        return Group {
            if let shown {
                HStack(spacing: 12) {
                    Image(systemName: shown.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(shown.warning ? colors.warning.color : .white)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shown.title)
                            .font(.usBody(16, .medium))
                            .foregroundColor(.white)
                        if let sub = shown.subtitle {
                            Text(sub)
                                .font(.usBody(13))
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("usesense.capture.hint")
                .transition(.opacity)
                .id(shown.title)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shown?.title)
    }

    static func symbol(_ icon: GateHint.Icon) -> String {
        switch icon {
        case .face: return "face.dashed"
        case .people: return "person.2.fill"
        case .centre: return "arrow.left.and.right"
        case .closer: return "arrow.up.left.and.arrow.down.right"
        case .back: return "arrow.down.right.and.arrow.up.left"
        case .pose: return "eye"
        case .light: return "sun.max.fill"
        case .steady: return "iphone"
        case .eyes: return "eye.fill"
        case .still: return "scope"
        }
    }

    // MARK: Shutter

    private var shutter: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("Tap the shutter when you're ready")
                    .font(.usBody(15, .medium))
                    .foregroundColor(.white)
                Text("We'll still scan for \(viewModel.scanSecondsForCopy) seconds")
                    .font(.usBody(13))
                    .foregroundColor(.white.opacity(0.75))
            }
            .multilineTextAlignment(.center)
            Button(action: { viewModel.shutterTapped() }) {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                    Circle().fill(Color.white).frame(width: 60, height: 60)
                }
            }
            .accessibilityLabel("Start scan")
            .accessibilityIdentifier("usesense.capture.shutter")
        }
        .padding(.bottom, 8)
        .transition(.opacity)
    }

    private var debugChips: some View {
        let failing = viewModel.guide.snapshot.failing
        return HStack(spacing: 4) {
            ForEach(GateCheck.allCases, id: \.self) { check in
                Text(check.debugLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(Capsule().fill(failing.contains(check) ? Color.red.opacity(0.7) : Color.green.opacity(0.6)))
            }
        }
        .accessibilityHidden(true)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .accessibilityLabel("Close")
        .padding(.trailing, 16)
    }
}

/// An ellipse whose path starts at 12 o'clock and runs clockwise, so a
/// trimmed stroke fills like a progress ring.
struct TopStartEllipse: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 160
        for i in 0...steps {
            let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(steps)
            let pt = CGPoint(x: rect.midX + rect.width / 2 * CGFloat(cos(a)),
                             y: rect.midY + rect.height / 2 * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// Warm white frame around the screen: with brightness at max it lights the face.
struct FillLightBorder: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Color(red: 1.0, green: 0.96, blue: 0.88), lineWidth: 34)
            .shadow(color: Color(red: 1.0, green: 0.93, blue: 0.8).opacity(0.8), radius: 24)
            .ignoresSafeArea()
            .transition(.opacity)
            .accessibilityHidden(true)
    }
}

// MARK: - Contour scan

/// Horizontal lines displaced by the smoothed mesh depth, clipped to the
/// oval. They sweep in from the top when the scan starts and follow the head
/// as it moves. Core Graphics via Canvas: ~26 lines x 57 points at 30 fps.
struct ContourScanView: View {
    let field: ContourDepthField
    let colors: CaptureColors
    let startedAt: Date
    var dimmed: Bool
    /// Draw one frame at this time instead of animating (snapshots).
    var fixedDate: Date? = nil

    static let lineCount = 26
    static let samples = 56
    static let sweepSeconds = 0.9

    var body: some View {
        Group {
            if let fixedDate {
                frame(at: fixedDate)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    frame(at: timeline.date)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func frame(at date: Date) -> some View {
            Canvas { g, size in
                let oval = CaptureOvalLayout.ovalRect(in: size)
                let snap = field.snapshot()
                let reveal = min(1, date.timeIntervalSince(startedAt) / Self.sweepSeconds)
                g.clip(to: Path(ellipseIn: oval))
                let amp = max(snap.rect.width, oval.width * 0.6) * 0.22
                for i in 0..<Self.lineCount {
                    let f = (Double(i) + 0.5) / Double(Self.lineCount)
                    guard f <= reveal else { break }
                    let baseY = oval.minY + oval.height * CGFloat(f)
                    var path = Path()
                    var onFace: Float = 0
                    for k in 0...Self.samples {
                        let x = oval.minX + oval.width * CGFloat(k) / CGFloat(Self.samples)
                        let s = snap.sample(CGPoint(x: x, y: baseY))
                        onFace = max(onFace, s.mask)
                        let pt = CGPoint(x: x, y: baseY - CGFloat(s.depth * s.mask) * amp)
                        if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    let c = colors.contourStart.mix(colors.contourEnd, f)
                    let alpha = (dimmed ? 0.3 : 0.85) * (0.35 + 0.65 * Double(onFace))
                    g.stroke(path, with: .color(c.color.opacity(alpha)), lineWidth: 1.6)
                }
                if reveal < 1 {
                    let y = oval.minY + oval.height * CGFloat(reveal)
                    let beam = Path(CGRect(x: oval.minX, y: y - 1.5, width: oval.width, height: 3))
                    g.fill(beam, with: .color(colors.contourEnd.color.opacity(0.9)))
                }
            }
    }
}

// MARK: - Upload

/// Screen 7: the last frame blurred out for privacy behind one sheet, with
/// one progress bar for upload and checking.
struct GuidedUploadView: View {
    let backdrop: UIImage?
    let progress: Double

    private var colors: CaptureColors { .current }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let backdrop {
                    Image(uiImage: backdrop)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(x: -1, y: 1)
                        .blur(radius: 36, opaque: true)
                        .overlay(Color.black.opacity(0.35))
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack(spacing: 14) {
                Text("Checking it's you")
                    .font(.usDisplay(20, .bold))
                    .foregroundColor(.white)
                Text("Usually 3–5 seconds")
                    .font(.usBody(14))
                    .foregroundColor(.white.opacity(0.7))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15)).frame(height: 6)
                        Capsule().fill(colors.ring.color)
                            .frame(width: geo.size.width * CGFloat(min(1, max(0.04, progress))), height: 6)
                            .animation(.easeOut(duration: 3), value: progress)
                    }
                }
                .frame(height: 6)
                .accessibilityElement()
                .accessibilityLabel("Checking it's you")
                .accessibilityValue("\(Int(progress * 100)) percent")
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 28 + CaptureFooter.clearance)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.1))
                    .ignoresSafeArea(edges: .bottom)
            )
            .accessibilityIdentifier("usesense.capture.upload")
        }
    }
}
#endif
