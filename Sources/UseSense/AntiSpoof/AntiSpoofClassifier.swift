// ============================================================================
// AntiSpoofClassifier -- On-device EfficientNet-B0 spoof detection (v4.2)
// ============================================================================
//
// Runs the CelebA-Spoof antispoof classifier against captured face frames.
// Feature-flagged behind UseSenseConfig.options.antispoofOnDeviceEnabled.
// When the flag is off (default in v4.2), the classifier is not loaded and
// the watchtower backend runs the classifier server-side.
//
// Scope for v4.2 (ready but disabled):
//   - CoreML .mlpackage loading from app bundle or Resources
//   - Bounding-box crop + ImageNet normalisation (matches server preprocessing)
//   - Per-frame softmax spoof probability
//   - Emits OnDeviceClassifierSample records through the shared samples store
//
// The SDK produces a .mlpackage named `antispoof.mlpackage` alongside the
// MediaPipe assets. When the artifact is missing the classifier no-ops -- the
// server path stays authoritative.
// ============================================================================

#if canImport(CoreML) && canImport(UIKit) && canImport(Vision)
import Foundation
import CoreML
import UIKit
import Vision

public struct OnDeviceClassifierSample: Codable, Sendable {
    public let frameIndex: Int
    public let spoofProbability: Double
    public let latencyMs: Int
    public let modelVersion: String
    public let backbone: String

    public init(frameIndex: Int, spoofProbability: Double, latencyMs: Int, modelVersion: String, backbone: String) {
        self.frameIndex = frameIndex
        self.spoofProbability = spoofProbability
        self.latencyMs = latencyMs
        self.modelVersion = modelVersion
        self.backbone = backbone
    }
}

public final class AntiSpoofClassifier: @unchecked Sendable {

    // MARK: - Config

    private static let inputSize: Int = 224
    private static let modelBackbone = "efficientnet_b0"
    // Must be `public` so it can be the default value of the `public init`'s
    // modelVersion parameter below (Swift requires the default value's source
    // to be at least as visible as the function it's attached to).
    public static let defaultModelVersion = "v1"
    private static let bboxExpansion: CGFloat = 1.25   // 25% margin around face crop

    // MARK: - State

    private let modelVersion: String
    private let model: VNCoreMLModel?
    private let loadError: Error?

    // MARK: - Init

    /// Loads the bundled antispoof model. If `enabled` is false or the artifact
    /// is missing, the classifier enters no-op mode and `predict()` returns nil.
    public init(enabled: Bool, modelVersion: String = AntiSpoofClassifier.defaultModelVersion) {
        self.modelVersion = modelVersion
        guard enabled else {
            self.model = nil
            self.loadError = nil
            return
        }
        do {
            let url = try AntiSpoofClassifier.locateModel(version: modelVersion)
            let compiled = try MLModel.compileModel(at: url)
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try MLModel(contentsOf: compiled, configuration: config)
            self.model = try VNCoreMLModel(for: mlModel)
            self.loadError = nil
        } catch {
            self.model = nil
            self.loadError = error
        }
    }

    public var isAvailable: Bool { model != nil }
    public var availabilityError: Error? { loadError }

    // MARK: - Public API

    /// Runs inference on `image` within the supplied face bounding box.
    /// `boundingBox` is in normalised [0,1] image coordinates (Vision convention:
    /// origin bottom-left). Returns nil when the classifier is disabled or the
    /// crop is invalid. Safe to call on a background queue.
    public func predict(
        image: UIImage,
        frameIndex: Int,
        boundingBox: CGRect
    ) -> OnDeviceClassifierSample? {
        guard let model else { return nil }
        guard let cgImage = image.cgImage else { return nil }

        let start = Date()

        // Convert Vision normalised bbox (bottom-left origin) to pixel rect
        // (top-left origin) and expand by margin, clamped to image bounds.
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let cx = (boundingBox.origin.x + boundingBox.width / 2) * w
        let cy = (1.0 - (boundingBox.origin.y + boundingBox.height / 2)) * h
        let side = max(boundingBox.width * w, boundingBox.height * h) * Self.bboxExpansion
        let left = max(0, cx - side / 2)
        let top = max(0, cy - side / 2)
        let right = min(w, cx + side / 2)
        let bottom = min(h, cy + side / 2)
        guard right > left, bottom > top else { return nil }
        let cropRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let logits = observation.featureValue.multiArrayValue else {
            return nil
        }

        let probs = Self.softmax2(logits)
        let spoof = probs.spoof
        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        return OnDeviceClassifierSample(
            frameIndex: frameIndex,
            spoofProbability: spoof,
            latencyMs: latencyMs,
            modelVersion: modelVersion,
            backbone: Self.modelBackbone
        )
    }

    // MARK: - Helpers

    private static func locateModel(version: String) throws -> URL {
        // 1. App-private caches dir (OTA-updated artifact)
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let otaUrl = caches
                .appendingPathComponent("UseSense", isDirectory: true)
                .appendingPathComponent("antispoof", isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("antispoof.mlpackage")
            if FileManager.default.fileExists(atPath: otaUrl.path) {
                return otaUrl
            }
        }

        // 2. Framework bundle (shipped with the SDK binary)
        let candidates: [Bundle?] = [
            Bundle(for: AntiSpoofClassifier.self),
            Bundle.main,
            Bundle.useSenseResourceBundle
        ]
        for bundle in candidates {
            if let url = bundle?.url(forResource: "antispoof", withExtension: "mlpackage") {
                return url
            }
            if let url = bundle?.url(forResource: "antispoof", withExtension: "mlmodelc") {
                return url
            }
        }

        throw AntiSpoofClassifierError.modelNotFound
    }

    private static func softmax2(_ arr: MLMultiArray) -> (live: Double, spoof: Double) {
        // Model output is shape [1, 2] or [2]. Classes: [live, spoof] per training.
        let count = arr.count
        guard count >= 2 else { return (1.0, 0.0) }

        let live = arr[count - 2].doubleValue
        let spoof = arr[count - 1].doubleValue
        let m = max(live, spoof)
        let eLive = exp(live - m)
        let eSpoof = exp(spoof - m)
        let denom = eLive + eSpoof
        guard denom > 0 else { return (1.0, 0.0) }
        return (eLive / denom, eSpoof / denom)
    }
}

public enum AntiSpoofClassifierError: Error {
    case modelNotFound
    case inferenceFailed
}

// MARK: - Bundle helper

private extension Bundle {
    static var useSenseResourceBundle: Bundle? {
        // Match the FaceMesh resource bundle convention.
        guard let url = Bundle(for: AntiSpoofClassifier.self)
            .url(forResource: "UseSense_UseSense", withExtension: "bundle") else {
            return nil
        }
        return Bundle(url: url)
    }
}

#else

// Non-iOS platforms: stub that never produces samples.
public struct OnDeviceClassifierSample: Codable, Sendable {
    public let frameIndex: Int
    public let spoofProbability: Double
    public let latencyMs: Int
    public let modelVersion: String
    public let backbone: String
}

public final class AntiSpoofClassifier: @unchecked Sendable {
    public init(enabled: Bool, modelVersion: String = "v1") {}
    public var isAvailable: Bool { false }
    public var availabilityError: Error? { nil }
}

#endif
