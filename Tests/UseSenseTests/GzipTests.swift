//
//  GzipTests.swift
//  UseSenseTests
//
//  metadata.json goes out on every session and was never compressed. The server
//  detects compression from the gzip magic bytes, so the framing here has to be
//  real RFC 1952 gzip rather than the raw DEFLATE the Compression framework
//  emits on its own. A malformed header or trailer would 400 the upload and fail
//  the capture, so these pin the framing.
//

import XCTest
@testable import UseSenseSDK

final class GzipTests: XCTestCase {

    /// Representative of the real payload: repetitive JSON with long float arrays.
    private func sampleMetadata() -> Data {
        var obj: [String: Any] = [:]
        obj["channel_integrity"] = ["camera_resolution": "1080x1920", "platform": "ios"]
        obj["frames_manifest"] = (0..<30).map { i in
            ["frame_index": i, "resolution_w": 540, "resolution_h": 960,
             "hash": String(repeating: "a", count: 64)] as [String: Any]
        }
        obj["verification_package"] = [
            "frames": (0..<8).map { _ in
                ["shapeParams": (0..<60).map { Double($0) * 0.017 },
                 "geometricRatios": (0..<40).map { Double($0) * 0.013 }] as [String: Any]
            }
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testCrc32KnownAnswer() {
        // The canonical CRC32 check vector from the zlib/PNG specs.
        let input = "123456789".data(using: .utf8)!
        XCTAssertEqual(Gzip.crc32(input), 0xCBF4_3926)
    }

    func testCrc32OfEmptyDataIsZero() {
        XCTAssertEqual(Gzip.crc32(Data()), 0)
    }

    func testEmitsGzipMagicBytes() throws {
        let out = try XCTUnwrap(Gzip.compress(sampleMetadata()))
        // The server sniffs exactly these two bytes. Everything else about the
        // encoding is negotiable; this is not.
        XCTAssertEqual(out[out.startIndex], 0x1f)
        XCTAssertEqual(out[out.startIndex + 1], 0x8b)
        // DEFLATE compression method.
        XCTAssertEqual(out[out.startIndex + 2], 0x08)
    }

    func testTrailerCarriesCrcAndLengthLittleEndian() throws {
        let source = sampleMetadata()
        let out = try XCTUnwrap(Gzip.compress(source))
        let bytes = [UInt8](out)

        let crcBytes = bytes[(bytes.count - 8)..<(bytes.count - 4)]
        let sizeBytes = bytes[(bytes.count - 4)...]

        let crc = crcBytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let size = sizeBytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        XCTAssertEqual(crc, Gzip.crc32(source))
        XCTAssertEqual(size, UInt32(source.count))
    }

    func testActuallyShrinksRealisticMetadata() throws {
        let source = sampleMetadata()
        let out = try XCTUnwrap(Gzip.compress(source))
        XCTAssertLessThan(out.count, source.count / 2,
                          "expected better than 50% on repetitive JSON")
    }

    func testReturnsNilForEmptyInput() {
        // Nothing to gain, and callers fall back to sending the payload as-is.
        XCTAssertNil(Gzip.compress(Data()))
    }

    func testReturnsNilRatherThanGrowIncompressibleInput() {
        // Random bytes cannot be deflated; the caller must not pay a size
        // penalty for the framing.
        var random = Data(count: 4096)
        random.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8.random(in: 0...255) }
        }
        if let out = Gzip.compress(random) {
            XCTAssertLessThan(out.count, random.count)
        }
    }

    func testHeaderIsTenBytesSoPayloadStartsWhereExpected() throws {
        // A short, highly compressible input keeps the arithmetic obvious:
        // 10-byte header + deflate payload + 8-byte trailer.
        let source = Data(repeating: 0x41, count: 1024)
        let out = try XCTUnwrap(Gzip.compress(source))
        XCTAssertGreaterThan(out.count, 18)
        XCTAssertEqual(Gzip.crc32(source), {
            let b = [UInt8](out)
            return b[(b.count - 8)..<(b.count - 4)].reversed()
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }())
    }
}
