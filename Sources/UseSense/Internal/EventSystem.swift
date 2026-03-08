import Foundation

public enum UseSenseEventType: String, CaseIterable, Sendable {
    case sessionCreated = "session_created"
    case permissionsRequested = "permissions_requested"
    case permissionsGranted = "permissions_granted"
    case permissionsDenied = "permissions_denied"
    case captureStarted = "capture_started"
    case frameCaptured = "frame_captured"
    case captureCompleted = "capture_completed"
    case audioRecordStarted = "audio_record_started"
    case audioRecordCompleted = "audio_record_completed"
    case challengeStarted = "challenge_started"
    case challengeCompleted = "challenge_completed"
    case uploadStarted = "upload_started"
    case uploadProgress = "upload_progress"
    case uploadCompleted = "upload_completed"
    case completeStarted = "complete_started"
    case decisionReceived = "decision_received"
    case imageQualityCheck = "image_quality_check"
    case error = "error"
}

public struct UseSenseEvent: Sendable {
    public let type: UseSenseEventType
    public let timestamp: Date
    public let data: [String: String]?

    public init(type: UseSenseEventType, data: [String: String]? = nil) {
        self.type = type
        self.timestamp = Date()
        self.data = data
    }
}

public typealias EventCallback = @Sendable (UseSenseEvent) -> Void

final class EventEmitter: @unchecked Sendable {
    private var callbacks: [EventCallback] = []
    private let lock = NSLock()

    func addListener(_ callback: @escaping EventCallback) -> () -> Void {
        lock.lock()
        let index = callbacks.count
        callbacks.append(callback)
        lock.unlock()

        return { [weak self] in
            self?.lock.lock()
            if let self = self, index < self.callbacks.count {
                self.callbacks.remove(at: index)
            }
            self?.lock.unlock()
        }
    }

    func emit(_ event: UseSenseEvent) {
        lock.lock()
        let cbs = callbacks
        lock.unlock()
        for cb in cbs { cb(event) }
    }

    func emit(_ type: UseSenseEventType, data: [String: String]? = nil) {
        emit(UseSenseEvent(type: type, data: data))
    }

    /// Clear all listeners (matches Android's EventEmitter.clear()).
    func clear() {
        lock.lock()
        callbacks.removeAll()
        lock.unlock()
    }
}
