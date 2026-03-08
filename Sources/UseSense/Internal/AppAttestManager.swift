#if canImport(DeviceCheck) && canImport(CryptoKit)
import DeviceCheck
import CryptoKit
import Foundation

actor AppAttestManager {
    private let service = DCAppAttestService.shared
    private let keychain = KeychainHelper.shared

    private static let keychainKeyId = "com.usesense.sdk.appAttest.keyId"
    private static let keychainAttestation = "com.usesense.sdk.appAttest.attestation"

    // Retry attestKey() up to 2 times with exponential backoff (Apple network call)
    private static let attestRetryDelays: [UInt64] = [1_000_000_000, 3_000_000_000] // 1s, 3s

    var isSupported: Bool { service.isSupported }

    // MARK: - Key Generation

    /// Ensures an App Attest key exists, generating one if needed.
    /// Returns the key ID, or nil if App Attest is not supported.
    func ensureKeyExists() async throws -> String? {
        guard isSupported else { return nil }

        if let existingKeyId = keychain.string(forKey: Self.keychainKeyId) {
            return existingKeyId
        }

        let keyId = try await service.generateKey()
        keychain.set(keyId, forKey: Self.keychainKeyId)
        return keyId
    }

    // MARK: - Attestation (one-time per key, stored in Keychain)

    /// Attests the key with Apple's servers. Only called once per key; result is stored.
    /// clientDataHash = SHA256(nonce). Uses the first session nonce.
    ///
    /// - Parameter nonce: The session nonce string from createSession
    /// - Returns: Base64-encoded attestation object, or nil
    func attestKey(nonce: String) async throws -> String? {
        guard let keyId = keychain.string(forKey: Self.keychainKeyId) else {
            return nil
        }

        // Check if we already have a stored attestation
        if let existingAttestation = keychain.getData(forKey: Self.keychainAttestation) {
            return existingAttestation.base64EncodedString()
        }

        // Compute clientDataHash = SHA256(nonce)
        let nonceData = Data(nonce.utf8)
        let clientDataHash = Data(SHA256.hash(data: nonceData))

        // Attest the key with retry (Apple network call, can be slow/flaky)
        var attestation: Data?
        var lastError: Error?

        // First attempt (no delay)
        do {
            attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
        } catch {
            lastError = error
            // Retry up to 2 more times with backoff
            for delay in Self.attestRetryDelays {
                try? await Task.sleep(nanoseconds: delay)
                do {
                    attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                }
            }
        }

        guard let attestationData = attestation else {
            if let error = lastError {
                throw error
            }
            return nil
        }

        // Store for future sessions (attestation is reusable)
        keychain.setData(attestationData, forKey: Self.keychainAttestation)
        return attestationData.base64EncodedString()
    }

    // MARK: - Assertion (per session)

    /// Generates a per-session assertion proving this request came from the attested device.
    /// This is fast (~50-100ms, local crypto only, no Apple network call).
    ///
    /// - Parameter nonce: The session nonce string from createSession
    /// - Returns: Base64-encoded assertion object, or nil
    func generateSessionAssertion(nonce: String) async throws -> String? {
        guard let keyId = keychain.string(forKey: Self.keychainKeyId) else {
            return nil
        }

        let nonceData = Data(nonce.utf8)
        let clientDataHash = Data(SHA256.hash(data: nonceData))

        let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
        return assertion.base64EncodedString()
    }

    // MARK: - Build web_integrity fields

    /// Returns the App Attest fields to merge into the web_integrity / channel_integrity metadata.
    /// Call this during metadata assembly, after receiving the session nonce.
    ///
    /// - Parameter sessionNonce: The nonce from createSession response
    /// - Returns: Dictionary of fields to merge into channel_integrity
    func getAttestFields(sessionNonce: String) async -> [String: Any] {
        var fields: [String: Any] = [
            "app_attest_supported": service.isSupported
        ]

        guard service.isSupported else {
            return fields
        }

        do {
            // Ensure key exists
            guard let keyId = try await ensureKeyExists() else {
                return fields
            }
            fields["app_attest_key_id"] = keyId

            // Get or create attestation (one-time, stored in keychain)
            if let attestation = try await attestKey(nonce: sessionNonce) {
                fields["app_attest_attestation"] = attestation
            }

            // Generate per-session assertion
            if let assertion = try await generateSessionAssertion(nonce: sessionNonce) {
                fields["app_attest_assertion"] = assertion
            }

            fields["app_attest_nonce_used"] = sessionNonce

        } catch let error as NSError where error.code == 2 {
            // DCError.invalidKey — key was invalidated (reinstall, restore, etc.)
            // Rotate key so the NEXT session gets a fresh one
            rotateKey()
            print("[UseSense] App Attest key invalidated, rotated for next session: \(error.localizedDescription)")
        } catch {
            // Log but don't crash — the server will fall back to presence-based scoring
            print("[UseSense] App Attest error: \(error.localizedDescription)")
        }

        return fields
    }

    // MARK: - Key Rotation

    /// Clears stored key and attestation, forcing fresh generation on next use.
    func rotateKey() {
        keychain.delete(forKey: Self.keychainKeyId)
        keychain.delete(forKey: Self.keychainAttestation)
    }
}
#endif
