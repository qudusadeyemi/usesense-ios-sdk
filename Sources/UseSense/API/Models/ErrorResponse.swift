import Foundation

struct ErrorResponse: Decodable {
    let error: ErrorDetail
}

struct ErrorDetail: Decodable {
    let code: String
    let message: String
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case code, message
        case requestId = "request_id"
    }
}
