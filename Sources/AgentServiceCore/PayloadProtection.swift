import CryptoKit
import Foundation

enum PayloadProtectionProfile: String, Codable, Sendable {
    case plaintext
    case encrypted
}

enum WrappingKeyAvailability: Sendable {
    case available(SymmetricKey)
    case missing
    case inaccessible
}

struct ProtectedPayload: Codable, Equatable, Sendable {
    var profile: PayloadProtectionProfile
    var walletID: String
    var body: Data
}

enum PayloadProtectionError: Error, Equatable {
    case wrappingKeyMissing
    case wrappingKeyInaccessible
    case invalidWrappingKey
    case protectionMismatch
    case contextMismatch
    case authenticationFailed
}

struct PayloadProtector: Sendable {
    let profile: PayloadProtectionProfile
    let walletID: String
    let wrappingKey: WrappingKeyAvailability

    func protect(_ plaintext: Data) throws -> ProtectedPayload {
        switch profile {
        case .plaintext:
            throw PayloadProtectionError.protectionMismatch
        case .encrypted:
            let key = try availableKey()
            do {
                let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedContext())
                guard let body = sealed.combined else { throw PayloadProtectionError.authenticationFailed }
                return ProtectedPayload(profile: profile, walletID: walletID, body: body)
            } catch {
                throw PayloadProtectionError.authenticationFailed
            }
        }
    }

    func open(_ payload: ProtectedPayload) throws -> Data {
        guard payload.profile == profile else { throw PayloadProtectionError.protectionMismatch }
        guard payload.walletID == walletID else { throw PayloadProtectionError.contextMismatch }
        switch profile {
        case .plaintext:
            throw PayloadProtectionError.protectionMismatch
        case .encrypted:
            let key = try availableKey()
            do {
                let sealed = try AES.GCM.SealedBox(combined: payload.body)
                return try AES.GCM.open(sealed, using: key, authenticating: authenticatedContext())
            } catch {
                throw PayloadProtectionError.authenticationFailed
            }
        }
    }

    private func availableKey() throws -> SymmetricKey {
        switch wrappingKey {
        case .missing:
            throw PayloadProtectionError.wrappingKeyMissing
        case .inaccessible:
            throw PayloadProtectionError.wrappingKeyInaccessible
        case .available(let key):
            guard key.bitCount == 256 else { throw PayloadProtectionError.invalidWrappingKey }
            return key
        }
    }

    private func authenticatedContext() -> Data {
        var context = Data("OpalAgentPayload/v1".utf8)
        for value in [profile.rawValue, walletID] {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { context.append(contentsOf: $0) }
            context.append(bytes)
        }
        return context
    }
}
