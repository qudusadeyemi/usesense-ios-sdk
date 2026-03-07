import Foundation

struct UploadSignalsResponse: Decodable {
    let received: Bool
    let sessionId: String
    let framesCount: Int
    let audioReceived: Bool
    let metadataReceived: Bool
    let totalSizeBytes: Int?

    enum CodingKeys: String, CodingKey {
        case received
        case sessionId = "session_id"
        case framesCount = "frames_count"
        case audioReceived = "audio_received"
        case metadataReceived = "metadata_received"
        case totalSizeBytes = "total_size_bytes"
    }
}
