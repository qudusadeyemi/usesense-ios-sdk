#if canImport(AVFoundation) && canImport(UIKit)
import Foundation

/// Client-side presentation attack detection engine.
/// Runs alongside the face detection loop during capture, analyzing every 2nd frame.
/// Produces a 0-100 suspicion score that can trigger inline step-up challenges.
///
/// Signals (4 weighted):
/// - Pose Micro-Tremor (0.35): Real faces show irregular micro-jitter
/// - Temporal Smoothness (0.25): Screens show unnaturally smooth motion
/// - Brightness Stability (0.20): Screens have very stable luminance
/// - Sharpness Pattern (0.20): Screens show low sharpness with high brightness
final class SuspicionEngine: @unchecked Sendable {

    struct SuspicionSnapshot: Sendable {
        let score: Double
        let signals: [SignalSnapshot]
        let framesAnalyzed: Int
        let reliable: Bool
        let timestamp: Int64

        struct SignalSnapshot: Sendable {
            let name: String
            let score: Double
            let weight: Double
            let detail: String
        }
    }

    private let config: InlineStepUpConfig?
    private let lock = NSLock()

    // Rolling window of last 30 frames
    private var poseHistory: [(yaw: Double, pitch: Double, roll: Double)] = []
    private var luminanceHistory: [Double] = []
    private var sharpnessHistory: [Double] = []
    private static let windowSize = 30

    // Analyzer instances
    private let microTremorAnalyzer = MicroTremorAnalyzer()
    private let temporalSmoothnessAnalyzer = TemporalSmoothnessAnalyzer()
    private let brightnessStabilityAnalyzer = BrightnessStabilityAnalyzer()
    private let sharpnessPatternAnalyzer = SharpnessPatternAnalyzer()

    // State
    private var currentScore: Double = 0
    private var framesAnalyzed: Int = 0
    private var frameCounter: Int = 0
    private(set) var triggered: Bool = false

    init(config: InlineStepUpConfig? = nil) {
        self.config = config
    }

    /// Analyze a frame. Called from the capture loop.
    /// Only processes every 2nd frame to reduce CPU overhead.
    /// MUST NOT block the capture loop -- caller should dispatch to background queue.
    func analyzeFrame(pose: HeadPose, luminance: Double, sharpness: Double) {
        lock.lock()
        frameCounter += 1
        let shouldProcess = frameCounter % 2 == 0
        lock.unlock()

        guard shouldProcess else { return }

        lock.lock()

        // Add to rolling window
        poseHistory.append((yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll))
        luminanceHistory.append(luminance)
        sharpnessHistory.append(sharpness)

        // Trim to window size
        if poseHistory.count > Self.windowSize {
            poseHistory.removeFirst(poseHistory.count - Self.windowSize)
        }
        if luminanceHistory.count > Self.windowSize {
            luminanceHistory.removeFirst(luminanceHistory.count - Self.windowSize)
        }
        if sharpnessHistory.count > Self.windowSize {
            sharpnessHistory.removeFirst(sharpnessHistory.count - Self.windowSize)
        }

        framesAnalyzed += 1

        // Need minimum data for analysis
        guard poseHistory.count >= 4 else {
            lock.unlock()
            return
        }

        let poses = poseHistory
        let luminances = luminanceHistory
        let sharpnesses = sharpnessHistory
        lock.unlock()

        // Compute individual signal scores (0 = live, 100 = screen)
        let tremorScore = microTremorAnalyzer.analyze(poses: poses)
        let smoothnessScore = temporalSmoothnessAnalyzer.analyze(poses: poses)
        let brightnessScore = brightnessStabilityAnalyzer.analyze(luminances: luminances)
        let sharpnessScore = sharpnessPatternAnalyzer.analyze(sharpnesses: sharpnesses, luminances: luminances)

        // Weighted average
        let instantScore = tremorScore * 0.35 +
                          smoothnessScore * 0.25 +
                          brightnessScore * 0.20 +
                          sharpnessScore * 0.20

        // Exponential moving average
        lock.lock()
        currentScore = 0.3 * instantScore + 0.7 * currentScore
        lock.unlock()
    }

    /// Check if step-up should be triggered.
    /// Requires: score >= threshold AND framesAnalyzed >= 6
    func shouldTriggerStepUp() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let config = config, config.enabled else { return false }
        guard framesAnalyzed >= 6 else { return false }

        if currentScore >= Double(config.suspicionThreshold) {
            triggered = true
            return true
        }
        return false
    }

    /// Get current suspicion snapshot for upload.
    func snapshot() -> SuspicionSnapshot {
        lock.lock()
        let score = currentScore
        let analyzed = framesAnalyzed
        let poses = poseHistory
        let luminances = luminanceHistory
        let sharpnesses = sharpnessHistory
        lock.unlock()

        let tremorScore = poses.count >= 4 ? microTremorAnalyzer.analyze(poses: poses) : 0
        let smoothnessScore = poses.count >= 4 ? temporalSmoothnessAnalyzer.analyze(poses: poses) : 0
        let brightnessScore = luminances.count >= 4 ? brightnessStabilityAnalyzer.analyze(luminances: luminances) : 0
        let sharpnessScore = sharpnesses.count >= 4 ? sharpnessPatternAnalyzer.analyze(sharpnesses: sharpnesses, luminances: luminances) : 0

        return SuspicionSnapshot(
            score: score,
            signals: [
                .init(name: "micro_tremor", score: tremorScore, weight: 0.35,
                      detail: "Pose delta analysis over \(poses.count) frames"),
                .init(name: "temporal_smoothness", score: smoothnessScore, weight: 0.25,
                      detail: "Jerk and zero-crossing analysis"),
                .init(name: "brightness_stability", score: brightnessScore, weight: 0.20,
                      detail: "Luminance CV across \(luminances.count) frames"),
                .init(name: "sharpness_pattern", score: sharpnessScore, weight: 0.20,
                      detail: "Sharpness-brightness correlation")
            ],
            framesAnalyzed: analyzed,
            reliable: analyzed >= 6,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    func reset() {
        lock.lock()
        poseHistory.removeAll()
        luminanceHistory.removeAll()
        sharpnessHistory.removeAll()
        currentScore = 0
        framesAnalyzed = 0
        frameCounter = 0
        triggered = false
        lock.unlock()
    }
}

// MARK: - Micro-Tremor Analyzer (weight: 0.35)

/// Computes median pose delta between consecutive frames.
/// Screen: stable/smooth < 0.05 deg median delta
/// Live: irregular 0.08-0.8 deg jitter with high variance
final class MicroTremorAnalyzer {
    func analyze(poses: [(yaw: Double, pitch: Double, roll: Double)]) -> Double {
        guard poses.count >= 2 else { return 0 }

        var deltas: [Double] = []
        for i in 1..<poses.count {
            let dy = abs(poses[i].yaw - poses[i-1].yaw)
            let dp = abs(poses[i].pitch - poses[i-1].pitch)
            let dr = abs(poses[i].roll - poses[i-1].roll)
            deltas.append(dy + dp + dr)
        }

        let sorted = deltas.sorted()
        let median = sorted[sorted.count / 2]
        let variance = computeVariance(deltas)

        // Screen indicator: very stable (median < 0.05) or unnaturally smooth (low variance)
        if median < 0.05 {
            return min(100, 90 + (0.05 - median) * 200)
        }
        if variance < 0.001 && median < 0.15 {
            return min(100, 70 + (0.15 - median) * 200)
        }

        // Live indicator: irregular jitter with high variance
        if median >= 0.08 && median <= 0.8 && variance > 0.01 {
            return max(0, 30 - variance * 500)
        }

        return max(0, min(100, 50 - median * 50))
    }

    private func computeVariance(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
    }
}

// MARK: - Temporal Smoothness Analyzer (weight: 0.25)

/// Computes jerk (3rd derivative) and zero-crossing rate.
/// Screen: low jerk, low zero-crossing rate
/// Live: high jerk, frequent direction reversals
final class TemporalSmoothnessAnalyzer {
    func analyze(poses: [(yaw: Double, pitch: Double, roll: Double)]) -> Double {
        guard poses.count >= 4 else { return 0 }

        let yaws = poses.map(\.yaw)

        // Compute velocity (1st derivative)
        var velocities: [Double] = []
        for i in 1..<yaws.count {
            velocities.append(yaws[i] - yaws[i-1])
        }

        // Compute acceleration (2nd derivative)
        var accelerations: [Double] = []
        for i in 1..<velocities.count {
            accelerations.append(velocities[i] - velocities[i-1])
        }

        // Compute jerk (3rd derivative)
        var jerks: [Double] = []
        for i in 1..<accelerations.count {
            jerks.append(abs(accelerations[i] - accelerations[i-1]))
        }

        guard !jerks.isEmpty, !velocities.isEmpty else { return 0 }

        let avgJerk = jerks.reduce(0, +) / Double(jerks.count)

        // Zero-crossing rate of velocity
        var zeroCrossings = 0
        for i in 1..<velocities.count {
            if (velocities[i] >= 0 && velocities[i-1] < 0) ||
               (velocities[i] < 0 && velocities[i-1] >= 0) {
                zeroCrossings += 1
            }
        }
        let zcr = Double(zeroCrossings) / Double(velocities.count)

        // Screen: low jerk + low ZCR = suspicious
        if avgJerk < 0.01 && zcr < 0.2 {
            return min(100, 80 + (0.2 - zcr) * 100)
        }

        // Live: high jerk + high ZCR = natural
        if avgJerk > 0.05 && zcr > 0.3 {
            return max(0, 20 - avgJerk * 100)
        }

        return max(0, min(100, 50 - avgJerk * 200 - zcr * 50))
    }
}

// MARK: - Brightness Stability Analyzer (weight: 0.20)

/// Coefficient of variation of per-frame luminance values.
/// Screen: CV < 0.02, especially in 65-90 lux range
/// Live: natural fluctuation CV > 0.05
final class BrightnessStabilityAnalyzer {
    func analyze(luminances: [Double]) -> Double {
        guard luminances.count >= 3 else { return 0 }

        let mean = luminances.reduce(0, +) / Double(luminances.count)
        guard mean > 1 else { return 0 }

        let variance = luminances.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(luminances.count)
        let stdDev = sqrt(variance)
        let cv = stdDev / mean

        // Screen indicator: very stable luminance
        if cv < 0.02 {
            // Extra suspicious in 65-90 lux range (common screen brightness)
            let isScreenRange = mean >= 65 && mean <= 90
            let base: Double = isScreenRange ? 95 : 85
            return min(100, base + (0.02 - cv) * 500)
        }

        // Live indicator: natural fluctuation
        if cv > 0.05 {
            return max(0, 20 - (cv - 0.05) * 200)
        }

        // Transition zone
        return max(0, min(100, 50 - (cv - 0.02) * 1666))
    }
}

// MARK: - Sharpness Pattern Analyzer (weight: 0.20)

/// Analyzes sharpness-brightness correlation.
/// Screen: low sharpness (<45) with high brightness, uniform across frames
/// Live: good sharpness (>50) with natural variation
final class SharpnessPatternAnalyzer {
    func analyze(sharpnesses: [Double], luminances: [Double]) -> Double {
        guard sharpnesses.count >= 3 else { return 0 }

        let avgSharpness = sharpnesses.reduce(0, +) / Double(sharpnesses.count)
        let avgLuminance = luminances.isEmpty ? 128.0 : luminances.reduce(0, +) / Double(luminances.count)

        // Sharpness variation
        let sharpMean = avgSharpness
        let sharpVariance = sharpnesses.map { ($0 - sharpMean) * ($0 - sharpMean) }.reduce(0, +) / Double(sharpnesses.count)
        let sharpCV = sharpMean > 0 ? sqrt(sharpVariance) / sharpMean : 0

        // Screen indicator: low sharpness with high brightness, uniform
        if avgSharpness < 45 && avgLuminance > 80 && sharpCV < 0.1 {
            return min(100, 80 + (45 - avgSharpness))
        }

        // Live indicator: good sharpness with natural variation
        if avgSharpness > 50 && sharpCV > 0.05 {
            return max(0, 20 - (avgSharpness - 50) * 0.5)
        }

        return max(0, min(100, 50 - avgSharpness * 0.5))
    }
}
#endif
