//
//  LiveSenseV4Session.swift
//  UseSense
//
//  End-to-end orchestrator for a v4 verification session on iOS.
//  Phase 1 ticket I-2.
//
//  Coordinates: AVCaptureSession at 1280x720 / 30fps with locked
//  exposure/WB, Vision face detection feeding ZoomMotionController,
//  HashChainBuilder per captured frame, V4ChainSigner on the terminal,
//  multipart upload with chain metadata, POST /v1/sessions/:id/result
//  for the opaque verdict.
//
//  NOTE: This class is the integration surface. Full device-verify
//  required on iPhone 13+, iPhone 15, and iPhone SE (camera stability,
//  Secure Enclave presence, reduce-motion handling).
//

import Foundation
import AVFoundation
import Vision
import CoreMedia
import CoreVideo
import CryptoKit
import UIKit

public final class LiveSenseV4Session: NSObject {
    public let config: LiveSenseV4Config
    public weak var delegate: LiveSenseV4Delegate?

    private let motion: ZoomMotionController
    private var signer: V4ChainSigner?
    private var chain: HashChainBuilder
    private let encoder: VideoEncoder
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.usesense.v4.capture")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var device: AVCaptureDevice?
    private var frameIndex: Int = 0
    private var faceRequest: VNDetectFaceRectanglesRequest?
    private var started = false
    private var stopped = false

    public init(config: LiveSenseV4Config, delegate: LiveSenseV4Delegate? = nil) {
        self.config = config
        self.delegate = delegate
        self.motion = ZoomMotionController()
        self.chain = HashChainBuilder(sessionToken: config.sessionToken)
        self.encoder = VideoEncoder()
        super.init()
        self.motion.delegate = self
    }

    /// Start the camera and capture loop. Call from the main thread.
    public func start() throws {
        guard !started else { return }
        started = true
        try configureCamera()
        try encoder.start()
        signer = try V4ChainSigner(sessionId: config.sessionId.uuidString)
        captureSession.startRunning()
        motion.start()
        delegate?.sessionPhaseDidChange(phase: .framing)
    }

    /// Cancel the capture if the user backs out mid-flow.
    public func cancel() {
        stopCapture(dispatchPhase: false)
    }

    // MARK: - Camera

    private func configureCamera() throws {
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw NSError(domain: "UseSense", code: -1001,
                          userInfo: [NSLocalizedDescriptionKey: "No front camera"])
        }
        self.device = cam
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device: cam)
        if captureSession.canAddInput(input) { captureSession.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(output) { captureSession.addOutput(output) }
        self.videoOutput = output

        if let conn = output.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = true }
        }
        captureSession.commitConfiguration()

        // Try to lock the device at 30fps with explicit frame duration.
        try cam.lockForConfiguration()
        defer { cam.unlockForConfiguration() }
        let desired = CMTime(value: 1, timescale: 30)
        cam.activeVideoMinFrameDuration = desired
        cam.activeVideoMaxFrameDuration = desired
        // Lock exposure and white balance for the capture window.
        if cam.isExposureModeSupported(.locked) { cam.exposureMode = .locked }
        if cam.isWhiteBalanceModeSupported(.locked) { cam.whiteBalanceMode = .locked }

        self.faceRequest = VNDetectFaceRectanglesRequest()
    }

    // MARK: - Lifecycle on motion events

    fileprivate func handleZoomComplete() {
        guard !stopped else { return }
        stopped = true
        captureSession.stopRunning()
        delegate?.sessionPhaseDidChange(phase: .uploading)
        Task { await self.finishAndUpload() }
    }

    fileprivate func handleZoomFailure(reason: ZoomFailureReason) {
        stopCapture(dispatchPhase: false)
        let err = NSError(
            domain: "UseSense.v4", code: -2001,
            userInfo: [NSLocalizedDescriptionKey: "zoom_failed:\(reason.rawValue)"]
        )
        delegate?.sessionDidFail(error: err)
    }

    private func stopCapture(dispatchPhase: Bool) {
        guard !stopped else { return }
        stopped = true
        captureSession.stopRunning()
        if dispatchPhase { delegate?.sessionPhaseDidChange(phase: .completed) }
    }

    // MARK: - Upload

    private func finishAndUpload() async {
        do {
            let mp4 = try await encoder.finish()

            let terminal = try chain.terminal()
            let terminalHex = try chain.terminalHex()
            guard let signer = self.signer else {
                throw NSError(domain: "UseSense.v4", code: -2002,
                              userInfo: [NSLocalizedDescriptionKey: "no signer"])
            }
            let sig = try signer.sign(terminal: terminal)
            let sigB64 = V4ChainSigner.base64UrlEncode(sig)
            let pkSpki = try signer.exportPublicKeySpkiBase64Url()

            let verdict = try await V4UploadClient.upload(
                config: config,
                mp4: mp4,
                frameHashes: chain.frameHashes(),
                terminalHashHex: terminalHex,
                signatureB64: sigB64,
                publicKeySpkiB64: pkSpki,
                assuranceLevel: signer.assuranceLevel,
                stats: motion.stats()
            )
            delegate?.sessionPhaseDidChange(phase: .completed)
            delegate?.sessionDidComplete(verdict: verdict)
        } catch {
            delegate?.sessionDidFail(error: error)
        }
    }
}

// MARK: - Video sample buffer -> motion observations + chain

extension LiveSenseV4Session: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !stopped else { return }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        try? encoder.appendPixelBuffer(pixel, at: pts)

        // Frame -> JPEG bytes for chain + upload fallback.
        if let jpegData = Self.pixelBufferToJpeg(pixel) {
            _ = chain.append(frameBytes: jpegData)
            frameIndex += 1
        }

        // Face detection for motion observations.
        guard let faceRequest = faceRequest else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .leftMirrored, options: [:])
        try? handler.perform([faceRequest])
        if let obs = (faceRequest.results as? [VNFaceObservation])?.first {
            let rect = obs.boundingBox
            let timestampMs = CACurrentMediaTime() * 1000.0
            let yaw = (obs.yaw?.doubleValue ?? 0) * 180.0 / .pi
            let pitch = (obs.pitch?.doubleValue ?? 0) * 180.0 / .pi
            let roll = (obs.roll?.doubleValue ?? 0) * 180.0 / .pi
            let bbox = FaceBoundingBox(
                cx: Double(rect.midX), cy: Double(rect.midY),
                w: Double(rect.width), h: Double(rect.height)
            )
            motion.observe(ZoomObservation(
                timestampMs: timestampMs,
                bbox: bbox,
                headPose: HeadPoseDegrees(yaw: yaw, pitch: pitch, roll: roll)
            ))
        }
    }

    private static func pixelBufferToJpeg(_ buffer: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: buffer)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        let img = UIImage(cgImage: cg)
        return img.jpegData(compressionQuality: 0.9)
    }
}

extension LiveSenseV4Session: ZoomMotionControllerDelegate {
    public func zoomMotionDidTransition(
        next: ZoomState,
        prev: ZoomState,
        stats: ZoomMotionStats,
        failure: ZoomFailureReason?
    ) {
        switch next {
        case .moving:
            delegate?.sessionPhaseDidChange(phase: .zoom)
        case .complete:
            handleZoomComplete()
        case .failed:
            handleZoomFailure(reason: failure ?? .timeout)
        default:
            break
        }
    }
}
