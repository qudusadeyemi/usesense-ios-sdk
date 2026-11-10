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

// MARK: - Tokens (capture test kit SPEC; reference/index.html `SPEC`)

enum CaptureTokens {
    static let cam = Color(red: 13 / 255, green: 15 / 255, blue: 20 / 255)     // #0d0f14
    static let panel = Color(red: 29 / 255, green: 32 / 255, blue: 41 / 255)   // #1d2029
    static let ink = Color(red: 244 / 255, green: 245 / 255, blue: 248 / 255)  // #f4f5f8
    static let ink2 = Color(red: 163 / 255, green: 169 / 255, blue: 184 / 255) // #a3a9b8
    /// Fill light veil colour (#FFF4E2, as Android).
    static let fillVeil = Color(red: 1, green: 244 / 255, blue: 226 / 255)
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
    static let uploadCopy = "Usually under 10 seconds"
    static let shutterCopy = "Tap the button when you're ready"
}

// MARK: - Align + scan screen

/// Align (one instruction at a time, auto start), low light (fill light),
/// scan (edge-to-edge contour lines + a ring that pauses) and the shutter
/// fallback. Layout follows the capture test kit SPEC exactly.
struct GuidedCaptureView<Camera: View>: View {
    enum Mode { case align, scan }

    let mode: Mode
    let camera: Camera
    @ObservedObject var viewModel: UseSenseViewModel
    let onClose: () -> Void

    @State private var scanStartedAt: Date
    @State private var showHelp = false
    @State private var cameraBlurred = false
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
    private var paused: Bool { mode == .scan && viewModel.scan.paused }
    private var fillLight: Bool { viewModel.guide.snapshot.fillLight }
    private var showShutter: Bool { mode == .align && viewModel.guide.shutterAvailable }

    /// The instruction shown, and whether it asks for an action.
    private var guidance: (title: String, subtitle: String?, action: Bool) {
        if showShutter { return (CaptureTokens.shutterCopy, nil, true) }
        if let hint, mode == .align || paused || hint.check == .light {
            return (hint.title, hint.subtitle, hint.check != .stillness)
        }
        return (GateHint.holdStill.title, nil, false)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let oval = CaptureOvalLayout.ovalRect(in: size)
            let insets = Self.windowInsets
            ZStack(alignment: .topLeading) {
                camera.frame(width: size.width, height: size.height)

                // Relief v3.1: 1.5 s into the scan the camera blurs (18 pt) so
                // the lines carry the shape. Align mode never shows it.
                if mode == .scan && (cameraBlurred || fixedDate != nil) {
                    CameraBlurView()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }

                if mode == .scan {
                    CaptureTokens.cam.opacity(CaptureTokens.feedDimDuringScan)
                        .allowsHitTesting(false)
                    ContourScanView(field: viewModel.contourField, colors: colors,
                                    startedAt: scanStartedAt, dimmed: paused, fixedDate: fixedDate)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                // Fill light: a warm veil over the whole screen, under the
                // guide (as Android). A border made the camera look inset.
                if fillLight { FillLightVeil().allowsHitTesting(false) }

                guideOrRing(oval)

                guidanceText
                    .frame(width: size.width - 48)
                    .offset(x: 24, y: oval.maxY + CaptureTokens.hintGapBelowOval)

                if showShutter || Self.showsGateChips {
                    VStack(spacing: 14) {
                        Spacer()
                        if Self.showsGateChips { debugChips }
                        if showShutter { shutterButton }
                    }
                    .frame(width: size.width, height: size.height - insets.bottom - 24)
                }

                CaptureTopBar(onBack: onClose, onHelp: { showHelp = true })
                    .padding(.horizontal, 16)
                    .frame(width: size.width)
                    .padding(.top, max(CaptureTokens.topBarTop, insets.top))
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 0.3), value: fillLight)
            .animation(.easeInOut(duration: 0.3), value: showShutter)
            .animation(.easeInOut(duration: 0.3), value: cameraBlurred)
            .task(id: mode == .scan) {
                guard mode == .scan else { cameraBlurred = false; return }
                try? await Task.sleep(nanoseconds: UInt64(CameraBlurView.afterSeconds * 1e9))
                if !Task.isCancelled, mode == .scan { cameraBlurred = true }
            }
            .onAppear {
                viewModel.setViewport(size)
                if fixedDate == nil { scanStartedAt = Date() }
            }
            .onChange(of: size) { viewModel.setViewport($0) }
        }
        .ignoresSafeArea()
        .alert("Quick face scan", isPresented: $showHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Look straight at the screen with a neutral face. Face the light; your screen will brighten to help. The scan starts by itself when your face is in the oval and still.")
        }
    }

    /// Gate debug chips: off by default in every build. DEBUG builds show them
    /// only with the explicit opt-in `USESENSE_DEBUG_GATE=1`; Release can't.
    static var showsGateChips: Bool {
        #if DEBUG
        return DebugCaptureRig.value("USESENSE_DEBUG_GATE") == "1"
        #else
        return false
        #endif
    }

    /// The window's safe-area insets (the GeometryReader ignores the safe
    /// area, so its own insets read zero).
    static var windowInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    }

    // MARK: Guide (align) / ring (scan)

    private func guideOrRing(_ oval: CGRect) -> some View {
        ZStack {
            if mode == .align {
                Ellipse()
                    .fill(Color.white.opacity(CaptureTokens.guideFill))
                    .frame(width: oval.width, height: oval.height)
                Ellipse()
                    .stroke(guidance.action ? colors.warning.color : Color.white.opacity(CaptureTokens.guideStroke),
                            lineWidth: CaptureTokens.guideWidth)
                    .frame(width: oval.width, height: oval.height)
                    .animation(.easeInOut(duration: 0.2), value: guidance.action)
            } else {
                let g = CaptureTokens.ringGap
                ZStack {
                    TopStartEllipse()
                        .stroke(Color.white.opacity(CaptureTokens.ringTrack), lineWidth: CaptureTokens.ringWidth)
                    TopStartEllipse()
                        .trim(from: 0, to: viewModel.scan.fraction)
                        .stroke(paused ? colors.warning.color : colors.ring.color,
                                style: StrokeStyle(lineWidth: CaptureTokens.ringWidth, lineCap: .round))
                        .animation(.linear(duration: 0.1), value: viewModel.scan.fraction)
                }
                .frame(width: oval.width + 2 * g, height: oval.height + 2 * g)
            }
        }
        .position(x: oval.midX, y: oval.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Guidance text (SPEC v1.1: plain text, no box, no icon, no counters)

    private var guidanceText: some View {
        let g = guidance
        let key = g.title + (g.subtitle ?? "")
        return ZStack(alignment: .top) {
            VStack(spacing: 6) {
                Text(g.title)
                    .font(.usBody(22, .semibold))
                    .tracking(-0.22)
                if let sub = g.subtitle {
                    Text(sub)
                        .font(.usBody(15, .medium))
                        .foregroundColor(.white.opacity(0.82))
                }
            }
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.45), radius: 7, y: 2)
            .frame(maxWidth: .infinity)
            .id(key)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: key)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("usesense.capture.hint")
    }

    // MARK: Shutter, chips

    private var shutterButton: some View {
        Button(action: { viewModel.shutterTapped() }) {
            Circle()
                .fill(Color.white)
                .frame(width: 72, height: 72)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 6).padding(-6))
        }
        .accessibilityLabel("Start scan")
        .accessibilityIdentifier("usesense.capture.shutter")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var debugChips: some View {
        let failing = viewModel.guide.snapshot.failing
        return HStack(spacing: 3) {
            ForEach(GateCheck.allCases, id: \.self) { check in
                let bad = failing.contains(check)
                Text(check.debugLabel)
                    .font(.usMono(9))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundColor(bad ? Color(red: 1, green: 0.8, blue: 0.48) : Color(red: 0.37, green: 0.94, blue: 0.8))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(Capsule().fill(bad ? Color(red: 1, green: 0.72, blue: 0.3).opacity(0.18)
                                                   : Color(red: 0, green: 0.83, blue: 0.67).opacity(0.16)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Back (left) and help (right): 32 pt circles, 16 pt from the sides.
struct CaptureTopBar: View {
    let onBack: () -> Void
    var onHelp: (() -> Void)?

    var body: some View {
        HStack {
            circle("arrow.left", label: "Back", action: onBack)
            Spacer()
            if let onHelp { circle("questionmark", label: "Help", action: onHelp) }
        }
    }

    private func circle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(CaptureTokens.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(CaptureTokens.cam.opacity(0.55)))
                .contentShape(Circle().inset(by: -6))
        }
        .accessibilityLabel(label)
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
/// Screen fill light: a warm white veil over the whole preview, with the
/// screen at full brightness. Lights the face while the camera shows through.
struct FillLightVeil: View {
    static let opacity = 0.38
    var body: some View {
        CaptureTokens.fillVeil.opacity(Self.opacity)
            .ignoresSafeArea()
            .transition(.opacity)
            .accessibilityHidden(true)
    }
}

// MARK: - Contour scan

/// Blurs whatever is behind it (the live camera layer, which SwiftUI's
/// `.blur` can't reach). A system blur held part way by a paused animator,
/// so its strength is about 18 pt (RELIEF-v3 "Camera blur", at 1.5 s in v3.1), without the
/// full material tint. Re-applied when the view returns to a window, since
/// iOS finishes paused animators on backgrounding.
struct CameraBlurView: UIViewRepresentable {
    static let afterSeconds = 1.5
    static let fraction: CGFloat = 0.42

    final class Host: UIVisualEffectView {
        private var animator: UIViewPropertyAnimator?
        private var observer: NSObjectProtocol?
        override init(effect: UIVisualEffect?) {
            super.init(effect: effect)
            isUserInteractionEnabled = false
            observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                self?.apply()
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            apply()
        }
        func apply() {
            animator?.stopAnimation(true)
            effect = nil
            let a = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
                self?.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            }
            a.pausesOnCompletion = true
            a.fractionComplete = CameraBlurView.fraction
            animator = a
        }
        deinit {
            animator?.stopAnimation(true)
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeUIView(context: Context) -> Host {
        Host(effect: nil)
    }

    func updateUIView(_ uiView: Host, context: Context) {}
}

/// Contour lines across the whole screen (SPEC "Contour lines", relief v3.1;
/// reference `drawLines`): 9 pt apart, 1.3 pt, from the top to 84% of the
/// height (fading over the last 14%), sampled every 3 pt. Each line bulges
/// away from the bump's centre and lifts over the face detail:
///   y' = max(y + A ry f tanh((y - cy) / (0.25 ry)) - 0.12 ry detail, yAbove + 2.5)
/// with A 0.50 above the centre and 0.32 below. The detail lift isn't scaled
/// by the tanh, so the nose, brow and lips show where they are. Packed lines
/// fade: alpha x (0.25 + 0.75 clamp(gap / spacing)). One colour (the ring
/// colour) at alpha 0.90. Lines sweep in top to bottom over 520 ms. Runs of
/// equal alpha are stroked as one path, so joints don't double up.
struct ContourScanView: View {
    let field: ContourDepthField
    let colors: CaptureColors
    let startedAt: Date
    var dimmed: Bool
    /// Draw one frame at this time, fully swept in (screenshots).
    var fixedDate: Date? = nil

    static let spacing: CGFloat = 9
    static let lineWidth: CGFloat = 1.3
    static let sampleStep: CGFloat = 3
    static let bottomOfH: CGFloat = 0.84
    static let fadeOfH: CGFloat = 0.14
    static let ampUp: CGFloat = 0.50
    static let ampDown: CGFloat = 0.32
    static let tanhOfRy: CGFloat = 0.25
    static let detailLiftOfRy: CGFloat = 0.12
    static let minGap: CGFloat = 2.5
    static let packedAlphaFloor = 0.25
    static let alpha = 0.90
    static let sweepMs = 520.0
    static let lineFadeMs = 140.0
    /// Final alpha is quantised to this many steps; one path per step.
    private static let aBuckets = 40

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

    /// Lines as y values per sample, top to bottom, with the minimum gap
    /// applied to every line (shown or not), plus each sample's gap to the
    /// line above.
    static func layout(_ snap: ContourDepthField.Snapshot, size: CGSize)
        -> (ys: [[CGFloat]], gaps: [[CGFloat]], baseY: [CGFloat]) {
        let bottom = size.height * bottomOfH
        let count = max(1, Int((bottom / spacing).rounded(.down)))
        let nS = Int((size.width / sampleStep).rounded(.up)) + 2
        let ry = max(1, snap.bumpRy)
        var prev = [CGFloat](repeating: -1e9, count: nS)
        var ys: [[CGFloat]] = [], gaps: [[CGFloat]] = [], baseY: [CGFloat] = []
        ys.reserveCapacity(count + 1); gaps.reserveCapacity(count + 1)
        for k in 0...count {
            let y = CGFloat(k) * spacing
            let t = CGFloat(tanh(Double((y - snap.bumpCy) / (tanhOfRy * ry))))
            let push = (t < 0 ? ampUp : ampDown) * ry * t
            let lift = detailLiftOfRy * ry
            var cur = [CGFloat](repeating: 0, count: nS)
            var gap = [CGFloat](repeating: 0, count: nS)
            for j in 0..<nS {
                let x = CGFloat(j) * sampleStep
                let yb = y + push * CGFloat(snap.sample(x, y)) - lift * CGFloat(snap.sampleDetail(x, y))
                cur[j] = max(yb, prev[j] + minGap)
                gap[j] = cur[j] - prev[j]
            }
            prev = cur
            ys.append(cur); gaps.append(gap); baseY.append(y)
        }
        return (ys, gaps, baseY)
    }

    /// Packed-line alpha factor for segment j (min gap of its two ends),
    /// quantised to 1/20 as the reference.
    static func packedFactor(_ gap: [CGFloat], _ j: Int) -> Double {
        let squeeze = min(1, max(0, Double(min(gap[j - 1], gap[j]) / spacing)))
        return (20 * (packedAlphaFloor + (1 - packedAlphaFloor) * squeeze)).rounded() / 20
    }

    private func frame(at date: Date) -> some View {
        Canvas { g, size in
            let snap = field.snapshot()
            guard snap.hasFace else { return }
            let bottom = size.height * Self.bottomOfH
            let fadeStart = bottom - size.height * Self.fadeOfH
            let lines = Self.layout(snap, size: size)
            let count = lines.ys.count - 1
            let revealMs = fixedDate != nil ? 1e9 : date.timeIntervalSince(startedAt) * 1000
            var paths = [Path](repeating: Path(), count: Self.aBuckets + 1)
            for k in 0...count {
                let y = lines.baseY[k]
                let appearAt = Double(k) / Double(count) * Self.sweepMs
                let a0 = min(1, max(0, (revealMs - appearAt) / Self.lineFadeMs))
                guard a0 > 0 else { continue }
                let edge = y > fadeStart ? Double(1 - (y - fadeStart) / (bottom - fadeStart)) : 1
                let base = a0 * edge * (dimmed ? 0.55 : 1)
                guard base > 0.01 else { continue }
                let cur = lines.ys[k], gap = lines.gaps[k]
                var j = 1
                while j < cur.count {
                    let a = Self.packedFactor(gap, j)
                    var e = j
                    while e + 1 < cur.count, Self.packedFactor(gap, e + 1) == a { e += 1 }
                    let bucket = min(Self.aBuckets, Int((base * a * Double(Self.aBuckets)).rounded()))
                    if bucket > 0 {
                        paths[bucket].move(to: CGPoint(x: CGFloat(j - 1) * Self.sampleStep, y: cur[j - 1]))
                        for m in j...e { paths[bucket].addLine(to: CGPoint(x: CGFloat(m) * Self.sampleStep, y: cur[m])) }
                    }
                    j = e + 1
                }
            }
            let style = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
            let c = colors.ring.color
            for (bucket, path) in paths.enumerated() where bucket > 0 && !path.isEmpty {
                g.stroke(path, with: .color(c.opacity(Self.alpha * Double(bucket) / Double(Self.aBuckets))), style: style)
            }
        }
    }
}

// MARK: - Upload

/// The upload bar's motion. It never sits still while waiting: each stage
/// eases toward a cap it never reaches, so a slow server check (6-7 s seen on
/// device) reads as working, not stuck. Display only: the real progress is
/// just "sending" then "checking" then "done".
struct UploadBar: Equatable {
    enum Stage: Equatable { case sending, checking, done }

    var stage: Stage
    /// Where this stage started from (the bar never jumps back).
    var startValue: Double
    var since: Date
    /// Hold one value (debug rig screenshots).
    var fixed: Double?

    static let sendingCap = 0.6, sendingTau: TimeInterval = 1.5
    static let checkingCap = 0.95, checkingTau: TimeInterval = 5
    static let floor = 0.04

    static func start(at date: Date = Date()) -> UploadBar {
        UploadBar(stage: .sending, startValue: floor, since: date)
    }

    func value(at date: Date) -> Double {
        if let fixed { return fixed }
        let t = max(0, date.timeIntervalSince(since))
        func ease(_ cap: Double, _ tau: TimeInterval) -> Double {
            let from = min(startValue, cap)
            return cap - (cap - from) * exp(-t / tau)
        }
        switch stage {
        case .sending: return ease(Self.sendingCap, Self.sendingTau)
        case .checking: return ease(Self.checkingCap, Self.checkingTau)
        case .done: return 1
        }
    }

    /// Move to a later stage from where the bar is now; earlier or equal
    /// stages are ignored.
    func advanced(to next: Stage, at date: Date = Date()) -> UploadBar {
        guard fixed == nil, next != stage, !(stage == .checking && next == .sending), stage != .done else { return self }
        return UploadBar(stage: next, startValue: value(at: date), since: date)
    }
}

/// Upload: the whole screen blurred (14 pt) under a bottom sheet with one
/// progress bar for upload and checking (SPEC "Upload").
struct GuidedUploadView: View {
    let backdrop: UIImage?
    let bar: UploadBar
    /// The scan's last contour field, drawn under the blur as on web.
    var field: ContourDepthField?
    let onBack: () -> Void

    private var colors: CaptureColors { .current }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ZStack {
                    ZStack {
                        CaptureTokens.cam
                        if let backdrop {
                            Image(uiImage: backdrop)
                                .resizable()
                                .scaledToFill()
                                .scaleEffect(x: -1, y: 1)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        }
                        CaptureTokens.cam.opacity(CaptureTokens.feedDimDuringScan)
                        if let field {
                            ContourScanView(field: field, colors: colors, startedAt: .distantPast,
                                            dimmed: false, fixedDate: Date())
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .drawingGroup(opaque: true)
                    .blur(radius: 14, opaque: true)
                    CaptureTokens.cam.opacity(0.25)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .accessibilityHidden(true)

                CaptureTopBar(onBack: onBack, onHelp: {})
                    .padding(.horizontal, 16)
                    .frame(width: geo.size.width)
                    .padding(.top, max(CaptureTokens.topBarTop, GuidedCaptureView<EmptyView>.windowInsets.top))

                VStack(spacing: 10) {
                    Text("Checking it's you")
                        .font(.usBody(18, .semibold))
                        .foregroundColor(CaptureTokens.ink)
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: bar.stage == .done || bar.fixed != nil)) { tl in
                        let progress = min(1, max(UploadBar.floor, bar.value(at: tl.date)))
                        GeometryReader { track in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule().fill(colors.ring.color)
                                    .frame(width: track.size.width * CGFloat(progress))
                            }
                        }
                        .frame(height: 4)
                        .accessibilityElement()
                        .accessibilityLabel("Checking it's you")
                        .accessibilityValue("\(Int(progress * 10) * 10) percent")
                    }
                    Text(CaptureTokens.uploadCopy)
                        .font(.usBody(13))
                        .foregroundColor(CaptureTokens.ink2)
                }
                .padding(22)
                .frame(width: geo.size.width - 16)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(CaptureTokens.panel))
                .accessibilityIdentifier("usesense.capture.upload")
                .frame(width: geo.size.width, height: geo.size.height - 8, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}
#endif
