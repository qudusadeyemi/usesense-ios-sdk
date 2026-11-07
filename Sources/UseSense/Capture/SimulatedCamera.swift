#if targetEnvironment(simulator) && canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import UIKit

/// Simulator-only stand-in for the front camera, for development and
/// screenshots: the simulator has no camera. Set the launch environment
/// `USESENSE_SIM_CAMERA` to the path of a portrait photo and the capture
/// pipeline (face mesh, quality gate, scan, contour) runs on that image at
/// 30 fps. Compiled out of device builds entirely.
final class SimulatedCamera {
    static var imagePath: String? {
        ProcessInfo.processInfo.environment["USESENSE_SIM_CAMERA"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private let buffer: CVPixelBuffer
    let image: UIImage
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.usesense.simcamera", qos: .userInitiated)
    private var frame: Int64 = 0

    init?(path: String) {
        guard let image = UIImage(contentsOfFile: path), let cg = image.cgImage else { return nil }
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
        self.buffer = pb
        self.image = image
    }

    /// Show the photo in the preview layer the way the front camera would
    /// (aspect fill, mirrored).
    func attach(to layer: AVCaptureVideoPreviewLayer) {
        DispatchQueue.main.async {
            layer.contents = self.image.cgImage
            layer.contentsGravity = .resizeAspectFill
            layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        }
    }

    func start(_ deliver: @escaping (CVPixelBuffer, CMTime) -> Void) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.frame += 1
            deliver(self.buffer, CMTime(value: self.frame, timescale: 30))
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
#endif
