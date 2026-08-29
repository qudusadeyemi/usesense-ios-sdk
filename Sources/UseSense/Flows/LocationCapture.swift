//
//  LocationCapture.swift
//  UseSense
//
//  Location capture, address ladder rung 0.
//
//  The contract-critical half is kept pure and separate from CoreLocation on
//  purpose. What goes on the wire is a frozen contract that five clients
//  implement independently (see location-capture-contract.md in the watchtower
//  repo), so payload construction is a plain function with its own tests
//  rather than something buried in a delegate callback.
//
//  The governing rule of this whole surface: it never terminates the step in
//  failure. A denied permission, a device that cannot get a fix, Location
//  Services switched off entirely — every one of those still submits the
//  descriptors and advances, at a lower rung. Blocking would abandon exactly
//  the subjects the capture ladder exists to include, and a low-confidence
//  record that can be upgraded is worth more than a failed onboarding.
//

import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// How a subject's position was established, strongest first. Shared
/// vocabulary with the server.
public enum CaptureRung: String, Sendable, Equatable {
    case validatedAutocomplete = "validated_autocomplete"
    case atTheDoor = "at_the_door"
    case passiveInference = "passive_inference"
    case walkTrace = "walk_trace"
    case spokenDescription = "spoken_description"
    case neighbourMatch = "neighbour_match"
    case agentVisit = "agent_visit"
}

/// A position fix as the device reports it.
public struct LocationFix: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    /// Horizontal accuracy in metres, when the device reported a valid one.
    public let accuracyM: Double?
    /// Whether the fix passed hardware attestation and mock-provider checks.
    public let attested: Bool

    public init(latitude: Double, longitude: Double, accuracyM: Double? = nil, attested: Bool = false) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyM = accuracyM
        self.attested = attested
    }
}

/// What the surface knows about the position, for the status line.
public enum LocationCaptureState: String, Sendable, Equatable {
    case idle
    case acquiring
    case ready
    case denied
    case unavailable
}

public enum LocationCapture {

    /// A fix is usable only if both coordinates are in range and it is not
    /// null island.
    ///
    /// `0, 0` means the device failed and reported zeroes. Submitting it would
    /// mint a Place in the Gulf of Guinea inside a registry shared across every
    /// customer, and a poisoned Place propagates to every future subject who
    /// resolves onto it. The server rejects it too; catching it here saves a
    /// pointless round trip and lets the subject retry.
    public static func isUsableFix(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        guard latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 else { return false }
        if latitude == 0 && longitude == 0 { return false }
        return true
    }

    /// Builds the exact `inputs` payload for an advance call.
    ///
    /// Two rules from the contract are enforced here rather than trusted to
    /// the caller. No fix means no coordinates at all and the rung drops to
    /// `spoken_description`, because the descriptors are still worth having
    /// and the rung says precisely what this evidence is. And we never report
    /// a rung higher than we performed.
    public static func buildInputs(
        fix: LocationFix?,
        descriptors: [String: Any],
        requestedRung: CaptureRung?,
        frontageDocumentId: String? = nil
    ) -> [String: Any] {
        var out = descriptors
        if let id = frontageDocumentId, !id.isEmpty {
            out["frontage_document_id"] = id
        }

        guard let fix, isUsableFix(latitude: fix.latitude, longitude: fix.longitude) else {
            out["rung"] = CaptureRung.spokenDescription.rawValue
            return out
        }

        out["latitude"] = fix.latitude
        out["longitude"] = fix.longitude
        if let accuracy = fix.accuracyM, accuracy.isFinite, accuracy >= 0 {
            out["accuracy_m"] = Int(accuracy.rounded())
        }
        out["attested"] = fix.attested
        out["rung"] = (requestedRung ?? .atTheDoor).rawValue
        return out
    }

    /// Human status text for each state.
    ///
    /// The denied and unavailable strings both say the subject can continue,
    /// because they can. Telling them otherwise is how a recoverable moment
    /// becomes an abandoned onboarding.
    public static func statusText(for state: LocationCaptureState, accuracyM: Double? = nil) -> String? {
        switch state {
        case .idle:
            return nil
        case .acquiring:
            return "Finding your location…"
        case .ready:
            if let accuracy = accuracyM, accuracy.isFinite {
                return "Location found, accurate to about \(Int(accuracy.rounded())) m"
            }
            return "Location found"
        case .denied:
            return "Location is off. You can still continue by describing where you live."
        case .unavailable:
            return "We could not get your location. You can still continue below."
        }
    }

    #if canImport(CoreLocation)
    /// Maps an authorization status to the state the surface should show.
    ///
    /// Note what is absent: `.authorizedAlways` is never requested. This
    /// contract covers foreground capture only, and asking for background
    /// location to satisfy it would be both a review risk and a promise we do
    /// not need to make.
    public static func state(for status: CLAuthorizationStatus) -> LocationCaptureState {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return .acquiring
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .idle
        @unknown default:
            return .unavailable
        }
    }

    /// Whether a CoreLocation reading is trustworthy enough to submit as a fix.
    ///
    /// A negative `horizontalAccuracy` is CoreLocation's way of saying the
    /// coordinate is invalid, and it is easy to miss because the struct still
    /// carries plausible-looking numbers.
    public static func isTrustworthy(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        return isUsableFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    /// Turns a CoreLocation reading into a fix.
    ///
    /// `attested` is passed in rather than derived here: App Attest lives in
    /// the device-trust layer and this module stays free of it, so the caller
    /// supplies the verdict. A failed attestation is never a rejection; it
    /// simply records a weaker evidence class, because rejecting it would push
    /// honest subjects on unusual handsets off the ladder.
    public static func fix(from location: CLLocation, attested: Bool) -> LocationFix? {
        guard isTrustworthy(location) else { return nil }
        return LocationFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyM: location.horizontalAccuracy,
            attested: attested
        )
    }
    #endif
}
