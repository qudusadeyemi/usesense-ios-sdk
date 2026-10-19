import XCTest
@testable import UseSenseSDK

/// Tests for location capture (address ladder rung 0).
///
/// These guard a frozen wire contract that five clients implement
/// independently, so they assert the exact payload rather than "something
/// reasonable". The rule that matters most is that no failure path terminates
/// the step: a denied permission still submits and still advances.
final class LocationCaptureTests: XCTestCase {

    private let lagos = LocationFix(latitude: 6.4281, longitude: 3.4219, accuracyM: 24, attested: true)
    private let descriptors: [String: Any] = ["street_name": "Adeola Odeku Street", "locality": "Victoria Island"]

    // MARK: - Usable fix

    func testAcceptsANormalCoordinate() {
        XCTAssertTrue(LocationCapture.isUsableFix(latitude: 6.4281, longitude: 3.4219))
    }

    func testRejectsNullIsland() {
        // The device failed and reported zeroes. Submitting it would mint a
        // Place in the Gulf of Guinea inside a registry shared across every
        // customer, and a poisoned Place reaches every future subject who
        // resolves onto it.
        XCTAssertFalse(LocationCapture.isUsableFix(latitude: 0, longitude: 0))
    }

    func testRejectsOutOfRangeAndNonFinite() {
        XCTAssertFalse(LocationCapture.isUsableFix(latitude: 91, longitude: 3))
        XCTAssertFalse(LocationCapture.isUsableFix(latitude: 6, longitude: 181))
        XCTAssertFalse(LocationCapture.isUsableFix(latitude: .nan, longitude: 3.4219))
        XCTAssertFalse(LocationCapture.isUsableFix(latitude: .infinity, longitude: 3.4219))
    }

    // MARK: - Payload

    func testSendsCoordinateAccuracyAttestationAndRung() {
        let out = LocationCapture.buildInputs(fix: lagos, descriptors: descriptors, requestedRung: .atTheDoor)
        XCTAssertEqual(out["latitude"] as? Double, 6.4281)
        XCTAssertEqual(out["longitude"] as? Double, 3.4219)
        XCTAssertEqual(out["accuracy_m"] as? Int, 24)
        XCTAssertEqual(out["attested"] as? Bool, true)
        XCTAssertEqual(out["rung"] as? String, "at_the_door")
        XCTAssertEqual(out["street_name"] as? String, "Adeola Odeku Street")
    }

    func testRoundsAccuracyToWholeMetres() {
        let fix = LocationFix(latitude: 6.4281, longitude: 3.4219, accuracyM: 23.7419)
        let out = LocationCapture.buildInputs(fix: fix, descriptors: [:], requestedRung: nil)
        XCTAssertEqual(out["accuracy_m"] as? Int, 24)
    }

    func testOmitsAccuracyWhenTheDeviceDidNotReportOne() {
        let fix = LocationFix(latitude: 6.4281, longitude: 3.4219, accuracyM: nil)
        let out = LocationCapture.buildInputs(fix: fix, descriptors: [:], requestedRung: nil)
        XCTAssertNil(out["accuracy_m"])
    }

    func testDefaultsTheRungWhenTheStepDidNotNameOne() {
        let out = LocationCapture.buildInputs(fix: lagos, descriptors: [:], requestedRung: nil)
        XCTAssertEqual(out["rung"] as? String, "at_the_door")
    }

    func testCarriesTheFrontagePhotoWhenThereIsOne() {
        let out = LocationCapture.buildInputs(
            fix: lagos, descriptors: [:], requestedRung: .atTheDoor, frontageDocumentId: "doc_1"
        )
        XCTAssertEqual(out["frontage_document_id"] as? String, "doc_1")
    }

    func testUnattestedIsSubmittedRatherThanRejected() {
        // An unattested fix is a weaker evidence class, not a failure.
        // Rejecting it would push honest subjects on unusual handsets off the
        // ladder entirely.
        let fix = LocationFix(latitude: 6.4281, longitude: 3.4219, accuracyM: 30, attested: false)
        let out = LocationCapture.buildInputs(fix: fix, descriptors: [:], requestedRung: .atTheDoor)
        XCTAssertEqual(out["attested"] as? Bool, false)
        XCTAssertEqual(out["rung"] as? String, "at_the_door")
    }

    // MARK: - No position is not a failure

    func testNoFixSubmitsDescriptorsAloneAtALowerRung() {
        let out = LocationCapture.buildInputs(fix: nil, descriptors: descriptors, requestedRung: .atTheDoor)
        XCTAssertNil(out["latitude"])
        XCTAssertNil(out["longitude"])
        XCTAssertEqual(out["rung"] as? String, "spoken_description")
        XCTAssertEqual(out["locality"] as? String, "Victoria Island")
    }

    func testNullIslandIsTreatedAsNoFixAtAll() {
        let fix = LocationFix(latitude: 0, longitude: 0, accuracyM: 5)
        let out = LocationCapture.buildInputs(fix: fix, descriptors: [:], requestedRung: .atTheDoor)
        XCTAssertNil(out["latitude"])
        XCTAssertEqual(out["rung"] as? String, "spoken_description")
    }

    func testNeverClaimsARungHigherThanItPerformed() {
        let out = LocationCapture.buildInputs(fix: nil, descriptors: [:], requestedRung: .agentVisit)
        XCTAssertEqual(out["rung"] as? String, "spoken_description")
    }

    // MARK: - Status copy

    func testDeniedAndUnavailableBothSayTheSubjectCanContinue() {
        XCTAssertTrue(LocationCapture.statusText(for: .denied)!.contains("still continue"))
        XCTAssertTrue(LocationCapture.statusText(for: .unavailable)!.contains("still continue"))
    }

    func testReportsTheAccuracyAchievedNotTheOneRequested() {
        XCTAssertTrue(LocationCapture.statusText(for: .ready, accuracyM: 137)!.contains("137 m"))
    }

    // MARK: - Decoding the action

    private func decode(_ raw: [String: Any]) throws -> PendingAction {
        try PendingAction.decode(raw)
    }

    func testDecodesALocationCapture() throws {
        let action = try decode([
            "kind": "capture",
            "capture": "location",
            "toolId": "address_capture",
            "locationRung": "at_the_door",
            "locationAccuracyTargetM": 150,
            "locationMaxWaitMs": 25000,
            "requireFrontagePhoto": true,
            "requireAttestation": true,
            "descriptorFields": [["key": "street_name", "type": "text", "label": "Street"]],
        ])
        guard case .captureLocation(let spec) = action else {
            return XCTFail("expected a location capture, got \(action)")
        }
        XCTAssertEqual(spec.rung, .atTheDoor)
        XCTAssertEqual(spec.maxWaitMs, 25000)
        XCTAssertEqual(spec.accuracyTargetM, 150)
        XCTAssertTrue(spec.requireFrontagePhoto)
        XCTAssertEqual(spec.descriptorFields.count, 1)
        XCTAssertEqual(spec.descriptorFields.first?.key, "street_name")
    }

    func testDecodingSurvivesAnEmptyAction() {
        // Every field is optional on the wire. A client that meets an action
        // with nothing set must render defaults, not fall over: this is a
        // frozen contract and the alternative is a crash mid-verification.
        let action = try? decode(["kind": "capture", "capture": "location"])
        guard case .captureLocation(let spec)? = action else {
            return XCTFail("an empty location action should still decode")
        }
        XCTAssertNil(spec.rung)
        XCTAssertEqual(spec.maxWaitMs, 20_000)
        XCTAssertFalse(spec.requireAttestation)
        XCTAssertTrue(spec.descriptorFields.isEmpty)
    }

    func testAnUnrecognisedRungIsIgnoredRatherThanFatal() {
        // The server takes the weaker of its own ceiling and whatever we
        // report, so falling back to nil costs nothing and cannot overstate.
        let action = try? decode(["kind": "capture", "capture": "location", "locationRung": "teleportation"])
        guard case .captureLocation(let spec)? = action else {
            return XCTFail("should still decode")
        }
        XCTAssertNil(spec.rung)
    }

    func testAnUnknownCaptureVariantStillThrows() {
        // The reason the whole downgrade exists: this decoder is strict, so a
        // build that has not declared the capability must never be sent a kind
        // it does not know.
        XCTAssertThrowsError(try decode(["kind": "capture", "capture": "retina_scan"]))
    }
}
