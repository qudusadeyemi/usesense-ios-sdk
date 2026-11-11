#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit

// Colours: `CaptureTheme` (environment) or the fixed `CaptureTokens` only.
// No literal colours in this file (CaptureBrandGuardTests).

enum ExtraCheckTokens {
    static let meterBars = 9
}

extension GuidedScreen.Tone {
    /// Glyph colour on a page; the tile is this colour at 16%.
    func ink(_ theme: CaptureTheme) -> Color {
        switch self {
        case .brand: return theme.primaryColor
        case .warning: return theme.warning.color
        case .success: return theme.success.color
        case .failure: return theme.error.color
        }
    }
    func fill(_ theme: CaptureTheme) -> Color { ink(theme).opacity(CaptureTokens.tileOpacity) }
}

// MARK: - Inline step-up on the scan screen

/// The suspicion engine's own check (RMAS micro-actions, Flash Reflection),
/// drawn like the extra check: plain guidance under the oval and an amber
/// ring while it waits for the person. A flash fills the screen with its
/// colour so the face can reflect it (fixed: the server's colours).
struct GuidedInlineStepUpView<Camera: View>: View {
    let camera: Camera
    let display: InlineStepUpDisplay
    let onBack: () -> Void

    var body: some View {
        ZStack {
            GuidedChallengeView(
                camera: camera,
                display: ChallengeDisplay(kind: .headTurn, progress: display.progress, tone: .warning,
                                          title: display.title, subtitle: display.subtitle),
                help: ExtraCheckCopy.helpInline,
                onBack: onBack)
            if let flash = CaptureColors.RGB(css: display.flashColor) {
                flash.color
                    .opacity(0.6)
                    .blendMode(.screen)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("usesense.inline.stepup")
    }
}

// MARK: - Shared guidance text (same type as the scan screen)

/// Guidance on the camera: fixed white with a shadow, in the brand body font.
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
                        .foregroundColor(CaptureTokens.guidanceInk.opacity(CaptureTokens.guidanceSubOpacity))
                }
            }
            .foregroundColor(CaptureTokens.guidanceInk)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .shadow(color: CaptureTokens.guidanceShadow.opacity(0.35), radius: 1, y: 1)
            .shadow(color: CaptureTokens.guidanceShadow.opacity(0.45), radius: 7, y: 2)
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
/// camera, the oval ring in the challenge colour (warning while paused,
/// success when done) and one instruction under it.
struct GuidedChallengeView<Camera: View>: View {
    let camera: Camera
    let display: ChallengeDisplay
    /// Speak Digits meter bars, oldest first, 0...1.
    var meter: [Double] = []
    /// The short tick after the check.
    var done = false
    /// Help text, when not the challenge's own.
    var help: String?
    let onBack: () -> Void

    @State private var showHelp = false
    @SwiftUI.Environment(\.captureTheme) private var theme

    private var ringColor: Color {
        if done { return theme.camera.success.color }
        return display.tone == .warning ? theme.camera.warning.color : theme.camera.challenge.color
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
                        .stroke(CaptureTokens.arrowInk, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
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
                        .foregroundColor(CaptureTokens.digitsInk)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(CaptureTokens.cam.opacity(CaptureTokens.digitsPillOpacity)))
                        .frame(width: size.width)
                        .padding(.top, max(96, insets.top + 42))
                        .accessibilityLabel("Say these numbers: \(digits)")
                        .accessibilityIdentifier("usesense.challenge.digits")
                    MeterBars(levels: meter, color: theme.camera.success.color)
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
        .overlay {
            if showHelp {
                CaptureHelpDialog(title: ExtraCheckCopy.helpTitle, message: helpText) { showHelp = false }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showHelp)
    }

    private var helpText: String {
        if let help { return help }
        switch display.kind {
        case .headTurn: return ExtraCheckCopy.helpHeadTurn
        case .followDot: return ExtraCheckCopy.helpFollowDot
        case .digits: return ExtraCheckCopy.helpSpeakDigits
        }
    }

    private func ring(_ oval: CGRect) -> some View {
        let g = CaptureTokens.ringGap
        return ZStack {
            TopStartEllipse()
                .stroke(CaptureTokens.guideInk.opacity(CaptureTokens.ringTrack), lineWidth: CaptureTokens.ringWidth)
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
        let ink = theme.camera.warning.color
        return ZStack {
            Path { path in
                guard let first = trail.first else { return }
                path.move(to: p(first))
                for q in trail.dropFirst() { path.addLine(to: p(q)) }
            }
            .stroke(ink.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 6]))
            Circle()
                .stroke(ink.opacity(0.5), lineWidth: 2)
                .frame(width: 44, height: 44)
                .position(p(dot))
            Circle()
                .fill(ink)
                .frame(width: 24, height: 24)
                .position(p(dot))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var tick: some View {
        ZStack {
            Circle().fill(theme.camera.success.color.opacity(0.9)).frame(width: 88, height: 88)
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(CaptureTokens.tickInk)
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
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<ExtraCheckTokens.meterBars, id: \.self) { i in
                let level = i < levels.count ? levels[i] : 0
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
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

/// Which colour an icon tile takes.
enum CaptureIconTone {
    case challenge, tone(GuidedScreen.Tone)

    func ink(_ theme: CaptureTheme) -> Color {
        switch self {
        case .challenge: return theme.camera.challenge.color
        case .tone(let t): return t.ink(theme)
        }
    }
}

/// Bottom sheet: inset 8, the page surface, top radius from the brand.
struct GuidedSheet: View {
    var icon: String?
    var iconTone: CaptureIconTone = .challenge
    let title: String
    var message: String?
    var primary: String?
    var busy = false
    var onPrimary: () -> Void = {}

    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let icon {
                let ink = iconTone.ink(theme)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(ink)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: theme.tileRadius, style: .continuous)
                        .fill(ink.opacity(CaptureTokens.tileOpacity)))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.usDisplay(20, .bold))
                .foregroundColor(theme.foreground)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.usBody(15))
                    .lineSpacing(4)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let primary {
                PrimaryCaptureButton(title: primary, height: 54, busy: busy, action: onPrimary)
                    .padding(.top, 6)
            }
            CapturePoweredBy(onCamera: false)
                .padding(.bottom, -12)
        }
        .padding(.top, 26)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.sheetRadius, style: .continuous).fill(theme.surface))
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

/// Primary capture button: brand primary, filled or outline, brand radius.
struct PrimaryCaptureButton: View {
    let title: String
    var height: CGFloat = 56
    var busy = false
    let action: () -> Void

    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        let ink = theme.buttonOutlined ? theme.primaryColor : theme.onPrimary
        let shape = RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(ink) }
            }
            .font(.usBody(17, .semibold))
            .foregroundColor(ink)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(shape.fill(theme.buttonOutlined ? Color.clear : theme.primaryColor))
            .overlay(shape.stroke(theme.buttonOutlined ? theme.primaryColor : Color.clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .disabled(busy)
    }
}

/// Secondary capture button: muted text, no fill, brand radius.
struct SecondaryCaptureButton: View {
    let title: String
    var height: CGFloat = 48
    var busy = false
    let action: () -> Void

    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(theme.muted) }
            }
            .font(.usBody(15, .semibold))
            .foregroundColor(theme.muted)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous))
        }
        .disabled(busy)
    }
}

// MARK: - Page chrome: background, logo header, footer

/// The page background: colour, then the brand image (cover) when set.
struct CapturePageBackground: View {
    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        ZStack {
            theme.background
            if let url = theme.backgroundImageURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    theme.background
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The brand lockup on page-surface screens: the logo, or the display name
/// as text when there is no logo. Placement `none` hides it.
struct CaptureLogoHeader: View {
    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        if theme.logoPlacement != .none, theme.logoURL != nil || theme.displayName != nil {
            HStack {
                if theme.logoPlacement == .center { Spacer(minLength: 0) }
                lockup
                Spacer(minLength: 0)
            }
            .frame(height: max(theme.logoHeight, 28))
            .accessibilityIdentifier("usesense.page.logo")
        }
    }

    @ViewBuilder private var lockup: some View {
        if let url = theme.logoURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(maxWidth: 200, maxHeight: theme.logoHeight, alignment: theme.logoPlacement == .center ? .center : .leading)
            .accessibilityLabel(theme.displayName ?? "Logo")
        } else if let name = theme.displayName {
            Text(name)
                .font(.usDisplay(17, .bold))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
        }
    }
}

/// "Powered by Sense" (fixed text, every capture screen). On the camera it is
/// the fixed 50% white; on a page it takes the page's muted colour so it reads.
struct CapturePoweredBy: View {
    var onCamera: Bool
    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        Text("Powered by Sense")
            .font(.system(size: 12))
            .foregroundColor(onCamera ? CaptureTokens.poweredByInk.opacity(CaptureTokens.poweredByOpacity) : theme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .allowsHitTesting(false)
            .accessibilityIdentifier("usesense.capture.footer")
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

    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            CapturePageBackground()
            VStack(alignment: .leading, spacing: 16) {
                CaptureLogoHeader()
                    .padding(.bottom, 8)
                illustration
                Text(content.title)
                    .font(.usDisplay(28, .bold))
                    .tracking(-0.28)
                    .foregroundColor(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("usesense.page.title")
                Text(content.body)
                    .font(.usBody(16))
                    .lineSpacing(5)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("usesense.page.body")
                if !content.tips.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(content.tips, id: \.self) { tip in
                            HStack(spacing: 12) {
                                Circle().fill(theme.primaryColor).frame(width: 8, height: 8)
                                Text(tip)
                                    .font(.usBody(15))
                                    .foregroundColor(theme.foreground)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                PrimaryCaptureButton(title: content.primary, action: onPrimary)
                    .accessibilityIdentifier("usesense.page.primary")
                if let secondary = content.secondary, let onSecondary {
                    SecondaryCaptureButton(title: secondary, busy: busySecondary, action: onSecondary)
                        .accessibilityIdentifier("usesense.page.secondary")
                }
                CapturePoweredBy(onCamera: false)
                    .padding(.top, -4)
            }
            .padding(.horizontal, 28)
            .padding(.top, 72)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let onClose {
                CaptureTopBar(onBack: onClose, onPage: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
    }

    /// The brand's result illustration when set, else the icon tile.
    @ViewBuilder private var illustration: some View {
        if let slot = content.iconSlot, let url = theme.icon(slot) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                tile
            }
            .frame(width: 96, height: 96, alignment: .leading)
            .accessibilityHidden(true)
        } else {
            tile
        }
    }

    private var tile: some View {
        Image(systemName: content.icon)
            .font(.system(size: 30, weight: .semibold))
            .foregroundColor(content.tone.ink(theme))
            .frame(width: 72, height: 72)
            .background(RoundedRectangle(cornerRadius: theme.tileRadius, style: .continuous)
                .fill(content.tone.fill(theme)))
            .accessibilityHidden(true)
    }
}

// MARK: - "Getting ready" and the camera request

/// The loader: spinner (primary), dots or bar, or the brand's own image.
struct CaptureLoader: View {
    @SwiftUI.Environment(\.captureTheme) private var theme
    @State private var phase = false

    var body: some View {
        Group {
            if let url = theme.loaderImageURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    spinner
                }
                .frame(width: 64, height: 64)
            } else {
                switch theme.loaderStyle {
                case .spinner: spinner
                case .dots: dots
                case .bar: bar
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var spinner: some View {
        ProgressView().progressViewStyle(.circular).tint(theme.primaryColor).scaleEffect(1.4)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(theme.primaryColor).frame(width: 10, height: 10)
                    .opacity(phase ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: phase)
            }
        }
        .onAppear { phase = true }
    }

    private var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.border)
                Capsule().fill(theme.primaryColor)
                    .frame(width: g.size.width * 0.35)
                    .offset(x: phase ? g.size.width * 0.65 : 0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
            }
        }
        .frame(width: 160, height: 4)
        .onAppear { phase = true }
    }
}

/// "Getting ready": the page while the session starts.
struct CaptureLoadingView: View {
    var title: String = CaptureScreenCopy.gettingReady
    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        ZStack {
            CapturePageBackground()
            VStack(spacing: 0) {
                CaptureLogoHeader().padding(.horizontal, 28).padding(.top, 72)
                Spacer()
                CaptureLoader()
                Text(title)
                    .font(.usDisplay(20, .bold))
                    .foregroundColor(theme.foreground)
                    .padding(.top, 22)
                    .accessibilityIdentifier("usesense.loading.title")
                Spacer()
                CapturePoweredBy(onCamera: false)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Dialogs

/// A centred dialog on the page surface (leave, help).
struct CaptureDialog<Buttons: View>: View {
    let title: String
    let message: String
    @ViewBuilder let buttons: () -> Buttons
    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        ZStack {
            CaptureTokens.dialogScrim.ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title)
                    .font(.usDisplay(17, .bold))
                    .foregroundColor(theme.foreground)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.usBody(14))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { buttons() }
                    .font(.usBody(15, .semibold))
                    .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .frame(width: 290)
            .background(RoundedRectangle(cornerRadius: theme.dialogRadius, style: .continuous).fill(theme.surface))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity)
    }
}

/// A dialog button: primary (brand) or secondary (outline in the border colour).
struct CaptureDialogButton: View {
    let title: String
    var primary: Bool
    let action: () -> Void
    @SwiftUI.Environment(\.captureTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(theme.buttonRadius, 22), style: .continuous)
        let outlined = !primary || theme.buttonOutlined
        Button(action: action) {
            Text(title)
                .foregroundColor(primary ? (theme.buttonOutlined ? theme.primaryColor : theme.onPrimary) : theme.foreground)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(shape.fill(outlined ? Color.clear : theme.primaryColor))
                .overlay(shape.stroke(outlined ? (primary ? theme.primaryColor : theme.border) : Color.clear, lineWidth: 1.5))
                .contentShape(shape)
        }
    }
}

struct LeaveVerificationDialog: View {
    let onLeave: () -> Void
    let onStay: () -> Void

    var body: some View {
        CaptureDialog(title: CaptureScreenCopy.leaveTitle, message: CaptureScreenCopy.leaveBody) {
            CaptureDialogButton(title: CaptureScreenCopy.leave, primary: false, action: onLeave)
                .accessibilityIdentifier("usesense.leave.confirm")
            CaptureDialogButton(title: CaptureScreenCopy.keepGoing, primary: true, action: onStay)
                .accessibilityIdentifier("usesense.leave.stay")
        }
    }
}

/// The help dialog on the camera screens (was a system alert, which can't
/// follow the brand).
struct CaptureHelpDialog: View {
    let title: String
    let message: String
    let onClose: () -> Void

    var body: some View {
        CaptureDialog(title: title, message: message) {
            CaptureDialogButton(title: "OK", primary: true, action: onClose)
                .accessibilityIdentifier("usesense.help.close")
        }
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
