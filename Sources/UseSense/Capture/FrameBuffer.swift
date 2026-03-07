import Foundation

final class FrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var timestamps: [Int] = []
    private let maxCapacity: Int

    init(maxCapacity: Int = 30) {
        self.maxCapacity = maxCapacity
    }

    func append(frame: Data, timestampMs: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard frames.count < maxCapacity else { return }
        frames.append(frame)
        timestamps.append(timestampMs)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    func allFrames() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func allTimestamps() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return timestamps
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
        timestamps.removeAll()
    }
}
