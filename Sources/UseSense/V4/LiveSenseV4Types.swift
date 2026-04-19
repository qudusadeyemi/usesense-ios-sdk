//
//  LiveSenseV4Types.swift
//  UseSense
//
//  Public types for the LiveSense v4 entry point. Phase 1 ticket I-2.
//

import Foundation
import SwiftUI

public struct LiveSenseV4Config {
    public let sessionId: UUID
    public let sessionToken: String
    public let nonce: String
    public let apiBaseURL: URL
    public let environment: String
    public let brandPrimaryColor: Color?
    public let displayName: String?

    public init(
        sessionId: UUID,
        sessionToken: String,
        nonce: String,
        apiBaseURL: URL,
        environment: String = "production",
        brandPrimaryColor: Color? = nil,
        displayName: String? = nil
    ) {
        self.sessionId = sessionId
        self.sessionToken = sessionToken
        self.nonce = nonce
        self.apiBaseURL = apiBaseURL
        self.environment = environment
        self.brandPrimaryColor = brandPrimaryColor
        self.displayName = displayName
    }
}

public struct V4Verdict: Decodable, Equatable {
    public let sessionId: String
    public let verdict: Decision
    public let confidence: Confidence
    public let assuranceLevelAchieved: String
    public let captureChannel: String
    public let matchSenseEmbeddingId: String?
    public let timestamp: String

    public enum Decision: String, Decodable, Equatable {
        case pass, fail, review
    }
    public enum Confidence: String, Decodable, Equatable {
        case high, medium, low
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case verdict, confidence, timestamp
        case assuranceLevelAchieved = "assurance_level_achieved"
        case captureChannel = "capture_channel"
        case matchSenseEmbeddingId = "match_sense_embedding_id"
    }
}

public enum LiveSenseV4Phase: String {
    case framing, zoom, uploading, completing, completed
}

public protocol LiveSenseV4Delegate: AnyObject {
    func sessionDidComplete(verdict: V4Verdict)
    func sessionDidFail(error: Error)
    func sessionPhaseDidChange(phase: LiveSenseV4Phase)
}
