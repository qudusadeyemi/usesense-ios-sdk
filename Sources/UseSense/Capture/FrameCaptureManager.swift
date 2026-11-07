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
    /// configure() runs once per manager. A retry calls it again, and adding a
    /// second input for the same camera fails ("Cannot add camera input."),
    /// which turned every "Try again" into a camera error.
    private var isConfigured = false
    private var camera: AVCaptureDevice?
    private var lastPointOfInterest: CGPoint?

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
        if isConfigured { return }
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Spec: use native camera resolution, do NOT downscale. Server handles analysis.
        captureSession.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw UseSenseError(code: .cameraUnavailable, message: "No camera found on this device.")
        }

        self.camera = camera
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
        isConfigured = true
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

    /// Focus and expose on the face instead of the frame centre, so a bright
    /// window behind the user doesn't darken the face and focus is the
    /// camera's job, not the user's. `devicePoint` is in capture-device
    /// coordinates (`AVCaptureVideoPreviewLayer.captureDevicePointConverted`).
    /// Small moves are ignored to avoid hunting.
    func setPointOfInterest(_ devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.camera else { return }
            if let last = self.lastPointOfInterest,
               hypot(last.x - devicePoint.x, last.y - devicePoint.y) < 0.04 { return }
            let p = CGPoint(x: min(1, max(0, devicePoint.x)), y: min(1, max(0, devicePoint.y)))
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = p
                    if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                }
                if camera.isExposurePointOfInterestSupported {
                    camera.exposurePointOfInterest = p
                    if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
                }
                if camera.isSubjectAreaChangeMonitoringEnabled == false {
                    camera.isSubjectAreaChangeMonitoringEnabled = true
                }
                self.lastPointOfInterest = p
            } catch {
                // Focus is best effort; the gate still judges sharpness.
            }
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
