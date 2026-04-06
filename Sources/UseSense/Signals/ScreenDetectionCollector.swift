#if canImport(UIKit) && canImport(Accelerate)
import UIKit
import Foundation
import Accelerate

/// Collects screen detection signals for the channel_integrity.screen_detection metadata.
/// These signals help detect screen replay attacks by analyzing image characteristics
/// that differ between live camera feeds and displayed screen content.
final class ScreenDetectionCollector: @unchecked Sendable {

    struct ScreenDetectionSignals: Sendable {
        /// Width of luminance distribution (0-1). Screens tend to have narrower spread.
        let luminanceHistogramSpread: Double
        /// High-frequency to total energy ratio (0-1). Screens have lower edge energy.
        let edgeEnergyRatio: Double
        /// Coefficient of variation across frames. Screens have very low CV.
        let frameLuminanceCv: Double
        /// How uniform RGB channels are (0-1). Screens show higher uniformity.
        let colorChannelUniformity: Double
    }

    /// Compute screen detection signals from captured frames.
    func collect(frames: [Data], luminances: [Double]) -> ScreenDetectionSignals {
        let histogramSpread = computeHistogramSpread(from: frames.first)
        let edgeEnergy = computeEdgeEnergyRatio(from: frames.first)
        let luminanceCv = computeFrameLuminanceCv(luminances: luminances)
        let colorUniformity = computeColorChannelUniformity(from: frames.first)

        return ScreenDetectionSignals(
            luminanceHistogramSpread: histogramSpread,
            edgeEnergyRatio: edgeEnergy,
            frameLuminanceCv: luminanceCv,
            colorChannelUniformity: colorUniformity
        )
    }

    // MARK: - Luminance Histogram Spread

    private func computeHistogramSpread(from jpegData: Data?) -> Double {
        guard let data = jpegData,
              let image = UIImage(data: data),
              let cgImage = image.cgImage else { return 0.5 }

        let width = min(cgImage.width, 160)
        let height = min(cgImage.height, 120)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Build 256-bin luminance histogram
        var histogram = [Int](repeating: 0, count: 256)
        let totalPixels = width * height

        for i in 0..<totalPixels {
            let offset = i * bytesPerPixel
            let r = Double(pixelData[offset])
            let g = Double(pixelData[offset + 1])
            let b = Double(pixelData[offset + 2])
            let lum = Int(0.299 * r + 0.587 * g + 0.114 * b)
            histogram[min(255, max(0, lum))] += 1
        }

        // Find the 5th and 95th percentile bin indices
        let p5Target = Int(Double(totalPixels) * 0.05)
        let p95Target = Int(Double(totalPixels) * 0.95)
        var cumulative = 0
        var p5 = 0, p95 = 255

        for i in 0..<256 {
            cumulative += histogram[i]
            if cumulative >= p5Target && p5 == 0 { p5 = i }
            if cumulative >= p95Target { p95 = i; break }
        }

        // Spread = range / 255 (0 = very narrow, 1 = full range)
        return Double(p95 - p5) / 255.0
    }

    // MARK: - Edge Energy Ratio

    private func computeEdgeEnergyRatio(from jpegData: Data?) -> Double {
        guard let data = jpegData,
              let image = UIImage(data: data),
              let cgImage = image.cgImage else { return 0.5 }

        let width = min(cgImage.width, 120)
        let height = min(cgImage.height, 90)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert to grayscale and compute Laplacian energy
        var totalEnergy: Double = 0
        var edgeEnergy: Double = 0

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = (y * width + x) * bytesPerPixel
                let center = Double(pixelData[idx])  // Use R channel as proxy
                totalEnergy += center * center

                let top = Double(pixelData[((y-1) * width + x) * bytesPerPixel])
                let bottom = Double(pixelData[((y+1) * width + x) * bytesPerPixel])
                let left = Double(pixelData[(y * width + (x-1)) * bytesPerPixel])
                let right = Double(pixelData[(y * width + (x+1)) * bytesPerPixel])

                let laplacian = top + bottom + left + right - 4 * center
                edgeEnergy += laplacian * laplacian
            }
        }

        guard totalEnergy > 0 else { return 0.5 }
        return min(1.0, edgeEnergy / totalEnergy)
    }

    // MARK: - Frame Luminance CV

    private func computeFrameLuminanceCv(luminances: [Double]) -> Double {
        guard luminances.count >= 2 else { return 0 }

        let mean = luminances.reduce(0, +) / Double(luminances.count)
        guard mean > 1 else { return 0 }

        let variance = luminances.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(luminances.count)
        let stdDev = sqrt(variance)

        return stdDev / mean
    }

    // MARK: - Color Channel Uniformity

    private func computeColorChannelUniformity(from jpegData: Data?) -> Double {
        guard let data = jpegData,
              let image = UIImage(data: data),
              let cgImage = image.cgImage else { return 0.5 }

        let width = min(cgImage.width, 80)
        let height = min(cgImage.height, 60)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let totalPixels = width * height
        var totalR: Double = 0, totalG: Double = 0, totalB: Double = 0

        for i in 0..<totalPixels {
            let offset = i * bytesPerPixel
            totalR += Double(pixelData[offset])
            totalG += Double(pixelData[offset + 1])
            totalB += Double(pixelData[offset + 2])
        }

        let avgR = totalR / Double(totalPixels)
        let avgG = totalG / Double(totalPixels)
        let avgB = totalB / Double(totalPixels)

        let channelMean = (avgR + avgG + avgB) / 3.0
        guard channelMean > 1 else { return 0 }

        let channelVariance = ((avgR - channelMean) * (avgR - channelMean) +
                               (avgG - channelMean) * (avgG - channelMean) +
                               (avgB - channelMean) * (avgB - channelMean)) / 3.0

        // Uniformity: 1 = perfectly uniform channels, 0 = very different
        return max(0, 1.0 - sqrt(channelVariance) / channelMean)
    }
}
#endif
