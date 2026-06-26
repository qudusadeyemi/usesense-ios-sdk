#if canImport(UIKit)
import UIKit

// MARK: - DocumentQuality
//
// Client-side document quality check, ported from the hosted page's
// assessDocumentQuality (frontend/.../document-quality.ts) with the same metrics
// and calibrated thresholds: variance-of-Laplacian (sharpness), mean luma, and
// source short-side. Returns the highest-priority issue, or nil if the capture
// looks fine. Never throws — a decode failure returns nil so we don't block.

public struct DocumentQualityIssue: Equatable {
    public let code: String
    public let title: String
    public let detail: String
}

public enum DocumentQuality {
    private static let workingW = 320
    private static let blurVarianceThreshold = 1000.0
    private static let darkLuma = 55.0
    private static let brightLuma = 245.0
    private static let minShortSide = 500

    public static func assess(_ image: UIImage) -> DocumentQualityIssue? {
        guard let cg = image.cgImage else { return nil }
        let natW = cg.width
        let natH = cg.height
        guard natW > 0, natH > 0 else { return nil }
        let shortSide = min(natW, natH)

        let w = workingW
        let h = max(1, Int((Double(workingW) * Double(natH) / Double(natW)).rounded()))
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var gray = [Double](repeating: 0, count: w * h)
        var lumaSum = 0.0
        for i in 0..<(w * h) {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            let v = 0.299 * r + 0.587 * g + 0.114 * b
            gray[i] = v
            lumaSum += v
        }
        let meanLuma = lumaSum / Double(w * h)

        // Variance of Laplacian over interior pixels.
        var s = 0.0, s2 = 0.0, n = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = 4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - w] - gray[i + w]
                s += lap
                s2 += lap * lap
                n += 1
            }
        }
        let sharpness = n > 0 ? s2 / Double(n) - (s / Double(n)) * (s / Double(n)) : 9999

        // Priority: lighting first (most actionable), then size, then sharpness.
        if meanLuma < darkLuma {
            return DocumentQualityIssue(code: "too_dark", title: "Too dark", detail: "Find brighter, even lighting and try again.")
        }
        if meanLuma > brightLuma {
            return DocumentQualityIssue(code: "too_bright", title: "Too bright", detail: "Move out of direct light or reduce glare.")
        }
        if shortSide < minShortSide {
            return DocumentQualityIssue(code: "low_res", title: "Image looks small", detail: "Capture at a higher resolution so the text is readable.")
        }
        if sharpness < blurVarianceThreshold {
            return DocumentQualityIssue(code: "blurry", title: "Photo may be unclear", detail: "Make sure all details are sharp and readable.")
        }
        return nil
    }
}
#endif
