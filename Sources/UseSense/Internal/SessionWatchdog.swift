import Foundation

/// Guarantees a capture reaches a terminal state. Once armed for a phase, it
/// fires `onTimeout` if the phase is still armed when its budget runs out (or,
/// for a phase with a stall window, when nothing has kicked it for that long).
///
/// It exists because every way the SDK used to hang -- an App Attest call that
/// never returned, a challenge that never reported completion, an upload stuck
/// in its retry loop -- left the subject on a spinner or a frozen camera with
/// nothing sent to the server and nothing told to the host app. A system
/// failure must end in an error the subject can see and retry, with a code.
final class SessionWatchdog: @unchecked Sendable {
    enum Phase: String, Sendable {
        /// Baseline, zoom, countdown, challenge and inline step-up: from the
        /// moment frames start being captured until the upload begins.
        case capture
        /// Signals upload (with its retries) through the complete call.
        case upload

        var errorCode: UseSenseErrorCode {
            switch self {
            case .capture: return .captureTimeout
            case .upload: return .uploadTimeout
            }
        }
    }

    struct Budget: Sendable, Equatable {
        /// Hard ceiling for the phase.
        let total: TimeInterval
        /// Optional "no progress" window: the phase also fails if `kick()` has
        /// not been called for this long. nil = hard ceiling only.
        let stall: TimeInterval?

        init(total: TimeInterval, stall: TimeInterval? = nil) {
            self.total = total
            self.stall = stall
        }
    }

    /// A capture is a few seconds of baseline plus one challenge; two minutes
    /// is far past any honest attempt.
    static let captureBudget = Budget(total: 120)
    /// The signals upload legitimately runs long on a slow uplink (it is sized
    /// for ~15 KB/s), so it is bounded by a hard ceiling plus a stall window
    /// that progress callbacks keep pushing back: a slow upload that is moving
    /// survives, one that has stopped moving does not.
    static let uploadBudget = Budget(total: 300, stall: 60)

    private let lock = NSLock()
    private var generation = 0
    private var phase: Phase?
    private var deadline = Date.distantFuture
    private var stallWindow: TimeInterval?
    private var lastKick = Date()
    private var task: Task<Void, Never>?
    private let now: @Sendable () -> Date
    private let onTimeout: @Sendable (Phase) -> Void

    init(now: @escaping @Sendable () -> Date = { Date() }, onTimeout: @escaping @Sendable (Phase) -> Void) {
        self.now = now
        self.onTimeout = onTimeout
    }

    deinit { task?.cancel() }

    var armedPhase: Phase? {
        lock.lock(); defer { lock.unlock() }
        return phase
    }

    /// Arm (or re-arm) for `phase`. Replaces any phase already armed.
    func arm(_ phase: Phase, budget: Budget) {
        lock.lock()
        generation += 1
        let gen = generation
        self.phase = phase
        let start = now()
        deadline = start.addingTimeInterval(budget.total)
        stallWindow = budget.stall
        lastKick = start
        task?.cancel()
        task = Task { [weak self] in await self?.run(generation: gen) }
        lock.unlock()
    }

    /// Record progress. Only meaningful for a phase with a stall window.
    func kick() {
        lock.lock()
        lastKick = now()
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        generation += 1
        phase = nil
        task?.cancel()
        task = nil
        lock.unlock()
    }

    /// Seconds until the armed phase should fire; nil when `generation` is no
    /// longer the armed one.
    private func secondsUntilFire(generation gen: Int) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard gen == generation, phase != nil else { return nil }
        var fireAt = deadline
        if let stall = stallWindow {
            fireAt = min(fireAt, lastKick.addingTimeInterval(stall))
        }
        return fireAt.timeIntervalSince(now())
    }

    /// Claims the timeout for `generation`; returns the phase that expired.
    private func claim(generation gen: Int) -> Phase? {
        lock.lock(); defer { lock.unlock() }
        guard gen == generation, let expired = phase else { return nil }
        generation += 1
        phase = nil
        task = nil
        return expired
    }

    private func run(generation gen: Int) async {
        while !Task.isCancelled {
            guard let wait = secondsUntilFire(generation: gen) else { return }
            if wait <= 0 {
                if let expired = claim(generation: gen) { onTimeout(expired) }
                return
            }
            // Wake at the earliest possible fire time, then re-check: a kick
            // may have pushed the stall deadline back in the meantime.
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 1_000_000)
            } catch {
                return
            }
        }
    }
}
