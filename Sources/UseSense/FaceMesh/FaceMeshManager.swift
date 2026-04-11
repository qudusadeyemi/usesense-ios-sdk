#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit
import Foundation

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif

/// Per-frame face mesh data extracted from MediaPipe FaceLandmarker.
struct FaceMeshResult: Sendable {
    let frameIndex: Int
    let timestampMs: Int64
    let headPose: HeadPose
    let leftEAR: Double
    let rightEAR: Double
    let bbox: NormalizedRect
    let landmarks: [(x: Double, y: Double, z: Double)]
}

struct HeadPose: Sendable {
    let yaw: Double
    let pitch: Double
    let roll: Double
}

struct NormalizedRect: Sendable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

/// Manages MediaPipe FaceLandmarker integration for on-device face mesh extraction.
/// Runs on a background queue to avoid blocking the capture loop.
///
/// The face_landmarker.task model is bundled in the SwiftPM module's Resources
/// directory and the CocoaPods resource_bundle 'UseSenseSDK', managed by the
/// mediapipe-sdk-sync workflow in qudusadeyemi/usesense-watchtower. See
/// MediaPipeModelInfo for the bundled bytes' version, sha256, and provenance.
///
/// MediaPipeTasksVision is a CocoaPods-only dependency. Google does not ship
/// MediaPipeTasksVision as a Swift Package, so SwiftPM consumers get the
/// gracefully-degraded code path (no face mesh signals). Both code paths
/// also gracefully degrade when the bundled asset is missing (e.g. between
/// this PR landing and the first sync run delivering bytes).
final class FaceMeshManager: @unchecked Sendable {
    private let analysisQueue = DispatchQueue(label: "com.usesense.facemesh", qos: .userInitiated)
    private var isReady = false
    /// Monotonic counter of successful `processFrame` calls since the
    /// last `reset()`. Stamped into the `frameIndex` field of the returned
    /// `FaceMeshResult` for telemetry/logging, but NOT the index used by
    /// the verification package — that one is the upload-aligned position
    /// assigned in `recordResult(_:)` below. See the docstring on
    /// `recordResult` for the full story.
    private var cameraFrameCounter: Int = 0
    private let lock = NSLock()
    private var results: [FaceMeshResult] = []

    #if canImport(MediaPipeTasksVision)
    private var landmarker: FaceLandmarker?
    #endif

    /// Initialize MediaPipe FaceLandmarker model.
    /// Loads face_landmarker.task from the bundled Resources directory via
    /// Bundle.useSenseResources (cross-toolchain: Bundle.module on SwiftPM,
    /// nested UseSenseSDK.bundle lookup on CocoaPods). Falls back to no face
    /// mesh signals if MediaPipeTasksVision is not linked (SwiftPM build) or
    /// if the bundled asset is missing (gap before the first sync run).
    func setup() {
        analysisQueue.async { [weak self] in
            guard let self = self else { return }
            #if canImport(MediaPipeTasksVision)
            do {
                guard let modelURL = Bundle.useSenseResources.url(
                    forResource: MediaPipeModelInfo.resourceName,
                    withExtension: MediaPipeModelInfo.resourceExtension
                ) else {
                    // Bundled asset not present yet (sync workflow has not run).
                    // SDK gracefully degrades to no face mesh signals.
                    self.isReady = false
                    return
                }
                let options = FaceLandmarkerOptions()
                options.baseOptions.modelAssetPath = modelURL.path
                options.runningMode = .image
                options.numFaces = 1
                options.outputFacialTransformationMatrixes = true
                self.landmarker = try FaceLandmarker(options: options)
                self.isReady = true
            } catch {
                // FaceLandmarker initialization failed (corrupt bytes, unsupported
                // device, etc.). SDK gracefully degrades to no face mesh signals.
                self.isReady = false
            }
            #else
            // MediaPipeTasksVision not linked (SwiftPM build).
            // SDK gracefully degrades to no face mesh signals.
            self.isReady = false
            #endif
        }
    }

    /// Process a camera frame and extract face mesh data.
    ///
    /// Called from the capture delegate on EVERY camera frame that arrives
    /// during a session (the face guide stage as well as active capture),
    /// so the suspicion engine can consume per-frame telemetry. The
    /// returned result is NOT automatically recorded into the internal
    /// results array used by the verification package — the caller must
    /// explicitly pass it to `recordResult(_:)` for frames that are
    /// also being buffered to the JPEG upload buffer. See the docstring
    /// on `recordResult` for why.
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestampMs: Int64) -> FaceMeshResult? {
        guard isReady else { return nil }

        guard let landmarkData = extractLandmarks(pixelBuffer) else { return nil }

        let pose = estimateHeadPose(from: landmarkData)
        let leftEAR = computeEAR(landmarks: landmarkData, eye: .left)
        let rightEAR = computeEAR(landmarks: landmarkData, eye: .right)
        let bbox = computeBoundingBox(from: landmarkData)

        lock.lock()
        let cameraIndex = cameraFrameCounter
        cameraFrameCounter += 1
        lock.unlock()

        return FaceMeshResult(
            frameIndex: cameraIndex,
            timestampMs: timestampMs,
            headPose: pose,
            leftEAR: leftEAR,
            rightEAR: rightEAR,
            bbox: bbox,
            landmarks: landmarkData
        )
    }

    /// Record a `FaceMeshResult` from `processFrame(...)` into the
    /// internal results array that the verification package reads from
    /// via `getResults()`.
    ///
    /// The caller (FrameCaptureDelegate in UseSenseSession) MUST only
    /// call this for frames that are ALSO being buffered into the JPEG
    /// frame buffer in the same delegate callback, so that
    /// `meshResults[i]` and `frameHashes[i]` are guaranteed to be the
    /// same camera frame after VerificationPackageBuilder zips them by
    /// index. Without that guarantee, the mesh data in verification
    /// package frame `i` is cryptographically bound (via `bindingProof`)
    /// to a JPEG captured from a DIFFERENT camera frame — which is
    /// internally consistent on the wire (the HMAC still verifies
    /// against the same inputs the SDK signed) but semantically wrong.
    ///
    /// The `frameIndex` field of the stored result is reassigned to
    /// the upload-aligned position (`results.count` at record time),
    /// not preserved from the `processFrame` return value. This makes
    /// `results[i].frameIndex == i` an invariant, which is what the
    /// downstream verification package builder and the backend
    /// validator both expect after usesense-ios-sdk#28 (the frameIndex
    /// one-liner).
    func recordResult(_ result: FaceMeshResult) {
        lock.lock()
        let uploadIndex = results.count
        let recorded = FaceMeshResult(
            frameIndex: uploadIndex,
            timestampMs: result.timestampMs,
            headPose: result.headPose,
            leftEAR: result.leftEAR,
            rightEAR: result.rightEAR,
            bbox: result.bbox,
            landmarks: result.landmarks
        )
        results.append(recorded)
        lock.unlock()
    }

    func getResults() -> [FaceMeshResult] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }

    func reset() {
        lock.lock()
        results.removeAll()
        cameraFrameCounter = 0
        lock.unlock()
    }

    func teardown() {
        isReady = false
        #if canImport(MediaPipeTasksVision)
        landmarker = nil
        #endif
        reset()
    }

    // MARK: - Landmark Extraction

    private func extractLandmarks(_ pixelBuffer: CVPixelBuffer) -> [(x: Double, y: Double, z: Double)]? {
        #if canImport(MediaPipeTasksVision)
        guard let landmarker = self.landmarker else { return nil }
        do {
            let mpImage = try MPImage(pixelBuffer: pixelBuffer)
            let result = try landmarker.detect(image: mpImage)
            guard let firstFace = result.faceLandmarks.first, firstFace.count >= 468 else {
                return nil
            }
            return firstFace.map { lm in
                (x: Double(lm.x), y: Double(lm.y), z: Double(lm.z))
            }
        } catch {
            return nil
        }
        #else
        // MediaPipeTasksVision not linked; no landmarks available.
        return nil
        #endif
    }

    // MARK: - Head Pose Estimation

    /// Extract yaw/pitch/roll from MediaPipe's landmark output.
    private func estimateHeadPose(from landmarks: [(x: Double, y: Double, z: Double)]) -> HeadPose {
        guard landmarks.count >= 468 else {
            return HeadPose(yaw: 0, pitch: 0, roll: 0)
        }

        // Key landmarks for pose: nose tip (1), chin (152), left eye outer (33), right eye outer (263)
        let noseTip = landmarks[1]
        let chin = landmarks[152]
        let leftEyeOuter = landmarks[33]
        let rightEyeOuter = landmarks[263]

        // Yaw: horizontal displacement of nose relative to eye midpoint
        let eyeMidX = (leftEyeOuter.x + rightEyeOuter.x) / 2.0
        let yaw = (noseTip.x - eyeMidX) * 180.0

        // Pitch: vertical displacement of nose relative to eye-chin midpoint
        let eyeMidY = (leftEyeOuter.y + rightEyeOuter.y) / 2.0
        let faceMidY = (eyeMidY + chin.y) / 2.0
        let pitch = (noseTip.y - faceMidY) * 180.0

        // Roll: tilt of eye line
        let dx = rightEyeOuter.x - leftEyeOuter.x
        let dy = rightEyeOuter.y - leftEyeOuter.y
        let roll = atan2(dy, dx) * 180.0 / .pi

        return HeadPose(yaw: yaw, pitch: pitch, roll: roll)
    }

    // MARK: - Eye Aspect Ratio

    private enum EyeSide { case left, right }

    /// EAR = (|p2-p6| + |p3-p5|) / (2 * |p1-p4|)
    private func computeEAR(landmarks: [(x: Double, y: Double, z: Double)], eye: EyeSide) -> Double {
        guard landmarks.count >= 468 else { return 0.35 }

        // MediaPipe landmark indices for eyes
        let indices: (p1: Int, p2: Int, p3: Int, p4: Int, p5: Int, p6: Int)
        switch eye {
        case .left:
            indices = (33, 160, 158, 133, 153, 144)
        case .right:
            indices = (362, 385, 387, 263, 373, 380)
        }

        let p1 = landmarks[indices.p1]
        let p2 = landmarks[indices.p2]
        let p3 = landmarks[indices.p3]
        let p4 = landmarks[indices.p4]
        let p5 = landmarks[indices.p5]
        let p6 = landmarks[indices.p6]

        let vertA = distance(p2, p6)
        let vertB = distance(p3, p5)
        let horiz = distance(p1, p4)

        guard horiz > 0 else { return 0.35 }
        return (vertA + vertB) / (2.0 * horiz)
    }

    private func distance(_ a: (x: Double, y: Double, z: Double), _ b: (x: Double, y: Double, z: Double)) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Bounding Box

    private func computeBoundingBox(from landmarks: [(x: Double, y: Double, z: Double)]) -> NormalizedRect {
        guard !landmarks.isEmpty else {
            return NormalizedRect(x: 0, y: 0, w: 0, h: 0)
        }
        let xs = landmarks.map(\.x)
        let ys = landmarks.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        return NormalizedRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }
}
#endif
