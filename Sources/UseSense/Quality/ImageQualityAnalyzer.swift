#if canImport(AVFoundation) && canImport(Accelerate)
import Foundation
import AVFoundation
import Accelerate

// MARK: - Quality Enums (matching Android SDK)

enum QualityLevel: String, Sendable {
    case good = "GOOD"
    case acceptable = "ACCEPTABLE"
    case poor = "POOR"
}

enum GuidanceSeverity: String, Sendable {
    case critical = "CRITICAL"
    case warning = "WARNING"
    case info = "INFO"
}

enum GuidanceIcon: String, Sendable {
    case blur = "BLUR"
    case dark = "DARK"
    case bright = "BRIGHT"
    case contrast = "CONTRAST"
}

struct QualityGuidance: Sendable {
    let message: String
    let severity: GuidanceSeverity
    let icon: GuidanceIcon?
}

struct ImageQualityReport: Sendable {
    let laplacianVariance: Float
    let meanBrightness: Float
    let contrastStdDev: Float
    let underExposedRatio: Float
    let overExposedRatio: Float
    let overallScore: Float
    let qualityLevel: QualityLevel
    let isAcceptable: Bool
    let isTooDark: Bool
    let isTooBright: Bool
    let guidanceMessages: [QualityGuidance]
}

final class ImageQualityAnalyzer: @unchecked Sendable {
    private let analysisQueue = DispatchQueue(label: "com.usesense.quality", qos: .userInitiated)
    private var lastAnalysisTime: CFAbsoluteTime = 0

    // Analysis interval: 250ms (4Hz), matching Android's ANALYSIS_INTERVAL_MS
    private let analysisInterval: TimeInterval = 0.25

    // Score weights matching Android: blur 45%, lighting 55%
    private static let blurWeight: Float = 0.45
    private static let lightingWeight: Float = 0.55

    // Acceptable quality threshold matching Android
    static let acceptableThreshold: Float = 35.0

    func shouldAnalyze() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnalysisTime >= analysisInterval else { return false }
        lastAnalysisTime = now
        return true
    }

    func analyze(_ pixelBuffer: CVPixelBuffer) -> ImageQualityReport {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return defaultReport()
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Downsample to 160x120 grayscale (matching Android)
        let targetW = 160
        let targetH = 120
        let scaleX = Float(width) / Float(targetW)
        let scaleY = Float(height) / Float(targetH)
        let totalPixels = targetW * targetH

        var grayscale = [Float](repeating: 0, count: totalPixels)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in 0..<targetH {
            let srcY = min(Int(Float(y) * scaleY), height - 1)
            for x in 0..<targetW {
                let srcX = min(Int(Float(x) * scaleX), width - 1)
                let offset = srcY * bytesPerRow + srcX * 4
                let b = Float(ptr[offset])
                let g = Float(ptr[offset + 1])
                let r = Float(ptr[offset + 2])
                // ITU-R BT.601 formula
                grayscale[y * targetW + x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }

        // Mean brightness
        var mean: Float = 0
        vDSP_meanv(grayscale, 1, &mean, vDSP_Length(totalPixels))

        // Standard deviation (contrast)
        var stdDev: Float = 0
        var meanSquared: Float = 0
        vDSP_measqv(grayscale, 1, &meanSquared, vDSP_Length(totalPixels))
        let squaredMean = mean * mean
        stdDev = sqrtf(max(0, meanSquared - squaredMean))

        // Under/over exposure ratios
        var underCount: Float = 0
        var overCount: Float = 0
        for val in grayscale {
            if val < 40 { underCount += 1 }
            if val > 215 { overCount += 1 }
        }
        let underRatio = underCount / Float(totalPixels)
        let overRatio = overCount / Float(totalPixels)

        // Laplacian variance (blur detection)
        let laplacianVar = computeLaplacianVariance(grayscale, width: targetW, height: targetH)

        let isTooDark = mean < 55
        let isTooBright = mean > 210

        // Overall score: 45% blur + 55% lighting (matching Android weights)
        let blurScore = min(100, max(0, (laplacianVar - 30) / (80 - 30) * 100))
        let lightingScore: Float
        if isTooDark || isTooBright {
            lightingScore = 0
        } else if mean >= 80 && mean <= 180 && stdDev >= 40 {
            lightingScore = 100
        } else {
            lightingScore = min(100, max(0, (mean - 55) / (80 - 55) * 50 + (stdDev - 25) / (40 - 25) * 50))
        }
        let overallScore = blurScore * Self.blurWeight + lightingScore * Self.lightingWeight

        // Quality level thresholds matching Android
        let qualityLevel: QualityLevel
        if overallScore >= 70 {
            qualityLevel = .good
        } else if overallScore >= Self.acceptableThreshold {
            qualityLevel = .acceptable
        } else {
            qualityLevel = .poor
        }

        // Build guidance
        var guidance: [QualityGuidance] = []
        let suppressBlur = isTooDark || isTooBright || underRatio > 0.45 || overRatio > 0.45

        if isTooDark {
            guidance.append(.init(message: "Turn on the lights or move to a bright area", severity: .critical, icon: .dark))
        } else if isTooBright {
            guidance.append(.init(message: "Too bright -- move away from direct light", severity: .critical, icon: .bright))
        } else if mean < 80 {
            guidance.append(.init(message: "A bit dark -- more light would help", severity: .warning, icon: .dark))
        }

        if underRatio > 0.45 {
            guidance.append(.init(message: "Image is too dark -- add more lighting", severity: .critical, icon: .dark))
        }
        if overRatio > 0.45 {
            guidance.append(.init(message: "Too much glare -- reduce backlighting", severity: .critical, icon: .bright))
        }
        if stdDev < 20 {
            guidance.append(.init(message: "Low contrast -- adjust your lighting", severity: .warning, icon: .contrast))
        }

        if !suppressBlur {
            if laplacianVar < 30 {
                guidance.append(.init(message: "Clean your camera lens or hold your device steady", severity: .critical, icon: .blur))
            } else if laplacianVar < 80 && overallScore < 50 {
                guidance.append(.init(message: "Image is slightly blurry -- hold still", severity: .warning, icon: .blur))
            }
        }

        guidance.sort { lhs, rhs in
            let order: [GuidanceSeverity] = [.critical, .warning, .info]
            return (order.firstIndex(of: lhs.severity) ?? 2) < (order.firstIndex(of: rhs.severity) ?? 2)
        }

        return ImageQualityReport(
            laplacianVariance: laplacianVar, meanBrightness: mean,
            contrastStdDev: stdDev, underExposedRatio: underRatio,
            overExposedRatio: overRatio, overallScore: overallScore,
            qualityLevel: qualityLevel,
            isAcceptable: overallScore >= Self.acceptableThreshold,
            isTooDark: isTooDark, isTooBright: isTooBright,
            guidanceMessages: guidance
        )
    }

    private func computeLaplacianVariance(_ grayscale: [Float], width: Int, height: Int) -> Float {
        var result = [Float](repeating: 0, count: width * height)

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = grayscale[y * width + x]
                let top = grayscale[(y - 1) * width + x]
                let bottom = grayscale[(y + 1) * width + x]
                let left = grayscale[y * width + (x - 1)]
                let right = grayscale[y * width + (x + 1)]
                result[y * width + x] = top + bottom + left + right - 4 * center
            }
        }

        let inner = (height - 2) * (width - 2)
        guard inner > 0 else { return 0 }

        var mean: Float = 0
        var meanSq: Float = 0
        vDSP_meanv(result, 1, &mean, vDSP_Length(result.count))
        vDSP_measqv(result, 1, &meanSq, vDSP_Length(result.count))
        return max(0, meanSq - mean * mean)
    }

    private func defaultReport() -> ImageQualityReport {
        ImageQualityReport(
            laplacianVariance: 0, meanBrightness: 128, contrastStdDev: 40,
            underExposedRatio: 0, overExposedRatio: 0, overallScore: 50,
            qualityLevel: .acceptable, isAcceptable: true,
            isTooDark: false, isTooBright: false, guidanceMessages: []
        )
    }
}
#endif
