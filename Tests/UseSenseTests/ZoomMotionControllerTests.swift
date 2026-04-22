//
//  ZoomMotionControllerTests.swift
//  UseSenseTests
//
//  Phase 1 ticket I-1.
//

import XCTest
@testable import UseSenseSDK

final class ZoomMotionControllerTests: XCTestCase {

    private final class CaptureDelegate: ZoomMotionControllerDelegate {
        var transitions: [(ZoomState, ZoomState, ZoomFailureReason?)] = []
        func zoomMotionDidTransition(
            next: ZoomState,
            prev: ZoomState,
            stats: ZoomMotionStats,
            failure: ZoomFailureReason?
        ) {
            transitions.append((next, prev, failure))
        }
    }

    private func bbox(scale: Double) -> FaceBoundingBox {
        let baseW = 240.0
        let baseH = 320.0
        return FaceBoundingBox(cx: 640, cy: 360, w: baseW * scale, h: baseH * scale)
    }

    private func pose(yaw: Double = 0, pitch: Double = 0) -> HeadPoseDegrees {
        return HeadPoseDegrees(yaw: yaw, pitch: pitch, roll: 0)
    }

    func testValidZoomCompletes() {
        let ctrl = ZoomMotionController()
        let d = CaptureDelegate()
        ctrl.delegate = d
        ctrl.start()

        // 45 frames at 33ms each: linear 1.0 -> 1.4
        for i in 0..<45 {
            let t = 100.0 + Double(i) * 33.0
            let scale = 1.0 + 0.4 * Double(i) / 44.0
            ctrl.observe(ZoomObservation(timestampMs: t, bbox: bbox(scale: scale), headPose: pose()))
            if ctrl.state == .complete || ctrl.state == .failed { break }
        }
        // Dwell at 1.4.
        for i in 0..<10 {
            let t = 100.0 + 45.0 * 33.0 + Double(i) * 33.0
            ctrl.observe(ZoomObservation(timestampMs: t, bbox: bbox(scale: 1.4), headPose: pose()))
            if ctrl.state == .complete || ctrl.state == .failed { break }
        }

        XCTAssertEqual(ctrl.state, .complete)
    }

    func testNoMotionFails() {
        let ctrl = ZoomMotionController()
        ctrl.start()
        for i in 0..<60 {
            let t = 100.0 + Double(i) * 33.0
            ctrl.observe(ZoomObservation(timestampMs: t, bbox: bbox(scale: 1.0), headPose: pose()))
        }
        XCTAssertEqual(ctrl.state, .failed)
    }

    func testHeadTurnFails() {
        let ctrl = ZoomMotionController()
        let d = CaptureDelegate()
        ctrl.delegate = d
        ctrl.start()
        let stream: [(Double, Double, Double)] = [
            (100, 1.0, 0),
            (133, 1.05, 5),
            (166, 1.1, 12),
            (200, 1.15, 20)
        ]
        for (t, s, yaw) in stream {
            ctrl.observe(ZoomObservation(timestampMs: t, bbox: bbox(scale: s), headPose: pose(yaw: yaw)))
            if ctrl.state == .failed { break }
        }
        XCTAssertEqual(ctrl.state, .failed)
        let sawHeadTurn = d.transitions.contains { $0.2 == .headTurn }
        XCTAssertTrue(sawHeadTurn, "expected a headTurn transition, saw \(d.transitions)")
    }

    func testTimeoutShortBudget() {
        let cfg = ZoomMotionConfig(timeoutMs: 500, noMotionGraceMs: 2000)
        let ctrl = ZoomMotionController(config: cfg)
        ctrl.start()
        for i in 0..<40 {
            let t = 100.0 + Double(i) * 25.0
            ctrl.observe(ZoomObservation(timestampMs: t, bbox: bbox(scale: 1.0 + 0.01 * Double(i)), headPose: pose()))
        }
        XCTAssertEqual(ctrl.state, .failed)
    }

    func testStatsCapturePeakPose() {
        let ctrl = ZoomMotionController()
        ctrl.start()
        ctrl.observe(ZoomObservation(timestampMs: 100, bbox: bbox(scale: 1.0), headPose: pose(yaw: 3, pitch: -2)))
        ctrl.observe(ZoomObservation(timestampMs: 200, bbox: bbox(scale: 1.1), headPose: pose(yaw: 7, pitch: -5)))
        ctrl.observe(ZoomObservation(timestampMs: 300, bbox: bbox(scale: 1.2), headPose: pose(yaw: -4, pitch: 6)))
        let s = ctrl.stats()
        XCTAssertEqual(s.maxHeadYawAbsDeg, 7, accuracy: 0.001)
        XCTAssertEqual(s.maxHeadPitchAbsDeg, 6, accuracy: 0.001)
    }
}
