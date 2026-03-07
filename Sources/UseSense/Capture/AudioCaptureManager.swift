#if canImport(AVFoundation)
import AVFoundation
import Foundation

final class AudioCaptureManager: @unchecked Sendable {
    private var audioRecorder: AVAudioRecorder?
    private let fileManager = FileManager.default
    private(set) var isRecording = false

    private var recordingURL: URL {
        let tempDir = fileManager.temporaryDirectory
        return tempDir.appendingPathComponent("usesense_audio_\(UUID().uuidString).m4a")
    }

    func startRecording() throws -> URL {
        let url = recordingURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000
        ]

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.record()
        isRecording = true
        return url
    }

    func stopRecording() -> Data? {
        guard let recorder = audioRecorder, recorder.isRecording else { return nil }
        recorder.stop()
        isRecording = false

        let url = recorder.url
        defer {
            try? fileManager.removeItem(at: url)
            audioRecorder = nil
        }

        return try? Data(contentsOf: url)
    }

    func cleanup() {
        if let recorder = audioRecorder {
            if recorder.isRecording { recorder.stop() }
            try? fileManager.removeItem(at: recorder.url)
            audioRecorder = nil
        }
        isRecording = false
    }
}
#endif
