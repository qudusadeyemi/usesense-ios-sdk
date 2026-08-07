import Foundation
import Compression

/// gzip framing for upload payloads.
///
/// metadata.json is a few hundred KB of JSON on every session and browsers/OSes
/// do not compress request bodies on their own, so it goes out raw. gzip takes
/// roughly half of it.
///
/// The server detects compression from the payload's magic bytes (1f 8b) rather
/// than a filename or header, so the framing here has to be real gzip, not the
/// raw DEFLATE that `Compression.COMPRESSION_ZLIB` produces on its own. This
/// wraps that DEFLATE stream in the RFC 1952 header and trailer.
///
/// Returns nil when compression fails or would not help; callers must fall back
/// to sending the payload uncompressed, which the server still accepts.
enum Gzip {
    /// RFC 1952 fixed header: magic, DEFLATE method, no flags, no mtime,
    /// no extra flags, unknown OS.
    private static let header: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]

    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        guard let deflated = rawDeflate(data) else { return nil }

        var out = Data(header)
        out.append(deflated)

        // Trailer: CRC32 of the uncompressed data, then its length mod 2^32,
        // both little-endian.
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }

        // Only worth sending if it actually got smaller.
        return out.count < data.count ? out : nil
    }

    /// Raw DEFLATE stream (no zlib or gzip wrapper) via the Compression framework.
    private static func rawDeflate(_ data: Data) -> Data? {
        // Worst case for incompressible input is slightly larger than the source;
        // the extra headroom keeps the single-shot encode from failing on it.
        let capacity = data.count + (data.count / 2) + 64
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destination, capacity,
                base, data.count,
                nil, COMPRESSION_ZLIB
            )
        }

        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    // MARK: - CRC32

    // Table-driven CRC32 (IEEE polynomial, reflected 0xEDB88320). Implemented
    // here rather than linked from zlib so the SDK picks up no new dependency
    // and no module map for a dozen lines of arithmetic.
    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}
