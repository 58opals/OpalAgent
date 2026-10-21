import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import AgentServiceCore

struct KeychainWrappingKeyProvisioningTests {
    @Test func freshProvisioningAddsTheExactCandidateAndVerifiesItsPersistedIdentity() throws {
        let operations = KeychainTestOperations()
        let entropy = ProvisioningTestEntropy()
        let provisioner = try makeProvisioner(operations, entropy: entropy)

        let returned = try provisioner.provision()

        #expect(keyBytes(returned) == provisioningCandidate)
        #expect(entropy.calls == 1)
        #expect(operations.addCount == 1 && operations.updateCount == 0)
        #expect(operations.copyCount == 2)
        let calls = operations.calls
        #expect(calls.count == 3)
        guard calls.count == 3,
              case .copyMatching(let preflight) = calls[0],
              case .add(let added) = calls[1],
              case .copyMatching(let readBack) = calls[2] else {
            Issue.record("Provisioning must check absence, add once, and read back the exact item")
            return
        }
        try expectProvisioningReadQuery(preflight)
        try expectProvisioningReadQuery(readBack)
        let context = try #require(added[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed)
        var actual = added
        actual.removeValue(forKey: kSecUseAuthenticationContext as String)
        let expected: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.58opals.OpalAgent.wrapkey",
            kSecAttrAccount as String: "v1:6:wallet",
            kSecAttrAccessGroup as String: "test.OpalAgent.Service",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: provisioningCandidate
        ]
        #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
        #expect(operations.storedItems.count == 1)
        let stored = try #require(operations.storedItems.first)
        #expect(stored[kSecValueData as String] as? Data == provisioningCandidate)
    }

    @Test func absenceInspectionDoesNotGenerateAndCannotAuthorizeALaterReplacement() throws {
        let operations = KeychainTestOperations()
        let entropy = ProvisioningTestEntropy()
        let provisioner = try makeProvisioner(operations, entropy: entropy)
        try provisioner.requireAbsent()
        #expect(entropy.calls == 0)
        #expect(operations.addCount == 0 && operations.updateCount == 0)
        operations.insert(keychainTestItem(data: competingCandidate))
        let existing = operations.storedItems as NSArray

        #expect(throws: ContinuityError.invalidState) { try provisioner.provision() }

        #expect(entropy.calls == 0)
        #expect(operations.addCount == 0 && operations.updateCount == 0)
        #expect(existing.isEqual(operations.storedItems as NSArray))
    }

    @Test(arguments: ProvisioningPreflightFailure.allCases)
    private func unusableOrExistingItemsPreventEntropyAndAllWrites(_ failure: ProvisioningPreflightFailure) throws {
        var item = keychainTestItem(data: competingCandidate)
        if failure == .malformed { item[kSecValueData as String] = "not key bytes" }
        let operations = KeychainTestOperations(items: failure == .inaccessible ? [] : [item])
        if failure == .inaccessible {
            operations.overrideCopy(call: 1, status: errSecInteractionNotAllowed)
            operations.overrideCopy(call: 2, status: errSecInteractionNotAllowed)
        }
        let entropy = ProvisioningTestEntropy()
        let provisioner = try makeProvisioner(operations, entropy: entropy)
        let before = operations.storedItems as NSArray

        switch failure {
        case .existing:
            #expect(throws: ContinuityError.invalidState) { try provisioner.requireAbsent() }
            #expect(throws: ContinuityError.invalidState) { try provisioner.provision() }
        case .malformed:
            #expect(throws: KeychainCustodyError.invalidResult) { try provisioner.requireAbsent() }
            #expect(throws: KeychainCustodyError.invalidResult) { try provisioner.provision() }
        case .inaccessible:
            #expect(throws: ContinuityError.keyUnavailable) { try provisioner.requireAbsent() }
            #expect(throws: ContinuityError.keyUnavailable) { try provisioner.provision() }
        }

        #expect(entropy.calls == 0)
        #expect(operations.addCount == 0 && operations.updateCount == 0)
        #expect(before.isEqual(operations.storedItems as NSArray))
    }

    @Test func entropyFailureNeverAddsAnItem() throws {
        let operations = KeychainTestOperations()
        let entropy = ProvisioningTestEntropy()
        let provisioner = try KeychainWrappingKeyProvisioner(accessGroup: "test.OpalAgent.Service", walletID: "wallet",
            operations: operations, generateKey: {
                _ = entropy.generate()
                throw ProvisioningTestFailure.entropyUnavailable
            })

        #expect(throws: ProvisioningTestFailure.entropyUnavailable) { try provisioner.provision() }

        #expect(entropy.calls == 1)
        #expect(operations.addCount == 0 && operations.updateCount == 0)
        #expect(operations.storedItems.isEmpty)
    }

    @Test(arguments: [16, 64])
    func invalidGeneratedKeySizesNeverReachAdd(_ size: Int) throws {
        let operations = KeychainTestOperations()
        let entropy = ProvisioningTestEntropy(bytes: Data(repeating: 0x37, count: size))

        #expect(throws: KeychainCustodyError.invalidResult) { try makeProvisioner(operations, entropy: entropy).provision() }

        #expect(entropy.calls == 1)
        #expect(operations.addCount == 0 && operations.updateCount == 0)
        #expect(operations.storedItems.isEmpty)
    }

    @Test(arguments: ProvisioningAddFailure.allCases)
    private func everyUnsuccessfulAddRefusesProvisioningAndRetainsAnyPersistedBytes(_ failure: ProvisioningAddFailure) throws {
        let operations = KeychainTestOperations()
        operations.overrideAdd(call: 1, status: failure.status, persist: failure.persists)
        let entropy = ProvisioningTestEntropy()

        #expect(throws: KeychainCustodyError.operationFailed(failure.status)) { try makeProvisioner(operations, entropy: entropy).provision() }

        #expect(entropy.calls == 1)
        #expect(operations.addCount == 1 && operations.updateCount == 0)
        if failure.persists {
            let stored = try #require(operations.storedItems.first)
            #expect(operations.storedItems.count == 1)
            #expect(stored[kSecValueData as String] as? Data == provisioningCandidate)
        } else {
            #expect(operations.storedItems.isEmpty)
        }
    }

    @Test func successfulAddWithoutPersistenceCannotReturnAKey() throws {
        let operations = KeychainTestOperations()
        operations.overrideAdd(call: 1, status: errSecSuccess, persist: false)
        let entropy = ProvisioningTestEntropy()

        #expect(throws: KeychainCustodyError.invalidResult) { try makeProvisioner(operations, entropy: entropy).provision() }

        #expect(entropy.calls == 1)
        #expect(operations.copyCount == 2)
        #expect(operations.addCount == 1 && operations.updateCount == 0)
        #expect(operations.storedItems.isEmpty)
    }

    @Test(arguments: ProvisioningReadbackFailure.allCases)
    private func failedReadbackCannotReturnOrReplaceTheAttemptedCandidate(_ failure: ProvisioningReadbackFailure) throws {
        let operations = KeychainTestOperations()
        switch failure {
        case .inaccessible:
            operations.overrideCopy(call: 2, status: errSecInteractionNotAllowed)
        case .malformed:
            operations.overrideCopy(call: 2, status: errSecSuccess, result: "not an item" as NSString)
        case .foreignScope:
            let foreign = keychainTestItem(account: "v1:5:other", data: provisioningCandidate)
            operations.overrideCopy(call: 2, status: errSecSuccess, result: foreign as NSDictionary)
        case .differentKey:
            let different = keychainTestItem(data: competingCandidate)
            operations.overrideCopy(call: 2, status: errSecSuccess, result: different as NSDictionary)
        }
        let entropy = ProvisioningTestEntropy()

        #expect(throws: KeychainCustodyError.invalidResult) { try makeProvisioner(operations, entropy: entropy).provision() }

        #expect(entropy.calls == 1)
        #expect(operations.addCount == 1 && operations.updateCount == 0)
        let stored = try #require(operations.storedItems.first)
        #expect(operations.storedItems.count == 1)
        #expect(stored[kSecValueData as String] as? Data == provisioningCandidate)
    }

    @Test func aCompetingKeyInsertedAfterAbsenceWinsWithoutBeingAdoptedOrOverwritten() throws {
        let operations = KeychainTestOperations()
        let entropy = ProvisioningTestEntropy()
        let provisioner = try KeychainWrappingKeyProvisioner(accessGroup: "test.OpalAgent.Service", walletID: "wallet",
            operations: operations, generateKey: {
                let candidate = entropy.generate()
                operations.insert(keychainTestItem(data: competingCandidate))
                return candidate
            })

        #expect(throws: KeychainCustodyError.operationFailed(errSecDuplicateItem)) { try provisioner.provision() }

        #expect(entropy.calls == 1)
        #expect(operations.addCount == 1 && operations.updateCount == 0)
        let stored = try #require(operations.storedItems.first)
        #expect(operations.storedItems.count == 1)
        #expect(stored[kSecValueData as String] as? Data == competingCandidate)
    }

    @Test func failureAfterPersistenceLeavesAKeyThatAFreshAttemptMustNotRegenerate() throws {
        let operations = KeychainTestOperations()
        operations.overrideAdd(call: 1, status: errSecNotAvailable, persist: true)
        let entropy = ProvisioningTestEntropy()
        #expect(throws: KeychainCustodyError.operationFailed(errSecNotAvailable)) { try makeProvisioner(operations, entropy: entropy).provision() }
        let before = operations.storedItems as NSArray

        #expect(throws: ContinuityError.invalidState) { try makeProvisioner(operations, entropy: entropy).provision() }

        #expect(entropy.calls == 1)
        #expect(operations.addCount == 1 && operations.updateCount == 0)
        #expect(before.isEqual(operations.storedItems as NSArray))
    }
}

private enum ProvisioningPreflightFailure: CaseIterable, Sendable {
    case existing, malformed, inaccessible
}

private enum ProvisioningReadbackFailure: CaseIterable, Sendable {
    case inaccessible, malformed, foreignScope, differentKey
}

private enum ProvisioningAddFailure: CaseIterable, Sendable {
    case unavailableBeforeWrite, unavailableAfterWrite, missingEntitlement, duplicateAfterWrite

    var status: OSStatus {
        switch self {
        case .unavailableBeforeWrite, .unavailableAfterWrite: errSecNotAvailable
        case .missingEntitlement: errSecMissingEntitlement
        case .duplicateAfterWrite: errSecDuplicateItem
        }
    }

    var persists: Bool { self == .unavailableAfterWrite || self == .duplicateAfterWrite }
}

private enum ProvisioningTestFailure: Error, Equatable { case entropyUnavailable }

/// These fixed bytes are permanently disposable synthetic test material.
private let provisioningCandidate = Data(repeating: 0x37, count: 32)
private let competingCandidate = Data(repeating: 0x59, count: 32)

private final class ProvisioningTestEntropy: @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private var generated = 0

    init(bytes: Data = provisioningCandidate) { self.bytes = bytes }
    var calls: Int { lock.withLock { generated } }

    func generate() -> SymmetricKey {
        lock.withLock { generated += 1 }
        return SymmetricKey(data: bytes)
    }
}

private func makeProvisioner(_ operations: KeychainTestOperations, entropy: ProvisioningTestEntropy) throws -> KeychainWrappingKeyProvisioner {
    try KeychainWrappingKeyProvisioner(accessGroup: "test.OpalAgent.Service", walletID: "wallet",
        operations: operations, generateKey: { entropy.generate() })
}

private func keyBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

private func expectProvisioningReadQuery(_ query: [String: Any]) throws {
    let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
    #expect(context.interactionNotAllowed)
    var actual = query
    actual.removeValue(forKey: kSecUseAuthenticationContext as String)
    let expected: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.58opals.OpalAgent.wrapkey",
        kSecAttrAccount as String: "v1:6:wallet",
        kSecAttrAccessGroup as String: "test.OpalAgent.Service",
        kSecAttrSynchronizable as String: false,
        kSecUseDataProtectionKeychain as String: true,
        kSecReturnAttributes as String: true,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
}
