#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit

// MARK: - Tokens (storyboard "End-user storyboard", Phone screens table)

enum ExtraCheckTokens {
    /// Purple ring = extra check.
    static let ring = Color(red: 168 / 255, green: 120 / 255, blue: 252 / 255)        // #A878FC
    static let iconFill = Color(red: 168 / 255, green: 120 / 255, blue: 252 / 255).opacity(0.18)
    static let iconInk = Color(red: 195 / 255, green: 166 / 255, blue: 255 / 255)     // #C3A6FF
    static let done = Color(red: 0, green: 212 / 255, blue: 170 / 255)                // #00D4AA
    static let failure = Color(red: 1, green: 107 / 255, blue: 74 / 255)              // #FF6B4A
    static let dot = Color(red: 1, green: 184 / 255, blue: 77 / 255)                  // #FFB84D
    static let tipDot = Color(red: 122 / 255, green: 150 / 255, blue: 1)              // #7A96FF
    static let page = Color(red: 18 / 255, green: 20 / 255, blue: 27 / 255)           // #12141b
    static let meterBars = 9
}

extension GuidedScreen.Tone {
    var ink: Color {
        switch self {
        case .brand: return ExtraCheckTokens.tipDot
        case .warning: return CaptureColors.current.warning.color
        case .success: return ExtraCheckTokens.done
        case .failure: return ExtraCheckTokens.failure
        }
    }
    var fill: Color {
        switch self {
        case .brand: return Color(red: 79 / 255, green: 124 / 255, blue: 1).opacity(0.16)
        default: return ink.opacity(0.16)
        }
    }
}

// MARK: - Shared guidance text (same type as the scan screen)

struct CaptureGuidanceText: View {
    let title: String
    let subtitle: String?

    var body: some View {
        let key = title + (subtitle ?? "")
        ZStack(alignment: .top) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.usBody(22, .semibold))
                    .tracking(-0.22)
                if let subtitle {
                    Text(subtitle)
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
}

// MARK: - The challenge on the scan screen

/// Head Turn, Follow Dot or Speak Digits drawn on the scan screen: full-bleed
/// camera, the oval ring in purple (amber while paused, green when done) and
/// one instruction under it.
struct GuidedChallengeView<Camera: View>: View {
    let camera: Camera
    let display: ChallengeDisplay
    /// Speak Digits meter bars, oldest first, 0...1.
    var meter: [Double] = []
    /// The short green tick after the check.
    var done = false
    let onBack: () -> Void

    @State private var showHelp = false

    private var ringColor: Color {
        if done { return ExtraCheckTokens.done }
        return display.tone == .warning ? CaptureColors.current.warning.color : ExtraCheckTokens.ring
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let oval = CaptureOvalLayout.ovalRect(in: size)
            let insets = GuidedCaptureView<EmptyView>.windowInsets
            let title = done ? ExtraCheckCopy.done : display.title
            let subtitle = done ? nil : display.subtitle
            ZStack(alignment: .topLeading) {
                camera.frame(width: size.width, height: size.height)
                CaptureTokens.cam.opacity(CaptureTokens.feedDimDuringScan)
                    .allowsHitTesting(false)

                ring(oval)

                if !done, display.kind == .followDot, let dot = display.dot {
                    dotLayer(dot: dot, trail: display.trail, size: size)
                }
                if !done, let arrow = display.arrow {
                    ArrowGlyph(direction: arrow)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
                if done { tick.position(x: oval.midX, y: oval.midY) }

                if !done, display.kind == .digits, let digits = display.digits {
                    Text(digits)
                        .font(.usMono(34, medium: true))
                        .tracking(34 * 0.32)
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(CaptureTokens.cam.opacity(0.72)))
                        .frame(width: size.width)
                        .padding(.top, max(96, insets.top + 42))
                        .accessibilityLabel("Say these numbers: \(digits)")
                        .accessibilityIdentifier("usesense.challenge.digits")
                    MeterBars(levels: meter)
                        .frame(width: size.width, height: 34)
                        .offset(y: oval.maxY + 116)
                        .accessibilityHidden(true)
                }

                CaptureGuidanceText(title: title, subtitle: subtitle)
                    .frame(width: size.width - 48)
                    .offset(x: 24, y: oval.maxY + CaptureTokens.hintGapBelowOval)

                CaptureTopBar(onBack: onBack, onHelp: { showHelp = true })
                    .padding(.horizontal, 16)
                    .frame(width: size.width)
                    .padding(.top, max(CaptureTokens.topBarTop, insets.top))
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 0.2), value: display.arrow)
            .animation(.easeInOut(duration: 0.2), value: done)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("usesense.challenge")
        .alert("Quick extra check", isPresented: $showHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(helpText)
        }
    }

    private var helpText: String {
        switch display.kind {
        case .headTurn: return "Keep your face in the oval and turn your head slowly the way the arrow points."
        case .followDot: return "Keep your face in the oval and move your head to follow the dot. The dot waits if your face leaves the oval."
        case .digits: return "Keep your face in the oval and say the numbers out loud in a normal voice."
        }
    }

    private func ring(_ oval: CGRect) -> some View {
        let g = CaptureTokens.ringGap
        return ZStack {
            TopStartEllipse()
                .stroke(Color.white.opacity(CaptureTokens.ringTrack), lineWidth: CaptureTokens.ringWidth)
            TopStartEllipse()
                .trim(from: 0, to: done ? 1 : display.progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: CaptureTokens.ringWidth, lineCap: .round))
                .animation(.linear(duration: 0.1), value: display.progress)
                .animation(.easeInOut(duration: 0.2), value: display.tone)
        }
        .frame(width: oval.width + 2 * g, height: oval.height + 2 * g)
        .position(x: oval.midX, y: oval.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func dotLayer(dot: CGPoint, trail: [CGPoint], size: CGSize) -> some View {
        let p = { (q: CGPoint) in CGPoint(x: q.x * size.width, y: q.y * size.height) }
        return ZStack {
            Path { path in
                guard let first = trail.first else { return }
                path.move(to: p(first))
                for q in trail.dropFirst() { path.addLine(to: p(q)) }
            }
            .stroke(ExtraCheckTokens.dot.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 6]))
            Circle()
                .stroke(ExtraCheckTokens.dot.opacity(0.5), lineWidth: 2)
                .frame(width: 44, height: 44)
                .position(p(dot))
            Circle()
                .fill(ExtraCheckTokens.dot)
                .frame(width: 24, height: 24)
                .position(p(dot))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var tick: some View {
        ZStack {
            Circle().fill(ExtraCheckTokens.done.opacity(0.9)).frame(width: 88, height: 88)
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .accessibilityHidden(true)
    }
}

/// A side arrow (left/right at the screen edge, up/down beside the oval),
/// drawn as in the storyboard: a 46 pt shaft with a 22 pt head.
struct ArrowGlyph: Shape {
    let direction: HeadDirection

    func path(in rect: CGRect) -> Path {
        let oval = CaptureOvalLayout.ovalRect(in: rect.size)
        var p = Path()
        func arrow(tip: CGPoint, back: CGVector) {
            let len: CGFloat = 46, head: CGFloat = 22
            let n = CGVector(dx: -back.dy, dy: back.dx)
            p.move(to: tip)
            p.addLine(to: CGPoint(x: tip.x + back.dx * len, y: tip.y + back.dy * len))
            p.move(to: CGPoint(x: tip.x + back.dx * head + n.dx * head * 1.1, y: tip.y + back.dy * head + n.dy * head * 1.1))
            p.addLine(to: tip)
            p.addLine(to: CGPoint(x: tip.x + back.dx * head - n.dx * head * 1.1, y: tip.y + back.dy * head - n.dy * head * 1.1))
        }
        switch direction {
        case .left: arrow(tip: CGPoint(x: rect.minX + 40, y: oval.midY), back: CGVector(dx: 1, dy: 0))
        case .right: arrow(tip: CGPoint(x: rect.maxX - 40, y: oval.midY), back: CGVector(dx: -1, dy: 0))
        case .up: arrow(tip: CGPoint(x: oval.midX, y: oval.minY - 66), back: CGVector(dx: 0, dy: 1))
        case .down: arrow(tip: CGPoint(x: oval.midX, y: oval.maxY - 24), back: CGVector(dx: 0, dy: -1))
        case .center: break
        }
        return p
    }
}

/// Nine live level bars (Speak Digits).
struct MeterBars: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<ExtraCheckTokens.meterBars, id: \.self) { i in
                let level = i < levels.count ? levels[i] : 0
                RoundedRectangle(cornerRadius: 3)
                    .fill(ExtraCheckTokens.done)
                    .frame(width: 6, height: 4 + 30 * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

// MARK: - Sheets over the blurred scan

/// The last scan frame, blurred (14 pt) and dimmed: the backdrop of every
/// sheet, as the upload sheet.
struct BlurredCaptureBackdrop: View {
    let image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ZStack {
                    CaptureTokens.cam
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(x: -1, y: 1)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    CaptureTokens.cam.opacity(CaptureTokens.feedDimDuringScan)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .drawingGroup(opaque: true)
                .blur(radius: 14, opaque: true)
                CaptureTokens.cam.opacity(0.25)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Bottom sheet: inset 8, radius 28, #1D2029 (the upload sheet's styling).
struct GuidedSheet: View {
    var icon: String?
    var iconFill: Color = ExtraCheckTokens.iconFill
    var iconInk: Color = ExtraCheckTokens.iconInk
    let title: String
    var message: String?
    var primary: String?
    var busy = false
    var onPrimary: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(iconInk)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(iconFill))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.usBody(20, .semibold))
                .foregroundColor(CaptureTokens.ink)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.usBody(15))
                    .lineSpacing(4)
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let primary {
                PrimaryCaptureButton(title: primary, height: 54, busy: busy, action: onPrimary)
                    .padding(.top, 6)
            }
        }
        .padding(.top, 26)
        .padding([.horizontal, .bottom], 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(CaptureTokens.panel))
        .padding(8)
        .padding(.bottom, max(0, GuidedCaptureView<EmptyView>.windowInsets.bottom - 8))
    }
}

/// Blurred scan + a sheet, with the back button on top.
struct GuidedSheetScreen<Sheet: View>: View {
    let backdrop: UIImage?
    let onBack: () -> Void
    @ViewBuilder let sheet: () -> Sheet

    var body: some View {
        ZStack(alignment: .bottom) {
            BlurredCaptureBackdrop(image: backdrop)
            VStack {
                CaptureTopBar(onBack: onBack)
                    .padding(.horizontal, 16)
                    .padding(.top, max(CaptureTokens.topBarTop, GuidedCaptureView<EmptyView>.windowInsets.top))
                Spacer()
            }
            sheet()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .ignoresSafeArea()
    }
}

struct PrimaryCaptureButton: View {
    let title: String
    var height: CGFloat = 56
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(USColors.primaryForeground) }
            }
            .font(.usBody(17, .semibold))
            .foregroundColor(USColors.primaryForeground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(USColors.primary))
        }
        .disabled(busy)
    }
}

// MARK: - Full pages (primer, results, errors)

struct GuidedPageView: View {
    let content: GuidedScreen.Content
    let onPrimary: () -> Void
    var onSecondary: (() -> Void)?
    /// Back/close in the top bar (nil hides it).
    var onClose: (() -> Void)?
    var busySecondary = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ExtraCheckTokens.page.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: content.icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(content.tone.ink)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(content.tone.fill))
                    .accessibilityHidden(true)
                Text(content.title)
                    .font(.usBody(28, .semibold).weight(.bold))
                    .tracking(-0.28)
                    .foregroundColor(CaptureTokens.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("usesense.page.title")
                Text(content.body)
                    .font(.usBody(16))
                    .lineSpacing(5)
                    .foregroundColor(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("usesense.page.body")
                if !content.tips.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(content.tips, id: \.self) { tip in
                            HStack(spacing: 12) {
                                Circle().fill(ExtraCheckTokens.tipDot).frame(width: 8, height: 8)
                                Text(tip)
                                    .font(.usBody(15))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                PrimaryCaptureButton(title: content.primary, action: onPrimary)
                    .accessibilityIdentifier("usesense.page.primary")
                if let secondary = content.secondary, let onSecondary {
                    Button(action: onSecondary) {
                        ZStack {
                            Text(secondary).opacity(busySecondary ? 0 : 1)
                            if busySecondary { ProgressView().tint(.white) }
                        }
                        .font(.usBody(15, .semibold))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .disabled(busySecondary)
                    .accessibilityIdentifier("usesense.page.secondary")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 120)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(edges: .top)

            if let onClose {
                CaptureTopBar(onBack: onClose)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Leave dialog

struct LeaveVerificationDialog: View {
    let onLeave: () -> Void
    let onStay: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Leave verification?")
                    .font(.usBody(17, .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("You're nearly done. If you leave, you'll need to start again.")
                    .font(.usBody(14))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .opacity(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: onLeave) {
                        Text("Leave")
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.18)))
                    }
                    .accessibilityIdentifier("usesense.leave.confirm")
                    Button(action: onStay) {
                        Text("Keep going")
                            .foregroundColor(USColors.primaryForeground)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(USColors.primary))
                    }
                    .accessibilityIdentifier("usesense.leave.stay")
                }
                .font(.usBody(15, .semibold))
                .padding(.top, 6)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .frame(width: 290)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(CaptureTokens.panel))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity)
    }
}
#endif

enum ExtraCheckIcons {
    static func symbol(_ type: ChallengeType) -> String {
        switch type {
        case .headTurn: return "arrow.left.and.right"
        case .followDot: return "scope"
        case .speakPhrase: return "mic"
        }
    }
}
