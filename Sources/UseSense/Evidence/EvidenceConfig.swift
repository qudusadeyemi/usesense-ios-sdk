import Foundation

/// The optional `evidence` block of a session-create response (EVIDENCE-v1
/// section 1). The server says what Phase 2 evidence to collect; the SDK
/// collects it and the server scores it.
///
/// Decoding is lenient on purpose (a strict decoder broke Shuttlers on
/// 2026-06-22): every key is optional, unknown keys are ignored, a malformed
/// key reads as absent, and a `contract` other than "evidence-v1" makes the
/// whole block absent. Old servers never send it.
public struct EvidenceConfig: Codable, Sendable, Equatable {
    public static let contractV1 = "evidence-v1"

    public struct ColourSequence: Codable, Sendable, Equatable {
        public let id: String
        /// `#RRGGBB`, uppercased. Played in this order; never reordered or cached.
        public let colours: [String]
        public let segmentMs: Int
        public let leadInMs: Int
        public let opacity: Double

        enum CodingKeys: String, CodingKey {
            case id, colours, opacity
            case segmentMs = "segment_ms"
            case leadInMs = "lead_in_ms"
        }

        public init(id: String, colours: [String], segmentMs: Int = 600, leadInMs: Int = 300, opacity: Double = 0.35) {
            self.id = id
            self.colours = colours
            self.segmentMs = segmentMs
            self.leadInMs = leadInMs
            self.opacity = opacity
        }

        /// Defaults are the server's (evidence-contract.ts). A sequence with no
        /// id or no valid colour is not playable and fails the decode, which the
        /// parent turns into "no colour sequence".
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let id = c.lenientString(.id)
            let raw = (try? c.decodeIfPresent([String].self, forKey: .colours)) ?? []
            let colours = raw.compactMap(Self.normalised)
            guard !id.isEmpty, !colours.isEmpty, colours.count == raw.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "unplayable colour sequence"))
            }
            self.id = id
            self.colours = colours
            let segment = (try? c.decodeIfPresent(Int.self, forKey: .segmentMs)) ?? nil
            let leadIn = (try? c.decodeIfPresent(Int.self, forKey: .leadInMs)) ?? nil
            let opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? nil
            segmentMs = min(2000, max(100, segment ?? 600))
            leadInMs = min(2000, max(0, leadIn ?? 300))
            self.opacity = min(1, max(0.05, opacity ?? 0.35))
        }

        /// `#rrggbb` -> `#RRGGBB`; anything else -> nil.
        static func normalised(_ s: String) -> String? {
            let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
            return "#" + hex.uppercased()
        }

        /// Lead-in plus every segment.
        public var totalMs: Int { leadInMs + segmentMs * colours.count }
    }

    public struct CloserStep: Codable, Sendable, Equatable {
        public let enabled: Bool
        public let targetScale: Double
        public let minScale: Double

        enum CodingKeys: String, CodingKey {
            case enabled
            case targetScale = "target_scale"
            case minScale = "min_scale"
        }

        public init(enabled: Bool, targetScale: Double = 1.4, minScale: Double = 1.25) {
            self.enabled = enabled
            self.targetScale = targetScale
            self.minScale = minScale
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.lenientBool(.enabled)
            let target = (try? c.decodeIfPresent(Double.self, forKey: .targetScale)) ?? nil
            let minimum = (try? c.decodeIfPresent(Double.self, forKey: .minScale)) ?? nil
            targetScale = min(2, max(1.05, target ?? 1.4))
            minScale = min(targetScale, max(1.05, minimum ?? 1.25))
        }
    }

    public let contract: String
    public let colourSequence: ColourSequence?
    public let closerStep: CloserStep?
    public let bindingV2Enabled: Bool
    public let landmarksRequired: Bool

    enum CodingKeys: String, CodingKey {
        case contract
        case colourSequence = "colour_sequence"
        case closerStep = "closer_step"
        case bindingV2 = "binding_v2"
        case landmarks
    }

    private struct Flag: Codable {
        let enabled: Bool?
        let required: Bool?
    }

    public init(colourSequence: ColourSequence? = nil, closerStep: CloserStep? = nil,
                bindingV2Enabled: Bool = false, landmarksRequired: Bool = false) {
        contract = Self.contractV1
        self.colourSequence = colourSequence
        self.closerStep = closerStep
        self.bindingV2Enabled = bindingV2Enabled
        self.landmarksRequired = landmarksRequired
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contract = c.lenientString(.contract)
        guard contract == Self.contractV1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "unsupported evidence contract"))
        }
        colourSequence = (try? c.decodeIfPresent(ColourSequence.self, forKey: .colourSequence)) ?? nil
        closerStep = (try? c.decodeIfPresent(CloserStep.self, forKey: .closerStep)) ?? nil
        let binding = (try? c.decodeIfPresent(Flag.self, forKey: .bindingV2)) ?? nil
        bindingV2Enabled = binding?.enabled ?? false
        let landmarks = (try? c.decodeIfPresent(Flag.self, forKey: .landmarks)) ?? nil
        landmarksRequired = landmarks?.required ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contract, forKey: .contract)
        try c.encodeIfPresent(colourSequence, forKey: .colourSequence)
        try c.encodeIfPresent(closerStep, forKey: .closerStep)
        try c.encode(Flag(enabled: bindingV2Enabled, required: nil), forKey: .bindingV2)
        try c.encode(Flag(enabled: nil, required: landmarksRequired), forKey: .landmarks)
    }

    /// The colour sequence to play, if any.
    var playableColours: ColourSequence? { colourSequence }
    /// Whether to run the closer step.
    var closerEnabled: Bool { closerStep?.enabled == true }
}

extension KeyedDecodingContainer {
    /// The `evidence` block, or nil when absent, malformed or another contract.
    func lenientEvidence(_ key: Key) -> EvidenceConfig? {
        (try? decodeIfPresent(EvidenceConfig.self, forKey: key)) ?? nil
    }
}
