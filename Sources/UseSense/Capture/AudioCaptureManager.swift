#if canImport(AVFoundation)
import AVFoundation

final class AudioCaptureManager: @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    private let tempURL: URL

    init() {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("usesense_audio_\(UUID().uuidString).m4a")
    }

    func startRecording(durationMs: Int) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try audioSession.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 48000
        ]

        recorder = try AVAudioRecorder(url: tempURL, settings: settings)
        recorder?.record(forDuration: TimeInterval(durationMs) / 1000.0)
    }

    func stopRecording() -> Data? {
        recorder?.stop()
        defer { cleanup() }
        return try? Data(contentsOf: tempURL)
    }

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempURL)
        recorder = nil
    }

    deinit {
        cleanup()
    }
}
#endif
