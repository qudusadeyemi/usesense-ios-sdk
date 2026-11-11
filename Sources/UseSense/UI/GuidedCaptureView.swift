#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit

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

// MARK: - Copy (BRAND-v1 copy.capture; defaults = capture test kit SPEC v1.1)

enum CaptureCopyText {
    static var shutter: String { CaptureText.text(\.capture?.guidance?.shutterHint, "Tap the button when you're ready") }
    static var ready: String { CaptureText.text(\.capture?.guidance?.ready, "Hold still") }
    static var helpTitle: String { CaptureText.text(\.capture?.guidance?.helpTitle, "Quick face scan") }
    static var helpBody: String {
        CaptureText.text(\.capture?.guidance?.helpBody,
                         "Look straight at the screen with a neutral face. Face the light; your screen will brighten to help. The scan starts by itself when your face is in the oval and still.")
    }
    static var uploadTitle: String { CaptureText.text(\.capture?.upload?.title, "Checking it's you") }
    static var uploadCaption: String { CaptureText.text(\.capture?.upload?.caption, "Usually under 10 seconds") }
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
    @SwiftUI.Environment(\.captureTheme) private var theme
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

    private var colors: CaptureColors { theme.camera }
    private var hint: GateHint? { viewModel.guide.snapshot.hint }
    private var paused: Bool { mode == .scan && viewModel.scan.paused }
    private var fillLight: Bool { viewModel.guide.snapshot.fillLight }
    private var showShutter: Bool { mode == .align && viewModel.guide.shutterAvailable }

    /// The instruction shown, and whether it asks for an action.
    private var guidance: (title: String, subtitle: String?, action: Bool) {
        Self.guidance(hint: hint, mode: mode, paused: paused, showShutter: showShutter,
                      needsCloser: mode == .scan && viewModel.closer.needsCloser)
    }

    /// The shutter's "Tap the button when you're ready" never hides a check
    /// that holds the scan (a covered face, a second person, distance...):
    /// the tap starts a scan with the same quality bar, so the person still
    /// needs to know what to fix. Seen on device: a hand over the mouth for
    /// 20 s showed only the shutter copy.
    /// `needsCloser`: the EVIDENCE-v1 closer step is waiting for the face to
    /// follow the grown oval (existing copy, "Move a little closer").
    static func guidance(hint: GateHint?, mode: Mode, paused: Bool, showShutter: Bool, needsCloser: Bool = false)
        -> (title: String, subtitle: String?, action: Bool) {
        if showShutter {
            if let hint, hint.check != .stillness, hint.check != .light {
                return (hint.title, hint.subtitle, true)
            }
            return (CaptureCopyText.shutter, nil, true)
        }
        if let hint, mode == .align || paused || hint.check == .light {
            return (hint.title, hint.subtitle, hint.check != .stillness)
        }
        if needsCloser { return (GateHint.moveCloser.title, nil, true) }
        return (CaptureCopyText.ready, nil, false)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let oval = CaptureOvalLayout.ovalRect(in: size, scale: mode == .scan ? viewModel.closer.scale : 1)
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

                // EVIDENCE-v1 colour sequence: the server's colour over the
                // whole screen, under the ring and guidance. It replaces the
                // fill light veil while it shows, so the colour stays pure.
                if mode == .scan, let tint = viewModel.tint {
                    tint.color.opacity(tint.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if fillLight {
                    // Fill light: a warm veil over the whole screen, under the
                    // guide (as Android). A border made the camera look inset.
                    FillLightVeil().allowsHitTesting(false)
                }

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
                    .frame(width: size.width, height: size.height - insets.bottom - CaptureFooter.clearance)
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
            .animation(.easeInOut(duration: 0.5), value: viewModel.closer.scale)
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
        .overlay {
            if showHelp {
                CaptureHelpDialog(title: CaptureCopyText.helpTitle, message: CaptureCopyText.helpBody) { showHelp = false }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showHelp)
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
                    .fill(CaptureTokens.guideInk.opacity(CaptureTokens.guideFill))
                    .frame(width: oval.width, height: oval.height)
                Ellipse()
                    .stroke(guidance.action ? colors.warning.color : CaptureTokens.guideInk.opacity(CaptureTokens.guideStroke),
                            lineWidth: CaptureTokens.guideWidth)
                    .frame(width: oval.width, height: oval.height)
                    .animation(.easeInOut(duration: 0.2), value: guidance.action)
            } else {
                let g = CaptureTokens.ringGap
                ZStack {
                    TopStartEllipse()
                        .stroke(CaptureTokens.guideInk.opacity(CaptureTokens.ringTrack), lineWidth: CaptureTokens.ringWidth)
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
        CaptureGuidanceText(title: guidance.title, subtitle: guidance.subtitle)
    }

    // MARK: Shutter, chips

    private var shutterButton: some View {
        Button(action: { viewModel.shutterTapped() }) {
            Circle()
                .fill(CaptureTokens.shutter)
                .frame(width: 72, height: 72)
                .overlay(Circle().stroke(CaptureTokens.shutter.opacity(0.25), lineWidth: 6).padding(-6))
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
                    .foregroundColor(bad ? CaptureTokens.debugBadInk : CaptureTokens.debugGoodInk)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(Capsule().fill(bad ? CaptureTokens.debugBadFill : CaptureTokens.debugGoodFill))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Back (left) and help (right): 32 pt circles, 16 pt from the sides.
/// On the camera: fixed light glyph on the dimmed camera. On a page: the
/// page's foreground on its surface.
struct CaptureTopBar: View {
    let onBack: () -> Void
    var onHelp: (() -> Void)?
    var onPage = false
    @SwiftUI.Environment(\.captureTheme) private var theme

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
                .foregroundColor(onPage ? theme.foreground : CaptureTokens.chromeInk)
                .frame(width: 32, height: 32)
                .background(Circle().fill(onPage ? theme.surface : CaptureTokens.cam.opacity(CaptureTokens.chromeFillOpacity)))
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

    @SwiftUI.Environment(\.captureTheme) private var theme
    private var colors: CaptureColors { theme.camera }

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
                    Text(CaptureCopyText.uploadTitle)
                        .font(.usDisplay(18, .bold))
                        .foregroundColor(theme.foreground)
                        .accessibilityAddTraits(.isHeader)
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: bar.stage == .done || bar.fixed != nil)) { tl in
                        let progress = min(1, max(UploadBar.floor, bar.value(at: tl.date)))
                        GeometryReader { track in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.border)
                                Capsule().fill(colors.ring.color)
                                    .frame(width: track.size.width * CGFloat(progress))
                            }
                        }
                        .frame(height: 4)
                        .accessibilityElement()
                        .accessibilityLabel(CaptureCopyText.uploadTitle)
                        .accessibilityValue("\(Int(progress * 10) * 10) percent")
                    }
                    Text(CaptureCopyText.uploadCaption)
                        .font(.usBody(13))
                        .foregroundColor(theme.muted)
                    CapturePoweredBy(onCamera: false)
                        .padding(.bottom, -12)
                }
                .padding(22)
                .frame(width: geo.size.width - 16)
                .background(RoundedRectangle(cornerRadius: theme.sheetRadius, style: .continuous).fill(theme.surface))
                .accessibilityIdentifier("usesense.capture.upload")
                .frame(width: geo.size.width, height: geo.size.height - 8, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}
#endif
