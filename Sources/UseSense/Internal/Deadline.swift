import Foundation

/// Bounds an async operation by wall-clock time.
///
/// The `withTaskGroup` race this replaces (one child does the work, one sleeps)
/// does NOT return at the deadline: a task group always waits for every child
/// before it returns, so an operation that ignores cancellation -- an Apple
/// App Attest call, a URLSession transfer that is mid-retry -- held the caller
/// for as long as it liked. Here the caller is resumed by whichever finishes
/// first and the slow operation is cancelled and left to wind down on its own.
enum Deadline {
    /// Returns the operation's value, or nil if it did not finish within
    /// `seconds` (or the calling task was cancelled first).
    static func run<T>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let gate = ResumeOnce<T?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                gate.install(continuation)
                let work = Task {
                    let value = await operation()
                    gate.resume(value)
                }
                gate.setCancel { work.cancel() }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    if gate.resume(nil) { work.cancel() }
                }
            }
        } onCancel: {
            gate.resume(nil)
            gate.cancelWork()
        }
    }
}

/// Resumes a continuation exactly once, whichever side gets there first.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var hasPending = false
    private var done = false
    private var onLateCancel: (() -> Void)?

    func setCancel(_ cancel: @escaping () -> Void) {
        lock.lock()
        onLateCancel = cancel
        lock.unlock()
    }

    func install(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if hasPending, let value = pending {
            // Resumed (e.g. cancelled) before the continuation existed.
            hasPending = false
            pending = nil
            done = true
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Returns true when this call is the one that resumed.
    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        guard let continuation else {
            if !hasPending { pending = value; hasPending = true }
            lock.unlock()
            return true
        }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }

    func cancelWork() {
        lock.lock()
        let cancel = onLateCancel
        lock.unlock()
        cancel?()
    }
}
