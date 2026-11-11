import Foundation

// MARK: - copy.capture (BRAND-v1 section 5)
//
// Every capture string a person sees, keyed as in the brand contract. Each
// key is optional; a missing or blank value keeps the SDK's shipped English
// (the defaults live next to each use, byte-identical to before).
// Placeholders: `{app}` = the resolved display name, else the host app's
// name; `{side}` = "to the left", "to the right", "up" or "down", as the SDK
// words it. Unknown placeholders render literally.
//
// Keys iOS adds beyond the contract list (report to the other platforms):
//   primer.twoStepsDigitsBody
//   guidance.helpTitle, guidance.helpBody
//   extraCheck.pausedTurnSide ({side}), pausedLookCentre (as Android), keepFollowing, dotWaits, pointAtDot, thenSayNumbers,
//     cantHear, speakLouder, retryStep, slowly, further,
//     helpTitle, helpHeadTurn, helpFollowDot, helpSpeakDigits
//   result.retryTips (array)
//   errors.cameraTitle, cameraBody (the "Getting ready" camera request)
//   loading.title (the "Getting ready" screen)

public struct CaptureCopy: Codable, Equatable, Sendable {
    public var primer: Primer?
    public var guidance: Guidance?
    public var extraCheck: ExtraCheck?
    public var upload: Upload?
    public var result: Result?
    public var errors: Errors?
    public var leave: Leave?
    public var loading: Loading?

    public init(primer: Primer? = nil, guidance: Guidance? = nil, extraCheck: ExtraCheck? = nil,
                upload: Upload? = nil, result: Result? = nil, errors: Errors? = nil,
                leave: Leave? = nil, loading: Loading? = nil) {
        self.primer = primer; self.guidance = guidance; self.extraCheck = extraCheck
        self.upload = upload; self.result = result; self.errors = errors
        self.leave = leave; self.loading = loading
    }

    public struct Primer: Codable, Equatable, Sendable {
        public var selfieTitle: String?
        public var selfieBody: String?
        public var selfieTips: [String]?
        public var start: String?
        public var cancel: String?
        public var twoStepsTitle: String?
        public var twoStepsBody: String?
        /// iOS addition: the two-steps body when the check is Speak Digits.
        public var twoStepsDigitsBody: String?
        public var twoStepsTips: [String]?
        public init() {}
    }

    public struct Guidance: Codable, Equatable, Sendable {
        /// Shown while every check passes ("Hold still").
        public var ready: String?
        public var centre: String?
        public var closer: String?
        public var back: String?
        public var straight: String?
        public var dark: String?
        public var darkHint: String?
        public var bright: String?
        public var brightHint: String?
        public var blur: String?
        public var eyes: String?
        public var onePerson: String?
        public var showFace: String?
        public var covered: String?
        /// The stillness check's hint ("Hold still").
        public var holdStill: String?
        public var shutterHint: String?
        public var helpTitle: String?
        public var helpBody: String?
        public init() {}
    }

    public struct ExtraCheck: Codable, Equatable, Sendable {
        public var sheetTitle: String?
        /// The sheet's sentence for every check; `{side}` = the first side asked.
        public var sheetBody: String?
        public var `continue`: String?
        /// Head Turn step title; `{side}` = the side asked.
        public var headTurn: String?
        public var followDot: String?
        public var speakDigits: String?
        public var lookCentre: String?
        public var tryNext: String?
        public var done: String?
        /// Paused Head Turn detail; `{side}` = the side asked.
        public var pausedTurnSide: String?
        /// Paused on the centre step.
        public var pausedLookCentre: String?
        public var keepFollowing: String?
        public var dotWaits: String?
        public var pointAtDot: String?
        public var thenSayNumbers: String?
        public var cantHear: String?
        public var speakLouder: String?
        public var retryStep: String?
        public var slowly: String?
        /// Retry hint; `{side}` = the side asked.
        public var further: String?
        public var helpTitle: String?
        public var helpHeadTurn: String?
        public var helpFollowDot: String?
        public var helpSpeakDigits: String?
        public init() {}
    }

    public struct Upload: Codable, Equatable, Sendable {
        public var title: String?
        public var caption: String?
        public var failedTitle: String?
        public var failedBody: String?
        public var retry: String?
        public init() {}
    }

    public struct Result: Codable, Equatable, Sendable {
        public var approvedTitle: String?
        public var approvedBody: String?
        public var reviewTitle: String?
        public var reviewBody: String?
        public var rejectedTitle: String?
        public var rejectedBody: String?
        public var retryTitle: String?
        public var retryBody: String?
        public var retryTips: [String]?
        public var done: String?
        public var tryAgain: String?
        public var notNow: String?
        public init() {}
    }

    public struct Errors: Codable, Equatable, Sendable {
        public var cameraDeniedTitle: String?
        public var cameraDeniedBody: String?
        public var openSettings: String?
        public var cameraStoppedTitle: String?
        public var cameraStoppedBody: String?
        public var micTitle: String?
        public var micBody: String?
        public var useHeadMovement: String?
        public var offlineTitle: String?
        public var offlineBody: String?
        public var expiredTitle: String?
        public var expiredBody: String?
        public var startAgain: String?
        public var errorTitle: String?
        public var errorBody: String?
        /// iOS addition: the camera request before the system prompt.
        public var cameraTitle: String?
        public var cameraBody: String?
        public var allowCamera: String?
        public var tryAgain: String?
        public init() {}
    }

    public struct Leave: Codable, Equatable, Sendable {
        public var title: String?
        public var body: String?
        public var leave: String?
        public var keepGoing: String?
        public init() {}
    }

    /// iOS addition: the "Getting ready" screen.
    public struct Loading: Codable, Equatable, Sendable {
        public var title: String?
        public init() {}
    }

    /// Lenient: a malformed group is dropped, not the whole copy.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primer = (try? c.decodeIfPresent(Primer.self, forKey: .primer)) ?? nil
        guidance = (try? c.decodeIfPresent(Guidance.self, forKey: .guidance)) ?? nil
        extraCheck = (try? c.decodeIfPresent(ExtraCheck.self, forKey: .extraCheck)) ?? nil
        upload = (try? c.decodeIfPresent(Upload.self, forKey: .upload)) ?? nil
        result = (try? c.decodeIfPresent(Result.self, forKey: .result)) ?? nil
        errors = (try? c.decodeIfPresent(Errors.self, forKey: .errors)) ?? nil
        leave = (try? c.decodeIfPresent(Leave.self, forKey: .leave)) ?? nil
        loading = (try? c.decodeIfPresent(Loading.self, forKey: .loading)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case primer, guidance, extraCheck, upload, result, errors, leave, loading
    }
}

// MARK: - Merge

public extension CaptureCopy {
    /// Field by field: a non-blank `high` value wins, else `low` shows
    /// through. A blank string, or a list with no non-blank entry, is unset.
    static func merge(high: CaptureCopy?, low: CaptureCopy?) -> CaptureCopy? {
        guard let high else { return low }
        guard let low else { return high }
        guard let h = jsonObject(high), let l = jsonObject(low) else { return high }
        let merged = deepMerge(h, l)
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let out = try? JSONDecoder().decode(CaptureCopy.self, from: data) else { return high }
        return out
    }

    private static func jsonObject(_ c: CaptureCopy) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(c) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isSet(_ v: Any) -> Bool {
        if let s = v as? String { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let a = v as? [Any] { return a.contains(where: isSet) }
        return true
    }

    private static func deepMerge(_ high: [String: Any], _ low: [String: Any]) -> [String: Any] {
        var out = low
        for (k, hv) in high {
            if let hd = hv as? [String: Any] {
                out[k] = deepMerge(hd, (low[k] as? [String: Any]) ?? [:])
            } else if isSet(hv) {
                out[k] = hv
            }
        }
        return out
    }
}

// MARK: - Lookup

/// Resolves a capture string: the non-blank override (placeholders filled),
/// else the shipped default (returned as is).
enum CaptureText {
    static func text(_ key: KeyPath<FlowCopy, String?>, _ fallback: String, side: String? = nil) -> String {
        guard let raw = FlowCopyResolver.current?[keyPath: key] else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : fill(trimmed, side: side)
    }

    static func list(_ key: KeyPath<FlowCopy, [String]?>, _ fallback: [String]) -> [String] {
        let items = (FlowCopyResolver.current?[keyPath: key] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return items.isEmpty ? fallback : items.map { fill($0, side: nil) }
    }

    /// `{app}` and `{side}`; anything else in braces stays literal.
    static func fill(_ s: String, side: String?) -> String {
        var out = s.replacingOccurrences(of: "{app}", with: appName)
        if let side { out = out.replacingOccurrences(of: "{side}", with: side) }
        return out
    }

    /// `{app}`: the resolved display name, else the host app's name.
    static var appName: String {
        if let name = FlowCopyResolver.displayName { return name }
        let info = Bundle.main.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return "the app"
    }
}
