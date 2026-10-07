import Foundation

struct UploadSignalsResponse: Decodable {
    let received: Bool
    let sessionId: String
    let framesCount: Int
    let audioReceived: Bool
    let metadataReceived: Bool
    let totalSizeBytes: Int?
    /// Present when a server Step-up rule matched round 1.
    let stepUp: StepUpPayload?

    enum CodingKeys: String, CodingKey {
        case received
        case sessionId = "session_id"
        case framesCount = "frames_count"
        case audioReceived = "audio_received"
        case metadataReceived = "metadata_received"
        case totalSizeBytes = "total_size_bytes"
        case stepUp = "step_up"
    }

    // Tolerant: a round-2 response has no audio_received, and an unreadable
    // step_up must never fail the upload itself.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        received = (try? c.decodeIfPresent(Bool.self, forKey: .received)) ?? true
        sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        framesCount = (try? c.decodeIfPresent(Int.self, forKey: .framesCount)) ?? 0
        audioReceived = (try? c.decodeIfPresent(Bool.self, forKey: .audioReceived)) ?? false
        metadataReceived = (try? c.decodeIfPresent(Bool.self, forKey: .metadataReceived)) ?? false
        totalSizeBytes = try? c.decodeIfPresent(Int.self, forKey: .totalSizeBytes)
        stepUp = try? c.decodeIfPresent(StepUpPayload.self, forKey: .stepUp)
    }
}
