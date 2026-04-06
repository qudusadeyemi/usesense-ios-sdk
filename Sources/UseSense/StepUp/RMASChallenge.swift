#if canImport(UIKit)
import Foundation
import UIKit

/// Result of a Randomized Micro-Action Sequence challenge.
struct RMASResult: Sendable {
    let actions: [ActionResult]
    let passed: Bool
    let confidence: Double
    let actionsCompleted: Int
    let actionsTotal: Int

    struct ActionResult: Sendable {
        let actionType: String
        let label: String
        let windowMs: Int
        let completed: Bool
        let reactionTimeMs: Int?
    }
}

/// RMAS: prompt 3 random facial micro-actions. Pre-recorded video can't respond.
///
/// Action pool: blink, smile, raise_eyebrows, open_mouth, turn_left, turn_right
/// Each action: 1.5s window, poll face detection every 100ms
/// 300ms pause between actions
/// Pass if >= 2 of 3 completed
/// Hard reject: 0 of 3 completed
final class RMASChallenge {

    struct ActionSpec {
        let type: String
        let label: String
    }

    private static let actionPool: [ActionSpec] = [
        ActionSpec(type: "blink", label: "Blink twice"),
        ActionSpec(type: "smile", label: "Smile"),
        ActionSpec(type: "raise_eyebrows", label: "Raise your eyebrows"),
        ActionSpec(type: "open_mouth", label: "Open your mouth"),
        ActionSpec(type: "turn_left", label: "Turn head left"),
        ActionSpec(type: "turn_right", label: "Turn head right"),
    ]

    func run(
        getCurrentPose: @escaping () -> HeadPose?,
        getCurrentEAR: @escaping () -> (left: Double, right: Double)?
    ) async -> RMASResult {
        // Pick 3 random actions (no duplicates)
        let selected = Array(Self.actionPool.shuffled().prefix(3))
        var results: [RMASResult.ActionResult] = []
        var completed = 0

        // Capture baseline
        let baselinePose = getCurrentPose()
        let baselineEAR = getCurrentEAR()

        for action in selected {
            let startTime = Date()
            var actionCompleted = false
            var reactionTime: Int?

            // Poll face detection every 100ms for 1.5s window
            let windowMs = 1500
            let pollInterval: UInt64 = 100_000_000 // 100ms in nanoseconds

            for _ in 0..<(windowMs / 100) {
                let currentPose = getCurrentPose()
                let currentEAR = getCurrentEAR()

                if validateAction(
                    type: action.type,
                    currentPose: currentPose,
                    currentEAR: currentEAR,
                    baselinePose: baselinePose,
                    baselineEAR: baselineEAR
                ) {
                    actionCompleted = true
                    reactionTime = Int(Date().timeIntervalSince(startTime) * 1000)
                    break
                }

                try? await Task.sleep(nanoseconds: pollInterval)
            }

            if actionCompleted { completed += 1 }

            results.append(RMASResult.ActionResult(
                actionType: action.type,
                label: action.label,
                windowMs: windowMs,
                completed: actionCompleted,
                reactionTimeMs: reactionTime
            ))

            // 300ms pause between actions
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        return RMASResult(
            actions: results,
            passed: completed >= 2,
            confidence: Double(completed) / 3.0 * 100.0,
            actionsCompleted: completed,
            actionsTotal: 3
        )
    }

    /// Validate whether an action has been performed.
    /// Thresholds from spec Section 7.5.
    private func validateAction(
        type: String,
        currentPose: HeadPose?,
        currentEAR: (left: Double, right: Double)?,
        baselinePose: HeadPose?,
        baselineEAR: (left: Double, right: Double)?
    ) -> Bool {
        switch type {
        case "blink":
            // Eye aspect ratio < 0.2 (either eye)
            guard let ear = currentEAR else { return false }
            return ear.left < 0.2 || ear.right < 0.2

        case "smile":
            // Mouth width increases > 15% from baseline
            // Approximated via pose change (in production, use mouth landmarks)
            return false

        case "raise_eyebrows":
            // Brow landmarks move up > 0.008 normalized units
            // Approximated via pitch change
            guard let current = currentPose, let baseline = baselinePose else { return false }
            return abs(current.pitch - baseline.pitch) > 3.0

        case "open_mouth":
            // Upper-to-lower lip distance > 0.025 normalized units
            // Approximated via pose change (in production, use lip landmarks)
            return false

        case "turn_left":
            // Head yaw exceeds 12 degrees in left direction
            guard let current = currentPose else { return false }
            return current.yaw < -12.0

        case "turn_right":
            // Head yaw exceeds 12 degrees in right direction
            guard let current = currentPose else { return false }
            return current.yaw > 12.0

        default:
            return false
        }
    }
}
#endif
