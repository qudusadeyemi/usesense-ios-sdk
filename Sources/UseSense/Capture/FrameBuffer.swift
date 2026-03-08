#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit
import Foundation

final class FrameBuffer: @unchecked Sendable {
    private var frames: [(data: Data, timestamp: TimeInterval)] = []
    private let lock = NSLock()
    private let maxFrames: Int
    private let targetFps: Int
    private var lastCaptureTime: CFAbsoluteTime = 0
    private let captureInterval: TimeInterval

    init(maxFrames: Int = 40, targetFps: Int = 15) {
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
        guard let jpegData = jpegEncode(pixelBuffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard frames.count < maxFrames else { return }
        frames.append((data: jpegData, timestamp: timestamp))
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

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
        lastCaptureTime = 0
    }

    private func jpegEncode(_ pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.82) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: quality)
    }
}
#endif
