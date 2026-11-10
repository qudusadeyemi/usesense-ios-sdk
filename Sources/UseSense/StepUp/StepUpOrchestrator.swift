#if canImport(AVFoundation) && canImport(UIKit)
import Foundation
import UIKit

/// Result of an inline step-up challenge sequence.
struct StepUpResult: Sendable {
    let challengesRun: [String]
    let triggerSuspicionScore: Double
    let flashReflection: FlashReflectionResult?
    let rmas: RMASResult?
    let passed: Bool
    let hardReject: Bool
    let timestamp: String
}

/// What the screen shows while the inline step-up runs.
enum InlineStepUpPrompt: Equatable {
    /// A Flash Reflection step: `color` on screen now, or nil between flashes.
    case flash(color: String?, step: Int, steps: Int)
    /// An RMAS micro-action, waiting for the person to do it.
    case action(type: String, step: Int, steps: Int)
}

/// Guided screens: the inline step-up drawn on the scan screen (plain
/// guidance under the oval, amber ring while it waits for the person).
struct InlineStepUpDisplay: Equatable {
    var title: String
    var subtitle: String?
    var progress: Double
    /// Flash Reflection colour to fill the screen with (hex), if any.
    var flashColor: String?

    static let preparing = InlineStepUpDisplay(title: "Hold still", subtitle: nil, progress: 0, flashColor: nil)

    init(title: String, subtitle: String?, progress: Double, flashColor: String?) {
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.flashColor = flashColor
    }

    init(_ prompt: InlineStepUpPrompt) {
        switch prompt {
        case .flash(let color, let step, let steps):
            self.init(title: "Hold still", subtitle: "Your screen will change colour",
                      progress: Double(step + 1) / Double(max(1, steps)), flashColor: color)
        case .action(let type, let step, let steps):
            self.init(title: Self.actionTitle(type), subtitle: nil,
                      progress: Double(step + 1) / Double(max(1, steps)), flashColor: nil)
        }
    }

    /// Guided copy for each RMAS action (the upload keeps RMAS's own labels).
    static func actionTitle(_ type: String) -> String {
        switch type {
        case "blink": return "Blink twice"
        case "smile": return "Smile"
        case "raise_eyebrows": return "Raise your eyebrows"
        case "open_mouth": return "Open your mouth"
        case "turn_left": return "Turn your head to the left"
        case "turn_right": return "Turn your head to the right"
        default: return "Hold still"
        }
    }
}

/// Orchestrates inline step-up challenges (Flash Reflection + RMAS).
/// Timeout protection: 15 seconds max for the entire sequence.
///
/// Challenge selection (auto mode):
/// - Threshold to threshold+20: Flash Reflection only (~3s)
/// - Threshold+20 and above: Flash Reflection + RMAS (~9s)
final class StepUpOrchestrator: @unchecked Sendable {

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Run step-up challenges based on suspicion score and config.
    /// Camera MUST stay active throughout.
    /// - Parameters:
    ///   - suspicionScore: Current suspicion engine score (0-100)
    ///   - config: Inline step-up configuration from session policy
    ///   - captureFrame: Closure to capture current camera frame as UIImage
    ///   - faceMeshManager: For RMAS action validation
    /// - Returns: StepUpResult with challenge outcomes
    func run(
        suspicionScore: Double,
        config: InlineStepUpConfig,
        captureFrame: @escaping () -> UIImage?,
        getCurrentPose: @escaping () -> HeadPose?,
        getCurrentEAR: @escaping () -> (left: Double, right: Double)?,
        onPrompt: @escaping (InlineStepUpPrompt) -> Void = { _ in }
    ) async -> StepUpResult {
        let threshold = Double(config.suspicionThreshold)

        // Determine which challenges to run
        var challengesToRun: [String] = []
        let preferred = config.preferredChallenge

        if preferred == "flash_reflection" {
            challengesToRun = ["flash_reflection"]
        } else if preferred == "rmas" {
            challengesToRun = ["rmas"]
        } else {
            // Auto mode
            if suspicionScore >= threshold + 20 {
                challengesToRun = ["flash_reflection", "rmas"]
            } else {
                challengesToRun = ["flash_reflection"]
            }
        }

        // Run with 15-second timeout protection
        let result = await withTimeout(seconds: 15) { [self] in
            await self.runChallenges(
                challengesToRun,
                suspicionScore: suspicionScore,
                captureFrame: captureFrame,
                getCurrentPose: getCurrentPose,
                getCurrentEAR: getCurrentEAR,
                onPrompt: onPrompt
            )
        }

        return result ?? StepUpResult(
            challengesRun: [],
            triggerSuspicionScore: suspicionScore,
            flashReflection: nil,
            rmas: nil,
            passed: false,
            hardReject: false,
            timestamp: isoFormatter.string(from: Date())
        )
    }

    private func runChallenges(
        _ challenges: [String],
        suspicionScore: Double,
        captureFrame: @escaping () -> UIImage?,
        getCurrentPose: @escaping () -> HeadPose?,
        getCurrentEAR: @escaping () -> (left: Double, right: Double)?,
        onPrompt: @escaping (InlineStepUpPrompt) -> Void
    ) async -> StepUpResult {
        var flashResult: FlashReflectionResult?
        var rmasResult: RMASResult?
        // 3 steps per challenge, for the ring.
        let total = challenges.count * 3
        var offset = 0

        for challenge in challenges {
            let base = offset
            switch challenge {
            case "flash_reflection":
                flashResult = await FlashReflectionChallenge().run(captureFrame: captureFrame) { i, hex in
                    onPrompt(.flash(color: hex, step: base + i, steps: total))
                }
                offset += 3
            case "rmas":
                rmasResult = await RMASChallenge().run(
                    getCurrentPose: getCurrentPose,
                    getCurrentEAR: getCurrentEAR
                ) { i, action in
                    onPrompt(.action(type: action.type, step: base + i, steps: total))
                }
                offset += 3
            default:
                break
            }
        }

        // Determine pass/fail
        let flashPassed = flashResult?.passed ?? true
        let rmasPassed = rmasResult?.passed ?? true
        let passed = flashPassed || rmasPassed  // At least one must pass

        // Hard reject criteria
        var hardReject = false
        if let flash = flashResult, flash.overallColorDelta < 3.0 {
            hardReject = true  // Average delta < 3 across ALL flashes
        }
        if let rmas = rmasResult, rmas.actionsCompleted == 0 {
            hardReject = true  // 0 of 3 actions completed
        }
        if let flash = flashResult, let rmas = rmasResult,
           !flash.passed && !rmas.passed {
            hardReject = true  // Both decisively failed
        }

        return StepUpResult(
            challengesRun: challenges,
            triggerSuspicionScore: suspicionScore,
            flashReflection: flashResult,
            rmas: rmasResult,
            passed: passed && !hardReject,
            hardReject: hardReject,
            timestamp: isoFormatter.string(from: Date())
        )
    }

    /// Returns at the deadline even if the challenges ignore cancellation.
    /// (The task-group race this replaced kept waiting for the operation after
    /// the timer fired, so the 15s cap never actually capped anything.)
    private func withTimeout<T>(seconds: Int, operation: @escaping () async -> T) async -> T? {
        await Deadline.run(seconds: TimeInterval(seconds)) { await operation() }
    }
}
#endif
