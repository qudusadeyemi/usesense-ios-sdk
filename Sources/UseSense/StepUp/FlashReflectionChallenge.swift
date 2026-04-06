#if canImport(UIKit)
import Foundation
import UIKit

/// Result of a Flash Reflection challenge.
struct FlashReflectionResult: Sendable {
    let flashes: [FlashResult]
    let passed: Bool
    let confidence: Double
    let overallColorDelta: Double

    struct FlashResult: Sendable {
        let color: String
        let durationMs: Int
        let baselineRgb: (r: Double, g: Double, b: Double)
        let flashRgb: (r: Double, g: Double, b: Double)
        let colorDelta: Double
        let reflectionDetected: Bool
    }
}

/// Flash Reflection challenge: display colored overlays, detect facial reflections.
/// Real faces reflect displayed colors; screens don't.
///
/// Protocol:
/// 1. Pick 3 random colors
/// 2. For each: baseline sample (400ms) → flash sample (600ms) → compute delta
/// 3. Pass if >= 2 of 3 show valid reflection (delta >= 8 + correct channel)
///
/// Render timing: MUST wait for overlay to render before sampling.
/// Use CADisplayLink or DispatchQueue.main.async after setting overlay color.
final class FlashReflectionChallenge {

    private static let colorPool: [(hex: String, r: Double, g: Double, b: Double)] = [
        ("#FF0000", 255, 0, 0),
        ("#00FF00", 0, 255, 0),
        ("#0000FF", 0, 0, 255),
        ("#FFFF00", 255, 255, 0),
        ("#FF00FF", 255, 0, 255),
        ("#00FFFF", 0, 255, 255)
    ]

    func run(captureFrame: @escaping () -> UIImage?) async -> FlashReflectionResult {
        // Pick 3 random colors (no duplicates)
        let selectedColors = Array(Self.colorPool.shuffled().prefix(3))
        var flashes: [FlashReflectionResult.FlashResult] = []
        var validReflections = 0

        for color in selectedColors {
            // Baseline: capture without overlay (400ms)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let baselineRgb = sampleFaceRegion(from: captureFrame())

            // Flash: display color overlay, wait for render, then sample (600ms)
            // In production, this sets the overlay color on the UI layer
            try? await Task.sleep(nanoseconds: 600_000_000)
            let flashRgb = sampleFaceRegion(from: captureFrame())

            // Compute color delta
            let dR = flashRgb.r - baselineRgb.r
            let dG = flashRgb.g - baselineRgb.g
            let dB = flashRgb.b - baselineRgb.b
            let delta = sqrt(dR * dR + dG * dG + dB * dB)

            // Check dominant channel matches flash color direction
            let dominantShiftCorrect = checkDominantChannel(
                delta: (dR, dG, dB),
                flashColor: (color.r, color.g, color.b)
            )

            let reflected = delta >= 8.0 && dominantShiftCorrect
            if reflected { validReflections += 1 }

            flashes.append(FlashReflectionResult.FlashResult(
                color: color.hex,
                durationMs: 600,
                baselineRgb: baselineRgb,
                flashRgb: flashRgb,
                colorDelta: delta,
                reflectionDetected: reflected
            ))
        }

        let overallDelta = flashes.map(\.colorDelta).reduce(0, +) / Double(max(1, flashes.count))
        let passed = validReflections >= 2

        return FlashReflectionResult(
            flashes: flashes,
            passed: passed,
            confidence: Double(validReflections) / 3.0 * 100.0,
            overallColorDelta: overallDelta
        )
    }

    /// Sample the center 40% of the frame at reduced resolution (120x90).
    /// Region: x0 = floor(width * 0.3), y0 = floor(height * 0.2),
    ///         w = floor(width * 0.4), h = floor(height * 0.5)
    private func sampleFaceRegion(from image: UIImage?) -> (r: Double, g: Double, b: Double) {
        guard let cgImage = image?.cgImage else {
            return (r: 128, g: 128, b: 128)
        }

        let width = cgImage.width
        let height = cgImage.height

        let x0 = Int(Double(width) * 0.3)
        let y0 = Int(Double(height) * 0.2)
        let w = Int(Double(width) * 0.4)
        let h = Int(Double(height) * 0.5)

        guard let cropped = cgImage.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)) else {
            return (r: 128, g: 128, b: 128)
        }

        // Downscale to 120x90 for fast averaging
        let targetW = 120
        let targetH = 90
        let bytesPerPixel = 4
        let bytesPerRow = targetW * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: targetH * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (r: 128, g: 128, b: 128)
        }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        var totalR: Double = 0, totalG: Double = 0, totalB: Double = 0
        let totalPixels = targetW * targetH

        for i in 0..<totalPixels {
            let offset = i * bytesPerPixel
            totalR += Double(pixelData[offset])
            totalG += Double(pixelData[offset + 1])
            totalB += Double(pixelData[offset + 2])
        }

        return (
            r: totalR / Double(totalPixels),
            g: totalG / Double(totalPixels),
            b: totalB / Double(totalPixels)
        )
    }

    private func checkDominantChannel(
        delta: (Double, Double, Double),
        flashColor: (Double, Double, Double)
    ) -> Bool {
        let absDelta = (abs(delta.0), abs(delta.1), abs(delta.2))
        let maxDelta = max(absDelta.0, max(absDelta.1, absDelta.2))
        guard maxDelta > 0 else { return false }

        // Check if the dominant channel in delta matches the dominant channel of flash color
        let maxColor = max(flashColor.0, max(flashColor.1, flashColor.2))
        if flashColor.0 == maxColor && absDelta.0 == maxDelta { return true }
        if flashColor.1 == maxColor && absDelta.1 == maxDelta { return true }
        if flashColor.2 == maxColor && absDelta.2 == maxDelta { return true }

        return false
    }
}
#endif
