#if canImport(AVFoundation) && canImport(Accelerate)
import Foundation
import AVFoundation
import Accelerate

struct ImageQualityReport: Sendable {
    let laplacianVariance: Float
    let meanBrightness: Float
    let contrastStdDev: Float
    let underExposedRatio: Float
    let overExposedRatio: Float
    let overallScore: Float
    let isTooDark: Bool
    let isTooBright: Bool
    let guidanceMessages: [QualityGuidance]
}

struct QualityGuidance: Sendable {
    enum Severity: String, Sendable { case critical, warning, info }
    let message: String
    let severity: Severity
}

final class ImageQualityAnalyzer: @unchecked Sendable {
    private let analysisQueue = DispatchQueue(label: "com.usesense.quality", qos: .userInitiated)
    private var lastAnalysisTime: CFAbsoluteTime = 0
    private let analysisInterval: TimeInterval = 0.25 // 4Hz

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
        let totalPixels = width * height

        // Downsample to grayscale
        var grayscale = [Float](repeating: 0, count: totalPixels)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let b = Float(ptr[offset])
                let g = Float(ptr[offset + 1])
                let r = Float(ptr[offset + 2])
                grayscale[y * width + x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }

        // Mean brightness
        var mean: Float = 0
        vDSP_meanv(grayscale, 1, &mean, vDSP_Length(totalPixels))

        // Standard deviation (contrast)
        var stdDev: Float = 0
        var meanSquared: Float = 0
        var squaredMean: Float = 0
        vDSP_measqv(grayscale, 1, &meanSquared, vDSP_Length(totalPixels))
        squaredMean = mean * mean
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
        let laplacianVar = computeLaplacianVariance(grayscale, width: width, height: height)

        let isTooDark = mean < 55
        let isTooBright = mean > 210

        // Overall score: 45% blur + 55% lighting
        let blurScore = min(100, max(0, (laplacianVar - 30) / (80 - 30) * 100))
        let lightingScore: Float
        if isTooDark || isTooBright {
            lightingScore = 0
        } else if mean >= 80 && mean <= 180 && stdDev >= 40 {
            lightingScore = 100
        } else {
            lightingScore = min(100, max(0, (mean - 55) / (80 - 55) * 50 + (stdDev - 25) / (40 - 25) * 50))
        }
        let overallScore = blurScore * 0.45 + lightingScore * 0.55

        // Build guidance
        var guidance: [QualityGuidance] = []
        let suppressBlur = isTooDark || isTooBright || underRatio > 0.45 || overRatio > 0.45

        if isTooDark {
            guidance.append(.init(message: "Turn on the lights or move to a bright area", severity: .critical))
        } else if isTooBright {
            guidance.append(.init(message: "Too bright -- move away from direct light", severity: .critical))
        } else if mean < 80 {
            guidance.append(.init(message: "A bit dark -- more light would help", severity: .warning))
        }

        if underRatio > 0.45 {
            guidance.append(.init(message: "Image is too dark -- add more lighting", severity: .critical))
        }
        if overRatio > 0.45 {
            guidance.append(.init(message: "Too much glare -- reduce backlighting", severity: .critical))
        }
        if stdDev < 20 {
            guidance.append(.init(message: "Low contrast -- adjust your lighting", severity: .warning))
        }

        if !suppressBlur {
            if laplacianVar < 30 {
                guidance.append(.init(message: "Clean your camera lens or hold your device steady", severity: .critical))
            } else if laplacianVar < 80 && overallScore < 50 {
                guidance.append(.init(message: "Image is slightly blurry -- hold still", severity: .warning))
            }
        }

        guidance.sort { lhs, rhs in
            let order: [QualityGuidance.Severity] = [.critical, .warning, .info]
            return (order.firstIndex(of: lhs.severity) ?? 2) < (order.firstIndex(of: rhs.severity) ?? 2)
        }

        return ImageQualityReport(
            laplacianVariance: laplacianVar, meanBrightness: mean,
            contrastStdDev: stdDev, underExposedRatio: underRatio,
            overExposedRatio: overRatio, overallScore: overallScore,
            isTooDark: isTooDark, isTooBright: isTooBright,
            guidanceMessages: guidance
        )
    }

    private func computeLaplacianVariance(_ grayscale: [Float], width: Int, height: Int) -> Float {
        // 4-connected Laplacian kernel: [0,1,0; 1,-4,1; 0,1,0]
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
            isTooDark: false, isTooBright: false, guidanceMessages: []
        )
    }
}
#endif
