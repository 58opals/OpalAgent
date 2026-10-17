import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

struct PayloadProtectionTests {
    @Test func encryptedPayloadRoundTripsThroughTheCodableEnvelope() throws {
        let protector = encryptedProtector()
        let plaintext = Data("disposable request body".utf8)
        let protected = try protector.protect(plaintext)
        #expect(protected.body != plaintext)
        #expect(protected.profile == .encrypted)
        let decoded = try JSONDecoder().decode(ProtectedPayload.self, from: JSONEncoder().encode(protected))
        #expect(try protector.open(decoded) == plaintext)
        #expect(try protector.protect(plaintext).body != protected.body)
    }

    @Test(arguments: UnavailableWrappingKey.allCases)
    private func missingAndInaccessibleKeysNeverFallBackOrRegenerate(state: UnavailableWrappingKey) throws {
        let payload = try encryptedProtector().protect(Data("disposable request body".utf8))
        let protector = PayloadProtector(profile: .encrypted, walletID: "wallet-a", wrappingKey: state.availability)
        #expect(throws: state.expectedError) { try protector.protect(Data()) }
        #expect(throws: state.expectedError) { try protector.open(payload) }
    }

    @Test func unsupportedPlaintextAndProtectionMetadataAreRejectedInBothDirections() throws {
        let encrypted = encryptedProtector()
        let unsupported = PayloadProtector(profile: .plaintext, walletID: "wallet-a", wrappingKey: .available(payloadKey))
        let clearPayload = ProtectedPayload(profile: .plaintext, walletID: "wallet-a", body: Data("disposable".utf8))
        let sealedPayload = try encrypted.protect(Data("disposable".utf8))
        #expect(throws: PayloadProtectionError.protectionMismatch) { try unsupported.protect(Data()) }
        #expect(throws: PayloadProtectionError.protectionMismatch) { try unsupported.open(clearPayload) }
        #expect(throws: PayloadProtectionError.protectionMismatch) { try encrypted.open(clearPayload) }
        #expect(throws: PayloadProtectionError.protectionMismatch) { try unsupported.open(sealedPayload) }
        var forged = clearPayload
        forged.profile = .encrypted
        #expect(throws: PayloadProtectionError.authenticationFailed) { try encrypted.open(forged) }
        var relabeled = sealedPayload
        relabeled.profile = .plaintext
        #expect(throws: PayloadProtectionError.protectionMismatch) { try unsupported.open(relabeled) }
    }

    @Test func authenticatedEncryptionRejectsTamperingMalformedBytesAndWrongKeys() throws {
        let protector = encryptedProtector()
        let payload = try protector.protect(Data("disposable".utf8))
        var tampered = payload
        tampered.body[tampered.body.count - 1] ^= 1
        #expect(throws: PayloadProtectionError.authenticationFailed) { try protector.open(tampered) }
        var malformed = payload
        malformed.body = Data([1, 2, 3])
        #expect(throws: PayloadProtectionError.authenticationFailed) { try protector.open(malformed) }
        let wrongKey = PayloadProtector(
            profile: .encrypted, walletID: "wallet-a",
            wrappingKey: .available(SymmetricKey(data: Data(repeating: 9, count: 32)))
        )
        #expect(throws: PayloadProtectionError.authenticationFailed) { try wrongKey.open(payload) }
    }

    @Test func walletContextIsCheckedAndAuthenticated() throws {
        let protector = encryptedProtector()
        let payload = try protector.protect(Data("disposable".utf8))
        let otherWallet = PayloadProtector(profile: .encrypted, walletID: "wallet-b", wrappingKey: .available(payloadKey))
        #expect(throws: PayloadProtectionError.contextMismatch) { try otherWallet.open(payload) }
        var relabeled = payload
        relabeled.walletID = "wallet-b"
        #expect(throws: PayloadProtectionError.authenticationFailed) { try otherWallet.open(relabeled) }
    }

    @Test func invalidKeySizeCannotEncryptOrOpenAPayload() throws {
        let payload = try encryptedProtector().protect(Data())
        let protector = PayloadProtector(
            profile: .encrypted, walletID: "wallet-a",
            wrappingKey: .available(SymmetricKey(data: Data(repeating: 1, count: 16)))
        )
        #expect(throws: PayloadProtectionError.invalidWrappingKey) { try protector.protect(Data()) }
        #expect(throws: PayloadProtectionError.invalidWrappingKey) { try protector.open(payload) }
    }
}

private let payloadKey = SymmetricKey(data: Data(repeating: 7, count: 32))

private func encryptedProtector() -> PayloadProtector {
    PayloadProtector(profile: .encrypted, walletID: "wallet-a", wrappingKey: .available(payloadKey))
}

private enum UnavailableWrappingKey: CaseIterable, Sendable {
    case missing, inaccessible

    var availability: WrappingKeyAvailability {
        switch self {
        case .missing: .missing
        case .inaccessible: .inaccessible
        }
    }

    var expectedError: PayloadProtectionError {
        switch self {
        case .missing: .wrappingKeyMissing
        case .inaccessible: .wrappingKeyInaccessible
        }
    }
}
