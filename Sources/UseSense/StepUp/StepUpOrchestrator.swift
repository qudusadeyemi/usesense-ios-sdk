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
        getCurrentEAR: @escaping () -> (left: Double, right: Double)?
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
                getCurrentEAR: getCurrentEAR
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
        getCurrentEAR: @escaping () -> (left: Double, right: Double)?
    ) async -> StepUpResult {
        var flashResult: FlashReflectionResult?
        var rmasResult: RMASResult?

        for challenge in challenges {
            switch challenge {
            case "flash_reflection":
                flashResult = await FlashReflectionChallenge().run(captureFrame: captureFrame)
            case "rmas":
                rmasResult = await RMASChallenge().run(
                    getCurrentPose: getCurrentPose,
                    getCurrentEAR: getCurrentEAR
                )
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

    private func withTimeout<T: Sendable>(seconds: Int, operation: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                return await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                return nil
            }
            // Return first completed result
            for await result in group {
                group.cancelAll()
                return result
            }
            return nil
        }
    }
}
#endif
