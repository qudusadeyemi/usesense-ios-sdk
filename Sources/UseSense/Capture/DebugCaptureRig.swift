#if DEBUG && canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import CoreImage
import UIKit

// MARK: - Debug capture rig (DEBUG builds only; compiled out of release)
//
// Renders the capture screens with no camera, through the real pipeline
// (MediaPipe mesh, quality gate, contour, preview), so they can be compared
// with the capture test kit's goldens. Every option is read from the launch
// arguments (`-USESENSE_FAKE_CAMERA /path/face.mp4`) or the environment:
//
//   USESENSE_FAKE_CAMERA  video (.mp4/.mov) or still image; replaces the camera
//   FREEZE_AT             seconds: seek the video there and hold that frame
//   FORCE_STATE           align | scan | upload: hold the screen in that state
//   FORCE_PROGRESS        0...1: scan ring / upload bar progress when forced
//   FORCE_HINT            centre | dark | closer | ... (reference `?hint=` keys)

enum DebugCaptureRig {
    static func value(_ key: String) -> String? {
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        return nil
    }

    static var fakeCameraPath: String? { value("USESENSE_FAKE_CAMERA") ?? value("USESENSE_SIM_CAMERA") }
    static var freezeAt: Double? { value("FREEZE_AT").flatMap(Double.init) }
    static var forcedProgress: Double? { value("FORCE_PROGRESS").flatMap(Double.init) }

    enum ForcedState: String { case align, scan, upload }
    static var forcedState: ForcedState? { value("FORCE_STATE").flatMap(ForcedState.init(rawValue:)) }

    /// FORCE_HINT (reference `?hint=` keys): pin one instruction.
    static var forcedHint: GateHint? {
        switch value("FORCE_HINT") {
        case "still", "ready": return .holdStill
        case "centre": return .centre
        case "closer": return .moveCloser
        case "back": return .moveBack
        case "straight": return .lookStraight
        case "dark": return .faceALight
        case "bright": return .tooBright
        case "blur": return .holdSteady
        case "eyes": return .eyesOpen
        case "one": return .onePerson
        case "covered": return .uncovered
        case "face": return .showFace
        default: return nil
        }
    }
}

/// Stand-in front camera: frames of a video (looped, 30 fps) or a still image.
final class DebugFakeCamera {
    private let url: URL
    private let isVideo: Bool
    private let freezeAt: Double?
    private var still: CVPixelBuffer?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.usesense.fakecamera", qos: .userInitiated)
    private let ciContext = CIContext()
    private var frame: Int64 = 0
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    init?(path: String, freezeAt: Double?) {
        url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let ext = url.pathExtension.lowercased()
        isVideo = ["mp4", "mov", "m4v"].contains(ext)
        self.freezeAt = freezeAt
        if !isVideo {
            guard let image = UIImage(contentsOfFile: path), let pb = Self.pixelBuffer(from: image) else { return nil }
            still = pb
        }
    }

    func attach(to layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        DispatchQueue.main.async {
            layer.contentsGravity = .resizeAspectFill
            layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))  // mirrored, like the front camera
            layer.masksToBounds = true
        }
    }

    func start(_ deliver: @escaping (CVPixelBuffer, CMTime) -> Void) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in
            guard let self, let buffer = self.nextFrame() else { return }
            self.frame += 1
            self.show(buffer)
            deliver(buffer, CMTime(value: self.frame, timescale: 30))
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Frames

    private func nextFrame() -> CVPixelBuffer? {
        if let still { return still }
        if freezeAt != nil, let current { return current }   // held frame
        if let buffer = readFrame() { current = buffer; return buffer }
        // End of the video: loop.
        reader = nil
        if let buffer = readFrame() { current = buffer }
        return current
    }

    private func readFrame() -> CVPixelBuffer? {
        if reader == nil { openReader() }
        guard let output else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            if let freezeAt, current == nil {
                // Seek: skip until the freeze time, then hold.
                if CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) + 0.001 < freezeAt { continue }
            }
            return pb
        }
        return nil
    }

    private func openReader() {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let r = try? AVAssetReader(asset: asset) else { return }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return }
        r.add(out)
        r.startReading()
        reader = r
        output = out
    }

    private func show(_ buffer: CVPixelBuffer) {
        guard let cg = ciContext.createCGImage(CIImage(cvPixelBuffer: buffer),
                                               from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer),
                                                            height: CVPixelBufferGetHeight(buffer))) else { return }
        DispatchQueue.main.async { [weak self] in self?.previewLayer?.contents = cg }
    }

    private static func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// The frame on screen now (forced upload backdrop).
    func currentImage() -> UIImage? {
        guard let pb = current ?? still else { return nil }
        guard let cg = ciContext.createCGImage(CIImage(cvPixelBuffer: pb),
                                               from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb),
                                                            height: CVPixelBufferGetHeight(pb))) else { return nil }
        return UIImage(cgImage: cg)
    }
}
#endif
