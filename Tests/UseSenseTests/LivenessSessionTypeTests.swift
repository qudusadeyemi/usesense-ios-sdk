import XCTest
@testable import UseSenseSDK

final class LivenessSessionTypeTests: XCTestCase {
    func testWireValues() {
        XCTAssertEqual(SessionType.liveness.rawValue, "liveness")
        XCTAssertEqual(SessionType.enrollment.rawValue, "enrollment")
        XCTAssertEqual(SessionType.authentication.rawValue, "authentication")
    }

    func testDecodesFromWire() throws {
        let decoded = try JSONDecoder().decode([SessionType].self, from: Data(#"["liveness"]"#.utf8))
        XCTAssertEqual(decoded, [.liveness])
    }

    func testLivenessWithoutIdentityIsValid() {
        XCTAssertNil(UseSenseSession.validateRequest(sessionType: .liveness, identityId: nil))
        XCTAssertNil(UseSenseSession.validateRequest(sessionType: .liveness, identityId: "  "))
    }

    func testLivenessWithIdentityIsRejected() {
        let error = UseSenseSession.validateRequest(sessionType: .liveness, identityId: "idn_123")
        XCTAssertEqual(error?.code, .invalidConfig)
        XCTAssertTrue(error?.message.contains("liveness") ?? false)
    }

    func testOtherTypesUnaffected() {
        XCTAssertNil(UseSenseSession.validateRequest(sessionType: .enrollment, identityId: nil))
        XCTAssertNil(UseSenseSession.validateRequest(sessionType: .authentication, identityId: "idn_123"))
    }

    func testVerificationRequestCarriesLiveness() {
        let request = VerificationRequest(sessionType: .liveness, externalUserId: "user-1")
        XCTAssertEqual(request.sessionType, .liveness)
        XCTAssertNil(request.identityId)
    }
}
