// Hand-written stub for first-time MediaPipe bundled-asset integration in Phase 3.
// Future updates land here automatically via the mediapipe-sdk-sync workflow
// in qudusadeyemi/usesense-watchtower, which overwrites this file with content
// generated from .github/mediapipe-sync-templates/MediaPipeModelInfo.swift.tmpl.
//
// Source:    https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
// Synced at: 2026-04-10T08:50:00Z (initial Phase 3 bootstrap, no sync run yet)
// Watchtower commit: bootstrap

import Foundation

/// Constants describing the MediaPipe FaceLandmarker model bundled with this SDK.
/// Kept in sync with usesense-watchtower's canonical manifest by the
/// mediapipe-sdk-sync workflow. Do not modify by hand.
public enum MediaPipeModelInfo {

    /// Upstream version path segment, e.g. "float16/1".
    public static let version: String = "float16/1"

    /// SHA-256 of the bundled face_landmarker.task bytes.
    /// The mediapipe-parity-check CI job verifies bundled bytes hash to this value.
    public static let sha256: String = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"

    /// Size of the bundled face_landmarker.task in bytes.
    public static let sizeBytes: Int = 3758596

    /// Upstream URL the canonical bytes were originally fetched from.
    /// Recorded for audit and provenance.
    public static let sourceUrl: String = "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"

    /// CDN URL for the canonical bytes (informational on iOS, used by web SDK).
    public static let cdnUrl: String = "https://cdn.usesense.ai/mediapipe/face_landmarker/64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff/face_landmarker.task"

    /// Bundle resource name as registered by SwiftPM .process("Resources") and the
    /// CocoaPods resource_bundle 'UseSenseSDK'. Use Bundle.module.url(forResource:
    /// withExtension:) to get the on-disk path MediaPipe FaceLandmarker expects via
    /// FaceLandmarkerOptions.baseOptions.modelAssetPath.
    public static let resourceName: String = "face_landmarker"
    public static let resourceExtension: String = "task"

    /// Stable identifier for upload payloads and observability.
    /// Format: "mediapipe_face_landmarker@<short-sha>"
    public static let versionLabel: String = "mediapipe_face_landmarker@64184e22"
}
