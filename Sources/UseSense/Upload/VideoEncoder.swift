//
//  VideoEncoder.swift
//  UseSense
//
//  AVAssetWriter wrapper for H.264 MP4 output.
//  Phase 1 ticket I-1.
//
//  1280x720 30fps, H.264 Baseline, ~4 Mbps. Writes to a temp file then
//  returns the bytes; caller handles upload.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

public enum VideoEncoderError: Error {
    case alreadyStarted
    case notStarted
    case writerSetupFailed
    case finishFailed
    case tempFileError
}

public final class VideoEncoder {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrate: Int

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var tempURL: URL?
    private var sessionStarted = false

    public init(
        width: Int = 1280,
        height: Int = 720,
        fps: Int = 30,
        bitrate: Int = 4_000_000
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
    }

    public func start() throws {
        guard writer == nil else { throw VideoEncoderError.alreadyStarted }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("usesense-v4-\(UUID().uuidString).mp4")
        self.tempURL = temp

        guard let writer = try? AVAssetWriter(outputURL: temp, fileType: .mp4) else {
            throw VideoEncoderError.writerSetupFailed
        }
        self.writer = writer

        // TODO: device-verify on iPhone 13 + iPhone 15 that 30fps locked
        // encoding holds under load. Test also on lower-end iPhone SE.
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        self.videoInput = input

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelAttrs
        )
        self.adaptor = adaptor

        if writer.canAdd(input) { writer.add(input) }

        guard writer.startWriting() else {
            throw VideoEncoderError.writerSetupFailed
        }
    }

    /// Append a pixel buffer. Caller provides the monotonic presentation time.
    public func appendPixelBuffer(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        guard let writer = writer, let adaptor = adaptor, let input = videoInput else {
            throw VideoEncoderError.notStarted
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData {
            adaptor.append(buffer, withPresentationTime: time)
        }
    }

    /// Finish the writer and return the MP4 bytes. Cleans up the temp file.
    public func finish() async throws -> Data {
        guard let writer = writer, let input = videoInput, let url = tempURL else {
            throw VideoEncoderError.notStarted
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw VideoEncoderError.finishFailed
        }
        let bytes = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return bytes
    }
}
