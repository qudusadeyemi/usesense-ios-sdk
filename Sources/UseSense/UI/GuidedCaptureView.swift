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

// MARK: - Tokens (from the capture proposal mockups, scaled ~1.6x to a phone)

enum CaptureTokens {
    /// Camera-surface ink and panels (#0d0f14 family).
    static let cam = Color(red: 13 / 255, green: 15 / 255, blue: 20 / 255)
    static let panel = Color(red: 29 / 255, green: 32 / 255, blue: 41 / 255)   // #1d2029
    static let ink = Color(red: 244 / 255, green: 245 / 255, blue: 248 / 255)  // #f4f5f8
    static let ink2 = Color(red: 163 / 255, green: 169 / 255, blue: 184 / 255) // #a3a9b8
    static let warmLight = Color(red: 1, green: 250 / 255, blue: 240 / 255)    // #fffaf0
    /// Hint card vertical anchor: its bottom sits 26% up from the screen bottom.
    static let hintBottomFraction: CGFloat = 0.26
    /// Contour lines run from the top to 78% of the screen height.
    static let contourBottomFraction: CGFloat = 0.78
}

// MARK: - Align + scan screen

/// Screens 2-6 of the capture redesign: align (one hint at a time, auto
/// start), low light (fill light), scan (full-screen contour lines + a ring
/// that pauses), shutter fallback.
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
    private var paused: Bool { mode == .scan && viewModel.scan.paused }
    private var fillLight: Bool { viewModel.guide.snapshot.fillLight }
    private var showShutter: Bool { mode == .align && viewModel.guide.shutterAvailable }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let oval = CaptureOvalLayout.ovalRect(in: size)
            let insets = Self.windowInsets
            ZStack {
                camera

                // Align: the feed stays visible, with a soft vignette so the
                // chrome reads. Scan: the feed sinks under a dark wash so the
                // contour lines carry the screen.
                RadialGradient(colors: [.clear, CaptureTokens.cam.opacity(0.55)],
                               center: UnitPoint(x: 0.5, y: 0.4),
                               startRadius: oval.width * 0.55, endRadius: size.height * 0.75)
                    .allowsHitTesting(false)
                if mode == .scan {
                    CaptureTokens.cam.opacity(paused ? 0.55 : 0.74)
                        .animation(.easeInOut(duration: 0.25), value: paused)
                        .allowsHitTesting(false)
                    ContourScanView(field: viewModel.contourField, colors: colors,
                                    startedAt: scanStartedAt, dimmed: paused, fixedDate: fixedDate)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                ovalAndRing(oval)

                if fillLight { FillLightBorder().allowsHitTesting(false) }

                // Hint card: bottom edge 26% up from the screen bottom.
                VStack {
                    Spacer()
                    hintCard.padding(.horizontal, 24)
                    Spacer().frame(height: size.height * CaptureTokens.hintBottomFraction)
                }

                VStack(spacing: 14) {
                    Spacer()
                    if USTrace.enabled { debugChips }
                    if showShutter { shutterButton }
                }
                .padding(.bottom, insets.bottom + CaptureFooter.clearance + 10)

                VStack {
                    HStack {
                        closeButton
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    // Status bar is hidden here: sit beside the Dynamic Island.
                    .padding(.top, max(16, insets.top - 36))
                    Spacer()
                }
            }
            .animation(.easeInOut(duration: 0.3), value: fillLight)
            .animation(.easeInOut(duration: 0.3), value: showShutter)
            .onAppear {
                viewModel.setViewport(size)
                if fixedDate == nil { scanStartedAt = Date() }
                pulse = true
            }
            .onChange(of: size) { viewModel.setViewport($0) }
        }
        .ignoresSafeArea()
    }

    /// The window's safe-area insets (the GeometryReader ignores the safe
    /// area, so its own insets read zero).
    static var windowInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
    }

    // MARK: Oval + ring

    private func ovalAndRing(_ oval: CGRect) -> some View {
        let failing = hint != nil && (mode == .align || paused)
        return ZStack {
            if mode == .align {
                TopStartEllipse()
                    .stroke(failing ? colors.warning.color : Color.white.opacity(0.92), lineWidth: 2.5)
                    .opacity(failing && pulse ? 0.55 : 1)
                    .animation(failing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                               value: pulse)
            } else {
                TopStartEllipse().stroke(Color.white.opacity(0.18), lineWidth: 4)
                TopStartEllipse()
                    .trim(from: 0, to: viewModel.scan.fraction)
                    .stroke(paused ? colors.warning.color : colors.ring.color,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .shadow(color: (paused ? colors.warning : colors.ring).color.opacity(0.6), radius: 6)
                    .animation(.linear(duration: 0.1), value: viewModel.scan.fraction)
            }
        }
        .frame(width: oval.width, height: oval.height)
        .position(x: oval.midX, y: oval.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Hint card

    private struct CardContent: Equatable {
        var title: String
        var subtitle: String?
        var symbol: String
        var warning: Bool
    }

    private var card: CardContent? {
        // Fallback screen: the shutter's own card (mockup screen 6).
        if showShutter {
            return CardContent(title: "Tap the shutter when you're ready",
                               subtitle: "We'll still scan for \(viewModel.scanSecondsForCopy) seconds",
                               symbol: "camera.aperture", warning: false)
        }
        if let hint, mode == .align || paused || hint.check == .light {
            return CardContent(title: hint.title, subtitle: hint.subtitle, symbol: Self.symbol(hint.icon),
                               warning: hint.check == .light || hint.check == .onePerson)
        }
        if mode == .scan {
            let total = max(1, Int(viewModel.scan.totalSeconds.rounded()))
            let done = min(total, Int(viewModel.scan.bankedSeconds.rounded(.down)))
            return CardContent(title: GateHint.holdStill.title, subtitle: "Scanning · \(done) of \(total) s",
                               symbol: "scope", warning: false)
        }
        return nil
    }

    private var hintCard: some View {
        let content = card
        return ZStack {
            if let content {
                HStack(spacing: 12) {
                    Image(systemName: content.symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(content.warning ? Color(red: 28 / 255, green: 26 / 255, blue: 23 / 255) : CaptureTokens.ink)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(content.warning ? colors.warning.color : Color.white.opacity(0.12))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(content.title)
                            .font(.usBody(16, .semibold))
                            .foregroundColor(CaptureTokens.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let sub = content.subtitle {
                            Text(sub)
                                .font(.usBody(13))
                                .foregroundColor(CaptureTokens.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 11)
                .padding(.leading, 12)
                .padding(.trailing, 18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(CaptureTokens.cam.opacity(0.82))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1))
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("usesense.capture.hint")
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .id(content.title)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: content)
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

    // MARK: Shutter, chips, close

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

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(CaptureTokens.ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(CaptureTokens.cam.opacity(0.45)))
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
        .accessibilityLabel("Close")
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
        RoundedRectangle(cornerRadius: 46, style: .continuous)
            .strokeBorder(CaptureTokens.warmLight, lineWidth: 34)
            .overlay(
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .inset(by: 34)
                    .stroke(CaptureTokens.warmLight.opacity(0.6), lineWidth: 18)
                    .blur(radius: 18)
            )
            .ignoresSafeArea()
            .transition(.opacity)
            .accessibilityHidden(true)
    }
}

// MARK: - Contour scan

/// Thin horizontal lines across the whole screen, flat away from the face and
/// lifted by the smoothed mesh depth over it (the proposal's scan mockup:
/// 6.5 pt apart, 1.1 pt wide, down to 78% of the height). Lines sweep in from
/// the top when the scan starts and follow the head as it moves. Drawn with
/// Canvas (Core Graphics); ~100 lines x 130 points at 30 fps.
struct ContourScanView: View {
    let field: ContourDepthField
    let colors: CaptureColors
    let startedAt: Date
    var dimmed: Bool
    /// Draw one frame at this time instead of animating (snapshots).
    var fixedDate: Date? = nil

    static let spacing: CGFloat = 6.5
    static let sampleStep: CGFloat = 3
    static let sweepSeconds = 0.9
    /// Lift at the nose tip, as a share of the face box height.
    static let lift: CGFloat = 0.30

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
            let snap = field.snapshot()
            let bottom = size.height * CaptureTokens.contourBottomFraction
            let reveal = CGFloat(min(1, date.timeIntervalSince(startedAt) / Self.sweepSeconds))
            let amp = max(snap.rect.height, 1) * Self.lift
            var y = Self.spacing
            while y < bottom {
                guard y <= bottom * reveal else { break }
                var path = Path()
                var maxH: Float = 0
                var x: CGFloat = 0
                while x <= size.width + Self.sampleStep {
                    let s = snap.sample(CGPoint(x: x, y: y))
                    let h = s.depth
                    maxH = max(maxH, h)
                    let pt = CGPoint(x: x, y: y - CGFloat(h) * amp)
                    if x == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    x += Self.sampleStep
                }
                let k = Double(min(1, maxH * 1.6))
                let c = colors.contourStart.mix(colors.contourEnd, k)
                let alpha = (0.35 + 0.55 * k) * (dimmed ? 0.45 : 1)
                g.stroke(path, with: .color(c.color.opacity(alpha)), lineWidth: 1.1)
                y += Self.spacing
            }
            if reveal < 1 {
                let beamY = bottom * reveal
                g.fill(Path(CGRect(x: 0, y: beamY - 1, width: size.width, height: 2)),
                       with: .color(colors.contourEnd.color.opacity(0.9)))
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
            ZStack {
                CaptureTokens.cam
                if let backdrop {
                    Image(uiImage: backdrop)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(x: -1, y: 1)
                        .blur(radius: 30, opaque: true)
                        .overlay(CaptureTokens.cam.opacity(0.35))
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Checking it's you")
                    .font(.usDisplay(22, .bold))
                    .foregroundColor(CaptureTokens.ink)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(colors.ring.color)
                            .frame(width: geo.size.width * CGFloat(min(1, max(0.04, progress))))
                            .animation(.easeOut(duration: 3), value: progress)
                    }
                }
                .frame(height: 6)
                .padding(.top, 6)
                .accessibilityElement()
                .accessibilityLabel("Checking it's you")
                .accessibilityValue("\(Int(progress * 100)) percent")
                Text("Usually 3–5 seconds")
                    .font(.usBody(14))
                    .foregroundColor(CaptureTokens.ink2)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(CaptureTokens.panel))
            .padding(.horizontal, 12)
            .padding(.bottom, CaptureFooter.clearance)
            .accessibilityIdentifier("usesense.capture.upload")
        }
    }
}
#endif
