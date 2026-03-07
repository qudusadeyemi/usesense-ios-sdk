#if canImport(DeviceCheck) && canImport(CryptoKit)
import DeviceCheck
import CryptoKit
import Foundation

actor AppAttestManager {
    private let service = DCAppAttestService.shared
    private let keychain = KeychainHelper.shared
    private static let keychainKeyId = "com.usesense.sdk.appAttest.keyId"
    private static let keychainAttested = "com.usesense.sdk.appAttest.attested"

    var isSupported: Bool { service.isSupported }

    // MARK: - Phase 1: Attestation (one-time key registration)

    func attestIfNeeded(apiClient: UseSenseAPIClient) async throws {
        guard isSupported else { return }
        if keychain.string(forKey: Self.keychainKeyId) != nil,
           keychain.bool(forKey: Self.keychainAttested) == true {
            return
        }

        let keyId = try await service.generateKey()
        keychain.set(keyId, forKey: Self.keychainKeyId)

        let challenge = try await apiClient.requestAttestationChallenge()
        let clientDataHash = Data(SHA256.hash(data: challenge))
        let attestationObject = try await service.attestKey(keyId, clientDataHash: clientDataHash)

        try await apiClient.registerAttestation(
            keyId: keyId, attestationObject: attestationObject, challenge: challenge
        )
        keychain.set(true, forKey: Self.keychainAttested)
    }

    // MARK: - Phase 2: Assertion (per-session proof for DeepSense)

    func generateAssertion(nonce: String) async throws -> String? {
        guard isSupported,
              let keyId = keychain.string(forKey: Self.keychainKeyId),
              keychain.bool(forKey: Self.keychainAttested) == true
        else { return nil }

        let clientData = Data(nonce.utf8)
        let clientDataHash = Data(SHA256.hash(data: clientData))
        let assertionObject = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
        return assertionObject.base64EncodedString()
    }

    /// Safe version that never throws. App Attest failures must not block verification.
    func generateAssertionSafe(nonce: String) async -> String? {
        guard isSupported else { return nil }
        do {
            return try await generateAssertion(nonce: nonce)
        } catch {
            if (error as NSError).code == 2 { // DCError.invalidKey
                rotateKey()
            }
            return nil
        }
    }

    func rotateKey() {
        keychain.delete(forKey: Self.keychainKeyId)
        keychain.delete(forKey: Self.keychainAttested)
    }
}
#endif
