#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit

protocol FrameCaptureDelegate: AnyObject {
    func frameCaptureManager(_ manager: FrameCaptureManager, didCaptureFrame data: Data, index: Int, timestampMs: Int)
    func frameCaptureManagerDidReachFrameLimit(_ manager: FrameCaptureManager)
}

final class FrameCaptureManager: NSObject, @unchecked Sendable {
    weak var delegate: FrameCaptureDelegate?

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.usesense.capture", qos: .userInteractive)
    private let encodingQueue = DispatchQueue(label: "com.usesense.encode", qos: .userInitiated)

    private var isCapturing = false
    private var frameCount = 0
    private var maxFrames: Int = 30
    private var captureInterval: TimeInterval = 0.5
    private var lastCaptureTime: CFAbsoluteTime = 0
    private var captureStartTime: CFAbsoluteTime = 0

    private lazy var ciContext = CIContext()

    var previewLayer: AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return layer
    }

    func configure() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            throw UseSenseError.cameraUnavailable()
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Non-mirrored raw frames for upload
        if let connection = videoOutput.connection(with: .video) {
            connection.isVideoMirrored = false
            connection.videoOrientation = .portrait
        }
    }

    func setCaptureParameters(maxFrames: Int, targetFps: Int) {
        self.maxFrames = maxFrames
        self.captureInterval = 1.0 / Double(targetFps)
    }

    func startPreview() {
        captureQueue.async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    func stopPreview() {
        captureQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    func startCapture() {
        frameCount = 0
        captureStartTime = CFAbsoluteTimeGetCurrent()
        lastCaptureTime = 0
        isCapturing = true
    }

    func stopCapture() {
        isCapturing = false
    }

    var currentFrameCount: Int { frameCount }

    private func encodeToJPEG(_ sampleBuffer: CMSampleBuffer, quality: CGFloat = 0.82) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}

extension FrameCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isCapturing else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastCaptureTime

        guard elapsed >= captureInterval, frameCount < maxFrames else { return }

        lastCaptureTime = now
        let index = frameCount
        frameCount += 1
        let timestampMs = Int((now - captureStartTime) * 1000)

        encodingQueue.async { [weak self] in
            guard let self = self, let data = self.encodeToJPEG(sampleBuffer) else { return }
            self.delegate?.frameCaptureManager(self, didCaptureFrame: data, index: index, timestampMs: timestampMs)
            if self.frameCount >= self.maxFrames {
                self.delegate?.frameCaptureManagerDidReachFrameLimit(self)
            }
        }
    }
}
#endif
