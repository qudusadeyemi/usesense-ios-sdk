#if canImport(UIKit) && canImport(QuartzCore)
import UIKit
import QuartzCore

/// What the colour player needs from the screen: a whole-screen tint and full
/// brightness. Implemented by the view model (main thread).
protocol ColourTintHost: AnyObject {
    /// `colour` nil hides the tint.
    func showTint(_ colour: String?, opacity: Double)
    /// Raise the screen to full brightness; returns the brightness actually
    /// set (0 to 1), or nil if unknown.
    func holdFullBrightness() -> Double?
    func releaseFullBrightness()
}

/// Plays the server's colour sequence (EVIDENCE-v1 section 6) and records
/// what actually happened. Each segment's start is the `CADisplayLink`
/// target time of the frame that first draws it, on the capture clock. Main
/// thread only.
///
/// Order rule (Watchtower `scoreReflection`): uploaded segments must read
/// `issued[i % n]` in order. So a gate pause drops the partly shown segment
/// and the replay resumes at that colour; a dropped scan window clears the
/// record and the next window starts again at the first colour.
final class ColourSequencePlayer {
    enum Phase: Equatable { case idle, leadIn, segment(Int), done }

    let sequence: EvidenceConfig.ColourSequence
    /// Host time (CACurrentMediaTime base) to capture-clock ms; nil before the
    /// camera's first frame.
    private let clock: (CFTimeInterval) -> Int?
    weak var host: ColourTintHost?
    /// Called when the white balance should lock (true) or unlock (false);
    /// returns whether the lock took.
    var lockWhiteBalance: ((Bool) -> Bool)?

    private(set) var phase: Phase = .idle
    private(set) var record: ColourEvidence
    /// Plays started (the first, plus replays after a pause).
    private(set) var runs = 0
    private var phaseStart: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var awbAllRuns = true
    /// The colour the next play starts at.
    private(set) var nextIndex = 0

    init(sequence: EvidenceConfig.ColourSequence, clock: @escaping (CFTimeInterval) -> Int?) {
        self.sequence = sequence
        self.clock = clock
        record = ColourEvidence(sequenceId: sequence.id)
    }

    var isPlaying: Bool {
        switch phase { case .leadIn, .segment: return true; default: return false }
    }
    var finished: Bool { phase == .done }

    /// Start, or resume after a pause, from a lead-in.
    func play(now: CFTimeInterval = CACurrentMediaTime()) {
        guard !isPlaying, !finished else { return }
        runs += 1
        phase = .leadIn
        phaseStart = now
        let locked = lockWhiteBalance?(true) ?? false
        awbAllRuns = awbAllRuns && locked
        record.awbLocked = awbAllRuns
        if let b = host?.holdFullBrightness() { record.screenBrightness = b }
        let link = CADisplayLink(target: self, selector: #selector(onFrame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A gate pause: stop the tint. The partly shown segment is dropped and
    /// the next play resumes at its colour, keeping the issued order.
    func interrupt(reason: String = "gate_pause", now: CFTimeInterval = CACurrentMediaTime()) {
        guard isPlaying else { return }
        if case .segment(let i) = phase {
            _ = record.segments.popLast()
            nextIndex = i
        }
        record.completed = false
        record.interruptedReason = reason
        stop(to: .idle)
    }

    /// Abandon the sequence (capture over, screen gone).
    func cancel(now: CFTimeInterval = CACurrentMediaTime()) {
        interrupt(reason: "cancelled", now: now)
    }

    /// The scan window was dropped with its frames: the segments go too, and
    /// the next window plays the sequence from the first colour.
    func resetForNewWindow(now: CFTimeInterval = CACurrentMediaTime()) {
        interrupt(reason: "window_dropped", now: now)
        record = ColourEvidence(sequenceId: sequence.id)
        nextIndex = 0
        runs = 0
        awbAllRuns = true
        phase = .idle
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        advance(to: link.targetTimestamp)
    }

    /// Drive the state machine to the frame shown at `t` (tested directly).
    func advance(to t: CFTimeInterval) {
        let leadIn = Double(sequence.leadInMs) / 1000
        let segment = Double(sequence.segmentMs) / 1000
        switch phase {
        case .leadIn where t - phaseStart >= leadIn:
            begin(nextIndex, at: t)
        case .segment(let i) where t - phaseStart >= segment:
            closeSegment(at: t)
            nextIndex = i + 1
            if i + 1 < sequence.colours.count {
                begin(i + 1, at: t)
            } else {
                record.completed = true
                record.interruptedReason = nil
                stop(to: .done)
            }
        default:
            break
        }
    }

    private func begin(_ i: Int, at t: CFTimeInterval) {
        guard let ms = clock(t) else { return }
        phase = .segment(i)
        phaseStart = t
        let colour = sequence.colours[i]
        record.segments.append(.init(colour: colour, startMs: ms, endMs: ms))
        host?.showTint(colour, opacity: sequence.opacity)
    }

    private func closeSegment(at t: CFTimeInterval) {
        guard var last = record.segments.popLast() else { return }
        last.endMs = max(last.startMs + 1, clock(t) ?? last.startMs + 1)
        record.segments.append(last)
    }

    private func stop(to next: Phase) {
        let wasPlaying = isPlaying
        link?.invalidate()
        link = nil
        phase = next
        guard wasPlaying else { return }
        host?.showTint(nil, opacity: 0)
        host?.releaseFullBrightness()
        _ = lockWhiteBalance?(false)
    }

    deinit { link?.invalidate() }
}
#endif
