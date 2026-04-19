//
//  ZoomPromptView.swift
//  UseSense
//
//  LiveSense v4 framing-oval UI. Phase 1 ticket I-1.
//
//  Mirror of web-sdk ZoomPrompt. Animates between 1.0 and 1.4 scale
//  over 250ms with brand cubic-bezier easing. Respects the system
//  reduce-motion accessibility setting.
//

import SwiftUI

public enum ZoomGuidanceTone {
    case neutral, positive, warning
}

public struct ZoomPromptView: View {
    public static let transitionMs: Double = 250
    public static let enlargedScale: CGFloat = 1.4

    public let state: ZoomOvalState
    public let guidance: String
    public let tone: ZoomGuidanceTone
    public let primaryColor: Color
    public let onEnlargeAnimationComplete: (() -> Void)?

    public init(
        state: ZoomOvalState,
        guidance: String,
        tone: ZoomGuidanceTone = .neutral,
        primaryColor: Color = Color(red: 123/255, green: 216/255, blue: 156/255),
        onEnlargeAnimationComplete: (() -> Void)? = nil
    ) {
        self.state = state
        self.guidance = guidance
        self.tone = tone
        self.primaryColor = primaryColor
        self.onEnlargeAnimationComplete = onEnlargeAnimationComplete
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Guidance text at top 12% of the container.
                Text(guidance)
                    .font(.system(size: 17, weight: .medium, design: .default))
                    .foregroundColor(guidanceColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.12)
                    .accessibilityAddTraits(.updatesFrequently)

                // Oval overlay at 40% vertical. Size is 44vmin x 59vmin;
                // scale animates between 1.0 and 1.4.
                let vmin = min(geo.size.width, geo.size.height)
                let ovalW = vmin * 0.44
                let ovalH = vmin * 0.59
                RoundedRectangle(cornerRadius: ovalW / 2, style: .continuous)
                    .stroke(Color.white.opacity(0.95), lineWidth: 3)
                    .frame(width: ovalW, height: ovalH)
                    .scaleEffect(currentScale)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.40)
                    .animation(animation, value: state)
                    .onChange(of: state) { newState in
                        // Fire the completion callback once the CSS-equivalent
                        // transition ends. Skipped in reduce-motion.
                        if newState == .enlarged && !reduceMotion {
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + .milliseconds(Int(ZoomPromptView.transitionMs) + 20)
                            ) {
                                onEnlargeAnimationComplete?()
                            }
                        }
                    }
            }
        }
        .background(Color.clear)
        .allowsHitTesting(false)
    }

    private var currentScale: CGFloat {
        state == .enlarged ? ZoomPromptView.enlargedScale : 1.0
    }

    private var animation: Animation {
        reduceMotion
            ? .linear(duration: 0)
            : .timingCurve(0.16, 1, 0.3, 1, duration: ZoomPromptView.transitionMs / 1000.0)
    }

    private var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    private var guidanceColor: Color {
        switch tone {
        case .positive: return primaryColor
        case .warning: return Color(red: 246/255, green: 195/255, blue: 107/255)
        case .neutral: return Color.white
        }
    }
}

#if DEBUG
struct ZoomPromptView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ZoomPromptView(state: .framing, guidance: "Fit your face in the oval")
                .background(Color.black)
                .previewDisplayName("Framing")
            ZoomPromptView(state: .enlarged, guidance: "Move phone closer")
                .background(Color.black)
                .previewDisplayName("Enlarged")
        }
    }
}
#endif
