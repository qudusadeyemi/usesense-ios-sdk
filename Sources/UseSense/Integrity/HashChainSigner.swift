//
//  HashChainSigner.swift
//  UseSense
//
//  LiveSense v4 hash-chain builder + Secure Enclave signer.
//
//  Phase 1 ticket I-1.
//
//  Protocol (matches watchtower chain-signature.tsx exactly):
//
//      chain[0] = SHA-256(session_token.utf8 || frame[0])
//      chain[i] = SHA-256(chain[i-1] || frame[i])   for i > 0
//
//  The terminal value is signed by a Secure Enclave EC P-256 key
//  generated per session via kSecAttrTokenIDSecureEnclave. This is
//  orthogonal to the App Attest key: App Attest gates the session
//  attestation_token, this key gates the per-session frame chain.
//

import Foundation
import CryptoKit
import Security

public enum HashChainError: Error, Equatable {
    case emptyChain
    case secureEnclaveUnavailable
    case keyCreationFailed(status: OSStatus)
    case signingFailed(status: OSStatus)
    case publicKeyExportFailed
    case invalidHexEncoding
}

// MARK: - HashChainBuilder

/// Incremental chain builder. Call append() in capture order. terminal()
/// yields the terminal hash; terminalHex() returns it hex-encoded.
public final class HashChainBuilder {
    private let sessionTokenBytes: Data
    private var current: Data?
    private var frameHashesList: [String] = []
    private var count: Int = 0

    public init(sessionToken: String) {
        self.sessionTokenBytes = Data(sessionToken.utf8)
    }

    /// Append a frame. Returns the per-frame SHA-256 hex (useful for the
    /// frame_hashes[] upload field).
    @discardableResult
    public func append(frameBytes: Data) -> String {
        let frameHash = Data(SHA256.hash(data: frameBytes))
        let hex = Self.bytesToHex(frameHash)
        frameHashesList.append(hex)
        current = nextChain(previous: current, frameHash: frameHash)
        count += 1
        return hex
    }

    /// Append a pre-computed per-frame hash. Saves a redundant hash pass
    /// when the caller already has it (e.g. from V4FrameCapture parallel).
    public func appendWithHash(hexHash: String) throws {
        guard hexHash.count == 64 else { throw HashChainError.invalidHexEncoding }
        let frameHash = try Self.hexToBytes(hexHash)
        frameHashesList.append(hexHash.lowercased())
        current = nextChain(previous: current, frameHash: frameHash)
        count += 1
    }

    public func terminal() throws -> Data {
        guard let t = current else { throw HashChainError.emptyChain }
        return t
    }

    public func terminalHex() throws -> String {
        return Self.bytesToHex(try terminal())
    }

    public func frameHashes() -> [String] { frameHashesList }
    public func length() -> Int { count }

    private func nextChain(previous: Data?, frameHash: Data) -> Data {
        if let p = previous {
            return Data(SHA256.hash(data: p + frameHash))
        }
        return Data(SHA256.hash(data: sessionTokenBytes + frameHash))
    }

    // MARK: Hex helpers

    static func bytesToHex(_ data: Data) -> String {
        var s = ""
        s.reserveCapacity(data.count * 2)
        for b in data { s += String(format: "%02x", b) }
        return s
    }

    static func hexToBytes(_ hex: String) throws -> Data {
        guard hex.count % 2 == 0 else { throw HashChainError.invalidHexEncoding }
        var out = Data()
        out.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else {
                throw HashChainError.invalidHexEncoding
            }
            out.append(b)
            idx = next
        }
        return out
    }
}

// MARK: - Secure Enclave signer

/// Secure Enclave EC P-256 signer. Generates a per-session signing key
/// stored only in the enclave (not extractable), signs the terminal hash,
/// and exports the public key as SPKI DER so the server can verify with
/// standard CryptoKit/OpenSSL/WebCrypto.
///
/// Usage:
///     let signer = try V4ChainSigner(sessionId: cfg.sessionId.uuidString)
///     let pkSpki = try signer.exportPublicKeySpkiBase64Url()
///     let sig = try signer.sign(terminal: terminal)
///
/// Signatures are DER-encoded ECDSA. The server handles both DER and raw
/// R||S; see chain-signature.tsx derToRawEcdsaSig.
public final class V4ChainSigner {
    public let assuranceLevel: String = "mobile_hardware"
    private let privateKey: SecKey
    private let publicKey: SecKey

    public init(sessionId: String) throws {
        // TODO: device-verify on iPhone 13 + iPhone 15 that Secure Enclave
        // is accessible. Simulator has no Secure Enclave so falls through
        // to the software keystore path at runtime.
        let tag = "com.usesense.v4.signing.\(sessionId)".data(using: .utf8)!

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &accessError
        ) else {
            throw HashChainError.secureEnclaveUnavailable
        }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access
            ]
        ]

        var keyError: Unmanaged<CFError>?
        guard let newKey = SecKeyCreateRandomKey(attrs as CFDictionary, &keyError) else {
            let status: OSStatus
            if let err = keyError?.takeRetainedValue() {
                status = OSStatus(CFErrorGetCode(err))
            } else {
                status = errSecUnimplemented
            }
            throw HashChainError.keyCreationFailed(status: status)
        }
        self.privateKey = newKey

        guard let pub = SecKeyCopyPublicKey(newKey) else {
            throw HashChainError.publicKeyExportFailed
        }
        self.publicKey = pub
    }

    /// Sign the terminal hash with ECDSA-SHA256 (DER-encoded).
    public func sign(terminal: Data) throws -> Data {
        let algo: SecKeyAlgorithm = .ecdsaSignatureMessageX962SHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algo) else {
            throw HashChainError.signingFailed(status: errSecUnimplemented)
        }
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, algo, terminal as CFData, &error) as Data? else {
            let status: OSStatus
            if let err = error?.takeRetainedValue() {
                status = OSStatus(CFErrorGetCode(err))
            } else {
                status = errSecUnimplemented
            }
            throw HashChainError.signingFailed(status: status)
        }
        return sig
    }

    /// Export the public key as base64url-encoded SPKI DER. SPKI is what
    /// Web Crypto / Java's X509EncodedKeySpec / the server verifier expect.
    public func exportPublicKeySpkiBase64Url() throws -> String {
        // SecKey's raw EC export for P-256 is the 65-byte uncompressed point
        // 0x04 || X || Y. We wrap it in the SPKI prefix for ecPublicKey +
        // prime256v1.
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw HashChainError.publicKeyExportFailed
        }
        let spki = Self.wrapRawP256IntoSpki(raw)
        return Self.base64UrlEncode(spki)
    }

    /// SPKI prefix for EC public key (1.2.840.10045.2.1) with namedCurve
    /// prime256v1 (1.2.840.10045.3.1.7). Known-constant 26-byte header.
    private static let p256SpkiPrefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
        0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00
    ]

    static func wrapRawP256IntoSpki(_ raw: Data) -> Data {
        // `raw` is 65 bytes: 0x04 || X (32) || Y (32). Prefix expects that exact form.
        var out = Data(p256SpkiPrefix)
        out.append(raw)
        return out
    }

    // MARK: Base64URL helpers

    public static func base64UrlEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
