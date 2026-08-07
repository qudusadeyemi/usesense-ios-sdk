#if canImport(AVFoundation) && canImport(UIKit) && canImport(CryptoKit)
import AVFoundation
import UIKit
import Foundation
import CryptoKit

final class FrameBuffer: @unchecked Sendable {
    /// Capture phase tag attached to each frame. Used by the v4 perspective
    /// validator (SfM bundle adjustment requires a coherent zoom motion;
    /// head_turn or framing frames are noise).
    enum CapturePhase: String {
        case framing
        case baseline
        case zoom
        case challenge
        case other
    }

    private var frames: [(data: Data, timestamp: TimeInterval, hash: String, luminance: Double, phase: String, width: Int, height: Int)] = []
    private let lock = NSLock()
    private var maxFrames: Int
    private var targetFps: Int
    private var lastCaptureTime: CFAbsoluteTime = 0
    private var captureInterval: TimeInterval
    private var currentPhase: CapturePhase = .other

    init(maxFrames: Int = 30, targetFps: Int = 3) {
        self.maxFrames = maxFrames
        self.targetFps = targetFps
        self.captureInterval = 1.0 / Double(targetFps)
    }

    /// Update the phase that subsequently captured frames will be tagged with.
    /// Safe to call from any thread.
    func setCapturePhase(_ phase: CapturePhase) {
        lock.lock()
        defer { lock.unlock() }
        currentPhase = phase
    }

    /// Re-configure with server-provided limits (called after session creation).
    func reconfigure(maxFrames: Int, targetFps: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.maxFrames = maxFrames
        self.targetFps = targetFps
        self.captureInterval = 1.0 / Double(targetFps)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    var isFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.count >= maxFrames
    }

    func shouldCapture() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCaptureTime >= captureInterval else { return false }
        lastCaptureTime = now
        return true
    }

    func addFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        // Compute luminance BEFORE JPEG encoding (lightweight ~0.1ms)
        let luminance = computeLuminance(pixelBuffer)

        guard let encoded = jpegEncode(pixelBuffer) else { return }

        // SHA-256 hash of raw JPEG bytes (REQUIRED per spec). Hashed after the
        // downscale, so it covers exactly the bytes that go on the wire.
        let hash = SHA256.hash(data: encoded.data).map { String(format: "%02x", $0) }.joined()

        lock.lock()
        defer { lock.unlock() }
        guard frames.count < maxFrames else { return }
        frames.append((data: encoded.data, timestamp: timestamp, hash: hash, luminance: luminance,
                       phase: currentPhase.rawValue, width: encoded.width, height: encoded.height))
    }

    /// Encoded (post-downscale) pixel size of each captured frame.
    ///
    /// The frames_manifest used to report a hardcoded 1280x720 regardless of
    /// what was actually captured or sent. The server scales its sharpness
    /// thresholds off this, so a wrong value scores frames against the wrong
    /// ruler.
    func getResolutions() -> [(width: Int, height: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return frames.map { (width: $0.width, height: $0.height) }
    }

    func getFrames() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return frames.map { $0.data }
    }

    func getTimestamps() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return frames.map { $0.timestamp }
    }

    /// Get SHA-256 hex hashes of all captured frames.
    func getFrameHashes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return frames.map { $0.hash }
    }

    /// Get per-frame luminance values for Suspicion Engine input.
    func getFrameLuminances() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return frames.map { $0.luminance }
    }

    /// Get per-frame capture-phase tags for the v4 SfM frame filter.
    func getFramePhases() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return frames.map { $0.phase }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
        lastCaptureTime = 0
    }

    // MARK: - JPEG Encoding

    /// Longest-edge cap for encoded frames.
    ///
    /// The capture session runs at `.high` (1080x1920 on modern iPhones) and
    /// frames used to be JPEG-encoded at that full size: 30 frames measured
    /// 12.9 MB per session in production, roughly five times the web SDK. On a
    /// mobile uplink that cannot finish inside any sane timeout.
    ///
    /// 960 matches MAX_FRAME_LONG_EDGE in the web SDK and the calibration table
    /// in the server's screen-replay-detector.tsx. It was chosen by measuring
    /// 198 real frames through the pipeline: face matching is unaffected, and
    /// the binding constraint is Rekognition's sharpness score, which stays
    /// clear of the screen-replay ceiling at 960 but not below it.
    ///
    /// Keep all three in step.
    static let maxFrameLongEdge: CGFloat = 960

    private let ciContext = CIContext()

    private func jpegEncode(
        _ pixelBuffer: CVPixelBuffer,
        quality: CGFloat = 0.80
    ) -> (data: Data, width: Int, height: Int)? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        let longEdge = max(extent.width, extent.height)

        // Lanczos rather than the default affine resample: a soft downscale
        // reads as lost sharpness to the server's screen-replay detector, which
        // is the one signal this change can actually hurt.
        let scaled: CIImage
        if longEdge > Self.maxFrameLongEdge, longEdge > 0 {
            let scale = Self.maxFrameLongEdge / longEdge
            if let filter = CIFilter(name: "CILanczosScaleTransform") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(scale, forKey: kCIInputScaleKey)
                filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
                scaled = filter.outputImage ?? ciImage.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale))
            } else {
                scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        } else {
            scaled = ciImage
        }

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: quality) else { return nil }
        return (data: data, width: cgImage.width, height: cgImage.height)
    }

    // MARK: - Luminance Computation

    /// Compute average luminance for a frame.
    /// Downscale to 64x48, compute: avg(0.299*R + 0.587*G + 0.114*B)
    /// Used by Suspicion Engine for screen replay detection.
    private func computeLuminance(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 128.0 }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Downsample to 64x48 for fast computation
        let targetW = 64
        let targetH = 48
        let scaleX = Double(width) / Double(targetW)
        let scaleY = Double(height) / Double(targetH)

        var totalLuminance: Double = 0
        let totalPixels = targetW * targetH

        for y in 0..<targetH {
            let srcY = min(Int(Double(y) * scaleY), height - 1)
            for x in 0..<targetW {
                let srcX = min(Int(Double(x) * scaleX), width - 1)
                let offset = srcY * bytesPerRow + srcX * 4
                let b = Double(ptr[offset])
                let g = Double(ptr[offset + 1])
                let r = Double(ptr[offset + 2])
                totalLuminance += 0.299 * r + 0.587 * g + 0.114 * b
            }
        }

        return totalLuminance / Double(totalPixels)
    }
}
#endif
