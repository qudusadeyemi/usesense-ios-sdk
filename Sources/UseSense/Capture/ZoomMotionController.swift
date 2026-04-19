//
//  ZoomMotionController.swift
//  UseSense
//
//  Pure state-machine port of the web-sdk zoom-motion controller.
//  Phase 1 ticket I-1.
//
//  Consumes a stream of per-frame (bbox, head-pose) observations and
//  decides whether the user is performing the v4 induced-zoom motion:
//  holding at arm's length, then moving the camera closer.
//
//  Does NOT touch AVCaptureSession and does NOT own a camera. It's a
//  pure state object driven by LiveSenseV4Session.
//

import Foundation
import CoreGraphics

public enum ZoomOvalState {
    case framing
    case enlarged
}

public enum ZoomState {
    case idle
    case watching
    case moving
    case complete
    case failed
}

public enum ZoomFailureReason: String {
    case timeout
    case noMotion = "no_motion"
    case headTurn = "head_turn"
    case faceLost = "face_lost"
}

public struct HeadPoseDegrees {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }
}

public struct FaceBoundingBox {
    public var cx: Double
    public var cy: Double
    public var w: Double
    public var h: Double
    public init(cx: Double, cy: Double, w: Double, h: Double) {
        self.cx = cx; self.cy = cy; self.w = w; self.h = h
    }
    public init(_ rect: CGRect) {
        self.cx = Double(rect.midX); self.cy = Double(rect.midY)
        self.w = Double(rect.width); self.h = Double(rect.height)
    }
}

public struct ZoomObservation {
    public let timestampMs: Double
    public let bbox: FaceBoundingBox
    public let headPose: HeadPoseDegrees
    public init(timestampMs: Double, bbox: FaceBoundingBox, headPose: HeadPoseDegrees) {
        self.timestampMs = timestampMs; self.bbox = bbox; self.headPose = headPose
    }
}

public struct ZoomMotionStats {
    public let startBbox: FaceBoundingBox?
    public let endBbox: FaceBoundingBox?
    public let scaleRatio: Double
    public let durationMs: Double
    public let maxHeadYawAbsDeg: Double
    public let maxHeadPitchAbsDeg: Double
    public let observationCount: Int
}

public struct ZoomMotionConfig {
    public var timeoutMs: Double
    public var windowMs: Double
    public var minGrowthInWindow: Double
    public var completionMinScaleRatio: Double
    public var completionMaxScaleRatio: Double
    public var completionDwellMs: Double
    public var maxHeadPoseDeg: Double
    public var noMotionGraceMs: Double

    public init(
        timeoutMs: Double = 3000,
        windowMs: Double = 200,
        minGrowthInWindow: Double = 0.05,
        completionMinScaleRatio: Double = 1.7,
        completionMaxScaleRatio: Double = 2.4,
        completionDwellMs: Double = 200,
        maxHeadPoseDeg: Double = 15,
        noMotionGraceMs: Double = 1500
    ) {
        self.timeoutMs = timeoutMs
        self.windowMs = windowMs
        self.minGrowthInWindow = minGrowthInWindow
        self.completionMinScaleRatio = completionMinScaleRatio
        self.completionMaxScaleRatio = completionMaxScaleRatio
        self.completionDwellMs = completionDwellMs
        self.maxHeadPoseDeg = maxHeadPoseDeg
        self.noMotionGraceMs = noMotionGraceMs
    }
}

public protocol ZoomMotionControllerDelegate: AnyObject {
    func zoomMotionDidTransition(
        next: ZoomState,
        prev: ZoomState,
        stats: ZoomMotionStats,
        failure: ZoomFailureReason?
    )
}

public final class ZoomMotionController {
    private let cfg: ZoomMotionConfig
    private var stateValue: ZoomState = .idle
    private var startTs: Double?
    private var startBbox: FaceBoundingBox?
    private var latestBbox: FaceBoundingBox?
    private var completionDwellStartedAt: Double?
    private var lastMotionTs: Double?
    private var maxYaw: Double = 0
    private var maxPitch: Double = 0
    private var observationCount: Int = 0
    private var window: [(ts: Double, area: Double)] = []

    public weak var delegate: ZoomMotionControllerDelegate?

    public init(config: ZoomMotionConfig = ZoomMotionConfig()) {
        self.cfg = config
    }

    public var state: ZoomState { stateValue }

    public func start() {
        guard stateValue == .idle || stateValue == .complete || stateValue == .failed else { return }
        reset()
        transition(to: .watching, failure: nil)
    }

    public func stop() {
        guard stateValue != .complete && stateValue != .failed else { return }
        transition(to: .failed, failure: .timeout)
    }

    /// Feed one observation. Returns true when state transitions.
    @discardableResult
    public func observe(_ obs: ZoomObservation) -> Bool {
        guard stateValue == .watching || stateValue == .moving else { return false }
        let prev = stateValue

        if startTs == nil {
            startTs = obs.timestampMs
            startBbox = obs.bbox
            latestBbox = obs.bbox
            observationCount = 0
            window = []
        }

        if let lastTs = window.last?.ts, obs.timestampMs < lastTs { return false }

        observationCount += 1
        latestBbox = obs.bbox
        maxYaw = max(maxYaw, abs(obs.headPose.yaw))
        maxPitch = max(maxPitch, abs(obs.headPose.pitch))

        let elapsed = obs.timestampMs - (startTs ?? obs.timestampMs)

        if abs(obs.headPose.yaw) > cfg.maxHeadPoseDeg || abs(obs.headPose.pitch) > cfg.maxHeadPoseDeg {
            transition(to: .failed, failure: .headTurn)
            return true
        }
        if elapsed > cfg.timeoutMs {
            transition(to: .failed, failure: .timeout)
            return true
        }

        let area = obs.bbox.w * obs.bbox.h
        window.append((obs.timestampMs, area))
        let lower = obs.timestampMs - cfg.windowMs
        while window.count > 1 && window.first!.ts < lower { window.removeFirst() }

        let startArea = max(1e-6, (startBbox?.w ?? 0) * (startBbox?.h ?? 0))
        let windowStartArea = window.first?.area ?? area
        let growthInWindow = (area - windowStartArea) / startArea

        if growthInWindow >= cfg.minGrowthInWindow {
            lastMotionTs = obs.timestampMs
            if stateValue == .watching { transition(to: .moving, failure: nil) }
        }

        let scaleRatio = area / startArea
        if scaleRatio >= cfg.completionMinScaleRatio && scaleRatio <= cfg.completionMaxScaleRatio {
            if completionDwellStartedAt == nil {
                completionDwellStartedAt = obs.timestampMs
            } else if obs.timestampMs - completionDwellStartedAt! >= cfg.completionDwellMs {
                transition(to: .complete, failure: nil)
                return true
            }
        } else {
            completionDwellStartedAt = nil
        }

        if lastMotionTs == nil && elapsed >= cfg.noMotionGraceMs {
            transition(to: .failed, failure: .noMotion)
            return true
        }

        return stateValue != prev
    }

    public func stats() -> ZoomMotionStats {
        let startArea = (startBbox?.w ?? 0) * (startBbox?.h ?? 0)
        let endArea = (latestBbox?.w ?? 0) * (latestBbox?.h ?? 0)
        let durationMs: Double = {
            guard let s = startTs, let l = window.last?.ts else { return 0 }
            return l - s
        }()
        return ZoomMotionStats(
            startBbox: startBbox,
            endBbox: latestBbox,
            scaleRatio: startArea > 0 ? endArea / startArea : 0,
            durationMs: durationMs,
            maxHeadYawAbsDeg: maxYaw,
            maxHeadPitchAbsDeg: maxPitch,
            observationCount: observationCount
        )
    }

    private func reset() {
        startTs = nil
        startBbox = nil
        latestBbox = nil
        completionDwellStartedAt = nil
        lastMotionTs = nil
        maxYaw = 0
        maxPitch = 0
        observationCount = 0
        window = []
    }

    private func transition(to next: ZoomState, failure: ZoomFailureReason?) {
        let prev = stateValue
        if prev == next { return }
        stateValue = next
        delegate?.zoomMotionDidTransition(next: next, prev: prev, stats: stats(), failure: failure)
    }
}
