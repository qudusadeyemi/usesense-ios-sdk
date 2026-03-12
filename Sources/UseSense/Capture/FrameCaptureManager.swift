#if canImport(AVFoundation)
import AVFoundation
import Foundation

protocol FrameCaptureDelegate: AnyObject {
    func frameCaptureManager(_ manager: FrameCaptureManager, didCapture pixelBuffer: CVPixelBuffer, timestamp: CMTime)
    func frameCaptureManager(_ manager: FrameCaptureManager, didFailWithError error: Error)
}

final class FrameCaptureManager: NSObject, @unchecked Sendable {
    weak var delegate: FrameCaptureDelegate?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.usesense.capture.session")
    private let outputQueue = DispatchQueue(label: "com.usesense.capture.output", qos: .userInitiated)

    private(set) var isRunning = false
    private var isMirrored = false

    /// Cached preview layer – must return the **same** instance every time so the
    /// UIView that hosts it keeps showing the live feed across SwiftUI re-renders.
    private lazy var _previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    var previewLayer: AVCaptureVideoPreviewLayer {
        _previewLayer
    }

    func configure() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .vga640x480

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw UseSenseError(code: .cameraUnavailable, message: "No camera found on this device.")
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(input) else {
            throw UseSenseError(code: .unknownError, message: "Cannot add camera input.")
        }
        captureSession.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            throw UseSenseError(code: .unknownError, message: "Cannot add video output.")
        }
        captureSession.addOutput(videoOutput)

        // Orient frames to portrait and disable mirroring for raw frames
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = false
            isMirrored = false
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
            self.isRunning = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
            self.isRunning = false
        }
    }

    func captureCurrentFrame() -> CVPixelBuffer? {
        return nil // Frames come through delegate
    }
}

extension FrameCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        delegate?.frameCaptureManager(self, didCapture: pixelBuffer, timestamp: timestamp)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Frame dropped, no action needed
    }
}
#endif
