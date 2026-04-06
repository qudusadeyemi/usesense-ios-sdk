#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit
import Foundation

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
final class FaceMeshManager: @unchecked Sendable {
    private let analysisQueue = DispatchQueue(label: "com.usesense.facemesh", qos: .userInitiated)
    private var isReady = false
    private var frameIndex: Int = 0
    private let lock = NSLock()
    private var results: [FaceMeshResult] = []

    /// Initialize MediaPipe FaceLandmarker model.
    /// In production, this loads the face_landmarker.task model.
    func setup() {
        analysisQueue.async { [weak self] in
            // MediaPipe FaceLandmarker initialization:
            // let options = FaceLandmarkerOptions()
            // options.baseOptions.modelAssetPath = "face_landmarker.task"
            // options.runningMode = .liveStream
            // options.numFaces = 1
            // options.outputFacialTransformationMatrixes = true
            // self?.landmarker = try? FaceLandmarker(options: options)
            self?.isReady = true
        }
    }

    /// Process a camera frame and extract face mesh data.
    /// Called from the capture delegate on each frame during active capture.
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestampMs: Int64) -> FaceMeshResult? {
        guard isReady else { return nil }

        lock.lock()
        let index = frameIndex
        frameIndex += 1
        lock.unlock()

        // Extract landmarks from MediaPipe FaceLandmarker.
        // When MediaPipe pod is integrated, this calls:
        //   let mpImage = MPImage(pixelBuffer: pixelBuffer)
        //   let result = try landmarker.detect(image: mpImage)
        // For now, return nil until MediaPipe dependency is added.
        guard let landmarkData = extractLandmarks(pixelBuffer) else { return nil }

        let pose = estimateHeadPose(from: landmarkData)
        let leftEAR = computeEAR(landmarks: landmarkData, eye: .left)
        let rightEAR = computeEAR(landmarks: landmarkData, eye: .right)
        let bbox = computeBoundingBox(from: landmarkData)

        let result = FaceMeshResult(
            frameIndex: index,
            timestampMs: timestampMs,
            headPose: pose,
            leftEAR: leftEAR,
            rightEAR: rightEAR,
            bbox: bbox,
            landmarks: landmarkData
        )

        lock.lock()
        results.append(result)
        lock.unlock()

        return result
    }

    func getResults() -> [FaceMeshResult] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }

    func reset() {
        lock.lock()
        results.removeAll()
        frameIndex = 0
        lock.unlock()
    }

    func teardown() {
        isReady = false
        reset()
    }

    // MARK: - Landmark Extraction

    private func extractLandmarks(_ pixelBuffer: CVPixelBuffer) -> [(x: Double, y: Double, z: Double)]? {
        // Placeholder: MediaPipe FaceLandmarker returns 468 3D landmarks.
        // Integration requires adding MediaPipeTasksVision pod dependency.
        // Returns nil until dependency is configured.
        return nil
    }

    // MARK: - Head Pose Estimation

    /// Extract yaw/pitch/roll from MediaPipe's FacialTransformationMatrix.
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
