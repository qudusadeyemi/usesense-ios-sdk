import XCTest
@testable import UseSenseSDK

/// The signals upload's retries must get to run before the session watchdog
/// gives up. On device, a stalled first attempt (idle limit 60 s) timed out at
/// the same moment as the watchdog's 60 s stall window, and its three retries
/// were cancelled within a millisecond.
final class UploadRetryTimingTests: XCTestCase {

    func testOneStalledAttemptPlusBackoffFitsInTheStallWindow() {
        let stall = SessionWatchdog.uploadBudget.stall ?? 0
        let longestBackoff: TimeInterval = 4
        XCTAssertLessThan(UseSenseAPIClient.uploadIdleTimeout + longestBackoff, stall,
                          "a stalled attempt must fail and retry before the watchdog fires")
    }

    func testEveryAttemptFitsTheWholeUploadBudget() {
        // 4 attempts, all stalled, with 1 + 2 + 4 s backoff between them.
        let worstCase = 4 * UseSenseAPIClient.uploadIdleTimeout + 7
        XCTAssertLessThan(worstCase, SessionWatchdog.uploadBudget.total)
        XCTAssertLessThanOrEqual(SessionWatchdog.uploadBudget.total, UseSenseAPIClient.uploadTimeout)
    }

    func testIdleLimitLeavesRoomForServerHandling() {
        // Server handling of /signals measured at 1-5 s (Supabase function logs).
        XCTAssertGreaterThanOrEqual(UseSenseAPIClient.uploadIdleTimeout, 15)
    }
}
