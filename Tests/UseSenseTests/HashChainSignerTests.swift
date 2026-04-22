//
//  HashChainSignerTests.swift
//  UseSenseTests
//
//  Phase 1 ticket I-1.
//

import XCTest
import CryptoKit
@testable import UseSenseSDK

final class HashChainSignerTests: XCTestCase {

    func testTwoFrameChainMatchesSpec() throws {
        let token = "sess_tok_abc"
        let f0 = Data("frame-0".utf8)
        let f1 = Data("frame-1".utf8)

        // Reference: reimplement the spec formula with CryptoKit.
        let h0 = Data(SHA256.hash(data: f0))
        let h1 = Data(SHA256.hash(data: f1))
        let c0 = Data(SHA256.hash(data: Data(token.utf8) + h0))
        let expectedTerminal = Data(SHA256.hash(data: c0 + h1))

        let b = HashChainBuilder(sessionToken: token)
        _ = b.append(frameBytes: f0)
        _ = b.append(frameBytes: f1)

        XCTAssertEqual(try b.terminal(), expectedTerminal)
        XCTAssertEqual(b.length(), 2)
        XCTAssertEqual(b.frameHashes().count, 2)
    }

    func testSingleFrame() throws {
        let token = "x"
        let f0 = Data("solo".utf8)
        let h0 = Data(SHA256.hash(data: f0))
        let expected = Data(SHA256.hash(data: Data(token.utf8) + h0))

        let b = HashChainBuilder(sessionToken: token)
        _ = b.append(frameBytes: f0)
        XCTAssertEqual(try b.terminal(), expected)
    }

    func testAppendWithHashEquivalence() throws {
        let token = "same"
        let f0 = Data("abc".utf8)
        let f1 = Data("def".utf8)

        let b1 = HashChainBuilder(sessionToken: token)
        _ = b1.append(frameBytes: f0)
        _ = b1.append(frameBytes: f1)

        let b2 = HashChainBuilder(sessionToken: token)
        try b2.appendWithHash(hexHash: HashChainBuilder.bytesToHex(Data(SHA256.hash(data: f0))))
        try b2.appendWithHash(hexHash: HashChainBuilder.bytesToHex(Data(SHA256.hash(data: f1))))

        XCTAssertEqual(try b1.terminal(), try b2.terminal())
    }

    func testTerminalBeforeAppendThrows() {
        let b = HashChainBuilder(sessionToken: "t")
        XCTAssertThrowsError(try b.terminal()) { err in
            XCTAssertEqual(err as? HashChainError, HashChainError.emptyChain)
        }
    }

    func testFrameReorderChangesTerminal() throws {
        let token = "t"
        let f0 = Data("a".utf8)
        let f1 = Data("b".utf8)

        let b1 = HashChainBuilder(sessionToken: token)
        _ = b1.append(frameBytes: f0)
        _ = b1.append(frameBytes: f1)

        let b2 = HashChainBuilder(sessionToken: token)
        _ = b2.append(frameBytes: f1)
        _ = b2.append(frameBytes: f0)

        XCTAssertNotEqual(try b1.terminal(), try b2.terminal())
    }

    func testBase64UrlNoPadding() {
        let data = Data([0xff, 0xee, 0xdd])
        let out = V4ChainSigner.base64UrlEncode(data)
        XCTAssertFalse(out.contains("="))
        XCTAssertFalse(out.contains("+"))
        XCTAssertFalse(out.contains("/"))
    }

    func testSpkiPrefixWrapSize() {
        // Raw P-256 public key is 65 bytes (0x04 || X || Y). Wrapping with
        // the SPKI prefix yields 91 bytes total.
        let raw = Data(repeating: 0x04, count: 65)
        let spki = V4ChainSigner.wrapRawP256IntoSpki(raw)
        XCTAssertEqual(spki.count, 91)
    }

    // Note: V4ChainSigner initialisation + signing require a real Secure
    // Enclave and cannot run on Simulator. See instrumented iOS tests.
    // TODO: device-verify end-to-end signing on iPhone 13 + iPhone 15.
}
