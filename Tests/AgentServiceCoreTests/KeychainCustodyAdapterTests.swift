import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import AgentServiceCore

struct KeychainCustodyAdapterTests {
    @Test(arguments: InvalidConfiguration.allCases, ["", "\0"])
    private func invalidScopeFailsBeforeAnyOperation(_ configuration: InvalidConfiguration, invalid: String) throws {
        let operations = KeychainTestOperations()
        #expect(throws: KeychainCustodyError.invalidConfiguration) {
            switch configuration {
            case .keyGroup:
                _ = try KeychainWrappingKeySource(accessGroup: invalid, walletID: "wallet", operations: operations)
            case .keyWallet:
                _ = try KeychainWrappingKeySource(accessGroup: "test.OpalAgent.Service", walletID: invalid, operations: operations)
            case .anchorGroup:
                _ = try KeychainContinuityAnchorStore(accessGroup: invalid, installationID: "installation", walletID: "wallet", operations: operations)
            case .anchorInstallation:
                _ = try KeychainContinuityAnchorStore(accessGroup: "test.OpalAgent.Service", installationID: invalid, walletID: "wallet", operations: operations)
            case .anchorWallet:
                _ = try KeychainContinuityAnchorStore(accessGroup: "test.OpalAgent.Service", installationID: "installation", walletID: invalid, operations: operations)
            }
        }
        #expect(operations.calls.isEmpty)
    }

    @Test func keyReaderConstructsTheExactServiceOnlyNonSynchronizingDataProtectionQuery() throws {
        let operations = KeychainTestOperations(items: [keychainTestItem()])
        let source = try wrappingSource(operations)
        if case .available(let key) = try source.wrappingKey() {
            #expect(key.withUnsafeBytes { Data($0) } == Data(repeating: 7, count: 32))
        } else {
            Issue.record("A matching valid key was not returned")
        }
        let call = try #require(operations.calls.first)
        guard case .copyMatching(let query) = call else {
            Issue.record("A key read must only copy its exact item")
            return
        }
        try expectReadQuery(query, service: "com.58opals.OpalAgent.wrapkey", account: "v1:6:wallet")
        #expect(operations.calls.count == 1)
        #expect(operations.addCount == 0 && operations.updateCount == 0)
    }

    @Test func namespaceEncodingSeparatesWalletsInstallationsAndDelimiterBearingComponents() throws {
        let operations = KeychainTestOperations()
        for wallet in ["wallet", "other", "é", "e\u{301}"] {
            _ = try KeychainWrappingKeySource(accessGroup: "test.OpalAgent.Service", walletID: wallet, operations: operations).wrappingKey()
        }
        for (installation, wallet) in [("a:b", "c"), ("a", "b:c"), ("installation", "wallet"), ("other", "wallet")] {
            _ = try KeychainContinuityAnchorStore(accessGroup: "test.OpalAgent.Service", installationID: installation, walletID: wallet, operations: operations).read()
        }
        let scopes = operations.calls.compactMap { call -> String? in
            guard case .copyMatching(let query) = call else { return nil }
            return query[kSecAttrAccount as String] as? String
        }
        #expect(scopes == ["v1:6:wallet", "v1:5:other", "v1:2:é", "v1:3:e\u{301}",
                           "v1:3:a:b1:c", "v1:1:a3:b:c", "v1:12:installation6:wallet", "v1:5:other6:wallet"])
        #expect(Set(scopes).count == scopes.count)
        let services = operations.calls.compactMap { call -> String? in
            guard case .copyMatching(let query) = call else { return nil }
            return query[kSecAttrService as String] as? String
        }
        #expect(services == Array(repeating: "com.58opals.OpalAgent.wrapkey", count: 4)
            + Array(repeating: "com.58opals.OpalAgent.continuityanchor", count: 4))
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecInteractionRequired, errSecNotAvailable, errSecAuthFailed])
    func unavailableReadsCannotBecomeMissingOrCreateAnItem(_ status: OSStatus) throws {
        let keyOperations = KeychainTestOperations()
        keyOperations.overrideCopy(call: 1, status: status)
        if case .inaccessible = try wrappingSource(keyOperations).wrappingKey() {} else {
            Issue.record("An inaccessible key was not distinguished from absence")
        }
        let anchorOperations = KeychainTestOperations()
        anchorOperations.overrideCopy(call: 1, status: status)
        do {
            _ = try anchorStore(anchorOperations).read()
            Issue.record("An inaccessible anchor must throw")
        } catch ContinuityStoreError.unavailable {} catch {
            Issue.record("Unexpected unavailable-anchor error: \(type(of: error))")
        }
        #expect(keyOperations.addCount == 0 && keyOperations.updateCount == 0)
        #expect(anchorOperations.addCount == 0 && anchorOperations.updateCount == 0)
    }

    @Test func exactQueryNoMatchReturnsAbsenceWithoutProvisioningOrFallback() throws {
        let operations = KeychainTestOperations(items: [keychainTestItem(accessGroup: "other.Service")])
        if case .missing = try wrappingSource(operations).wrappingKey() {} else {
            Issue.record("An exact-query no-match must report missing")
        }
        #expect(try anchorStore(operations).read() == nil)
        #expect(operations.copyCount == 2)
        #expect(operations.addCount == 0 && operations.updateCount == 0)
        #expect(operations.storedItems.count == 1)
    }

    @Test(arguments: [errSecMissingEntitlement, errSecParam, errSecDecode])
    func unexpectedSecurityStatusesRemainErrors(_ status: OSStatus) throws {
        let keyOperations = KeychainTestOperations()
        keyOperations.overrideCopy(call: 1, status: status)
        #expect(throws: KeychainCustodyError.operationFailed(status)) { try wrappingSource(keyOperations).wrappingKey() }
        let anchorOperations = KeychainTestOperations()
        anchorOperations.overrideCopy(call: 1, status: status)
        #expect(throws: KeychainCustodyError.operationFailed(status)) { try anchorStore(anchorOperations).read() }
        #expect(keyOperations.addCount == 0 && anchorOperations.addCount == 0)
    }

    @Test(arguments: MalformedResult.allCases)
    private func successfulStatusCannotAdmitMalformedKeychainResults(_ malformed: MalformedResult) throws {
        let keyOperations = KeychainTestOperations()
        keyOperations.overrideCopy(call: 1, status: errSecSuccess, result: malformed.result(item: keychainTestItem()))
        #expect(throws: KeychainCustodyError.invalidResult) { try wrappingSource(keyOperations).wrappingKey() }
        let anchorOperations = KeychainTestOperations()
        let item = try anchorItem(custodyTestAnchor())
        anchorOperations.overrideCopy(call: 1, status: errSecSuccess, result: malformed.result(item: item))
        #expect(throws: KeychainCustodyError.invalidResult) { try anchorStore(anchorOperations).read() }
    }

    @Test(arguments: [0, 16, 31, 33, 64])
    func wrappingKeysRequireExactly256Bits(_ byteCount: Int) throws {
        let operations = KeychainTestOperations(items: [keychainTestItem(data: Data(repeating: 7, count: byteCount))])
        #expect(throws: KeychainCustodyError.invalidResult) { try wrappingSource(operations).wrappingKey() }
        #expect(operations.addCount == 0 && operations.updateCount == 0)
    }

    @Test func anOpaqueReturnedAccessControlObjectDoesNotInvalidateOtherwiseValidItems() throws {
        let accessControl = try #require(SecAccessControlCreateWithFlags(nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [], nil))
        var keyItem = keychainTestItem()
        keyItem[kSecAttrAccessControl as String] = accessControl
        let keyOperations = KeychainTestOperations(items: [keyItem])
        if case .available(let key) = try wrappingSource(keyOperations).wrappingKey() {
            #expect(key.bitCount == 256)
        } else {
            Issue.record("A valid item with an opaque access-control object must remain readable")
        }
        let anchor = custodyTestAnchor()
        var item = try anchorItem(anchor)
        item[kSecAttrAccessControl as String] = accessControl
        let anchorOperations = KeychainTestOperations(items: [item])
        #expect(try anchorStore(anchorOperations).read() == anchor)
        #expect(keyOperations.addCount == 0 && keyOperations.updateCount == 0)
        #expect(anchorOperations.addCount == 0 && anchorOperations.updateCount == 0)
    }

    @Test(arguments: AnchorShape.allCases)
    private func anchorCodecPreservesTheCompleteExistingFormat(_ shape: AnchorShape) throws {
        let anchor = custodyTestAnchor(shape: shape)
        let operations = KeychainTestOperations(items: [try anchorItem(anchor)])
        #expect(try anchorStore(operations).read() == anchor)
        let call = try #require(operations.calls.first)
        guard case .copyMatching(let query) = call else {
            Issue.record("Expected an anchor read")
            return
        }
        try expectReadQuery(query, service: "com.58opals.OpalAgent.continuityanchor", account: "v1:12:installation6:wallet")
    }

    @Test(arguments: InvalidAnchor.allCases)
    private func malformedUnsupportedAndForeignAnchorsFailBeforeMutation(_ invalid: InvalidAnchor) throws {
        let anchor = invalid.anchor
        let operations = KeychainTestOperations(items: [try anchorItem(anchor)])
        let store = try anchorStore(operations)
        #expect(throws: (any Error).self) { try store.read() }
        #expect(throws: (any Error).self) { try store.write(anchor) }
        #expect(operations.addCount == 0 && operations.updateCount == 0)
    }

    @Test func malformedAnchorDataCannotBeTreatedAsMissing() throws {
        let operations = KeychainTestOperations(items: [keychainTestItem(service: "com.58opals.OpalAgent.continuityanchor",
            account: "v1:12:installation6:wallet", data: Data("not an anchor".utf8))])
        #expect(throws: (any Error).self) { try anchorStore(operations).read() }
        #expect(operations.addCount == 0 && operations.updateCount == 0)
    }

    @Test func firstAnchorWriteAddsItsExactProtectionAndExistingWritesUpdateOnlyCompleteData() throws {
        let operations = KeychainTestOperations()
        let store = try anchorStore(operations)
        let initial = custodyTestAnchor()
        try store.write(initial)
        #expect(try store.read() == initial)
        let addition = try #require(operations.calls.compactMap { call -> [String: Any]? in
            if case .add(let attributes) = call { return attributes }
            return nil
        }.first)
        #expect(addition[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(addition[kSecAttrAccessControl as String] == nil)
        #expect(addition[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(addition[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(addition[kSecAttrService as String] as? String == "com.58opals.OpalAgent.continuityanchor")
        #expect(addition[kSecAttrAccount as String] as? String == "v1:12:installation6:wallet")
        #expect(addition[kSecAttrAccessGroup as String] as? String == "test.OpalAgent.Service")
        #expect((addition[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        try expectWriteQuery(addition, includesData: true)
        let updated = custodyTestAnchor(shape: .pending)
        try store.write(updated)
        #expect(try store.read() == updated)
        let update = try #require(operations.calls.compactMap { call -> (query: [String: Any], attributes: [String: Any])? in
            if case .update(let query, let attributes) = call { return (query, attributes) }
            return nil
        }.last)
        #expect(Set(update.attributes.keys) == [kSecValueData as String])
        #expect(update.query[kSecReturnData as String] == nil && update.query[kSecReturnAttributes as String] == nil)
        #expect(update.query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(update.query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(update.query[kSecAttrAccount as String] as? String == "v1:12:installation6:wallet")
        #expect((update.query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        try expectWriteQuery(update.query, includesData: false)
        let written = try #require(update.attributes[kSecValueData as String] as? Data)
        #expect(try JSONDecoder().decode(ContinuityAnchor.self, from: written) == updated)
        #expect(operations.storedItems.count == 1)
    }

    @Test(arguments: [errSecNotAvailable, errSecMissingEntitlement, errSecParam])
    func failedAnchorAddsDoNotReportSuccessOrTryAnotherNamespace(_ status: OSStatus) throws {
        let operations = KeychainTestOperations()
        operations.overrideAdd(call: 1, status: status, persist: false)
        try expectAnchorWriteFailure(status) { try anchorStore(operations).write(custodyTestAnchor()) }
        #expect(operations.addCount == 1)
        #expect(operations.storedItems.isEmpty)
    }

    @Test(arguments: [errSecNotAvailable, errSecMissingEntitlement, errSecParam])
    func failedUpdatesCannotReplaceAnExistingAnchor(_ status: OSStatus) throws {
        let initial = custodyTestAnchor()
        let operations = KeychainTestOperations(items: [try anchorItem(initial)])
        operations.overrideUpdate(call: 1, status: status, persist: false)
        try expectAnchorWriteFailure(status) { try anchorStore(operations).write(custodyTestAnchor(shape: .pending)) }
        #expect(operations.addCount == 0)
        #expect(try anchorStore(operations).read() == initial)
    }

    @Test func existingUnexpectedProtectionCannotBeOverwrittenOrReplaced() throws {
        let initial = custodyTestAnchor()
        var item = try anchorItem(initial)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let operations = KeychainTestOperations(items: [item])
        #expect(throws: KeychainCustodyError.invalidResult) {
            try anchorStore(operations).write(custodyTestAnchor(shape: .pending))
        }
        #expect(operations.copyCount == 1)
        #expect(operations.updateCount == 0 && operations.addCount == 0)
        let retained = try #require(operations.storedItems.first)
        #expect(operations.storedItems.count == 1)
        #expect(retained[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(retained[kSecValueData as String] as? Data == item[kSecValueData as String] as? Data)
    }

    @Test(arguments: PreexistingAnchorFailure.allCases)
    private func unreadableExistingAnchorEvidenceCannotBeOverwrittenByAValidProposal(_ failure: PreexistingAnchorFailure) throws {
        let original = try failure.data()
        let item = keychainTestItem(service: "com.58opals.OpalAgent.continuityanchor",
            account: "v1:12:installation6:wallet", data: original)
        let operations = KeychainTestOperations(items: [item])
        #expect(throws: (any Error).self) {
            try anchorStore(operations).write(custodyTestAnchor(shape: .pending))
        }
        #expect(operations.copyCount == 1)
        #expect(operations.updateCount == 0 && operations.addCount == 0)
        let retained = try #require(operations.storedItems.first)
        #expect(operations.storedItems.count == 1)
        #expect(retained[kSecValueData as String] as? Data == original)
    }
}

private enum InvalidConfiguration: CaseIterable, Sendable {
    case keyGroup, keyWallet, anchorGroup, anchorInstallation, anchorWallet
}

private enum MalformedResult: CaseIterable, Equatable, Sendable {
    case nilValue, scalar, noData, nonData, noService, wrongService, wrongAccount, wrongGroup, wrongAccessibility, synchronized, noSynchronizable, accessControl

    func result(item: [String: Any]) -> CFTypeRef? {
        if self == .nilValue { return nil }
        if self == .scalar { return "unexpected" as NSString }
        var result = item
        switch self {
        case .nilValue, .scalar: break
        case .noData: result.removeValue(forKey: kSecValueData as String)
        case .nonData: result[kSecValueData as String] = "not data"
        case .noService: result.removeValue(forKey: kSecAttrService as String)
        case .wrongService: result[kSecAttrService as String] = "com.58opals.Wallet.personal"
        case .wrongAccount: result[kSecAttrAccount as String] = "v1:5:other"
        case .wrongGroup: result[kSecAttrAccessGroup as String] = "other.Service"
        case .wrongAccessibility: result[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .synchronized: result[kSecAttrSynchronizable as String] = true
        case .noSynchronizable: result.removeValue(forKey: kSecAttrSynchronizable as String)
        case .accessControl: result[kSecAttrAccessControl as String] = "unexpected interactive protection"
        }
        return result as NSDictionary
    }
}

enum AnchorShape: CaseIterable, Sendable { case initial, committed, pending, recovery, retained }

func custodyTestAnchor(shape: AnchorShape = .committed) -> ContinuityAnchor {
    let reference = StateReference(installationID: "installation", walletID: "wallet", network: "mainnet", generation: 3,
        commitID: "parent", formatVersion: 2, commitment: Data(repeating: 1, count: 32), history: .complete)
    var anchor = ContinuityAnchor(committed: reference)
    switch shape {
    case .initial:
        anchor.committed = nil
        anchor.recovery = RecoveryLatch(id: "new-wallet", targetGeneration: 1)
    case .committed: break
    case .pending:
        var target = reference
        target.commitID = "target"
        target.commitment = Data(repeating: 2, count: 32)
        anchor.pending = PendingState(parent: reference, target: target, classification: "receive")
    case .recovery:
        anchor.recovery = RecoveryLatch(id: "recovery", targetGeneration: 4, observedCommitted: reference, reason: .ownerReset)
    case .retained:
        var target = reference
        target.commitID = "retained-target"
        target.commitment = Data(repeating: 2, count: 32)
        anchor.originalProofs = [RetainedProof(reference: reference, parent: nil, classification: "committed"),
                                 RetainedProof(reference: target, parent: reference, classification: "stagedTarget")]
    }
    return anchor
}

private enum InvalidAnchor: CaseIterable, Sendable {
    case version, referenceVersion, commitmentLength, installation, wallet, pendingParent, recoveryObservedScope

    var anchor: ContinuityAnchor {
        var result = custodyTestAnchor()
        switch self {
        case .version: result.formatVersion = 99
        case .referenceVersion: result.committed?.formatVersion = 99
        case .commitmentLength: result.committed?.commitment = Data([1])
        case .installation: result.committed?.installationID = "other"
        case .wallet: result.committed?.walletID = "other"
        case .pendingParent:
            result = custodyTestAnchor(shape: .pending)
            result.pending?.parent?.commitID = "other"
        case .recoveryObservedScope:
            result = custodyTestAnchor(shape: .recovery)
            result.recovery?.observedCommitted?.installationID = "other"
        }
        return result
    }
}

private enum PreexistingAnchorFailure: CaseIterable, Sendable {
    case malformedJSON, unsupportedVersion, foreignWallet, foreignRecoveryScope

    func data() throws -> Data {
        let anchor: ContinuityAnchor
        switch self {
        case .malformedJSON: return Data("not a retained anchor".utf8)
        case .unsupportedVersion: anchor = InvalidAnchor.version.anchor
        case .foreignWallet: anchor = InvalidAnchor.wallet.anchor
        case .foreignRecoveryScope: anchor = InvalidAnchor.recoveryObservedScope.anchor
        }
        return try JSONEncoder().encode(anchor)
    }
}

private func wrappingSource(_ operations: KeychainTestOperations) throws -> KeychainWrappingKeySource {
    try KeychainWrappingKeySource(accessGroup: "test.OpalAgent.Service", walletID: "wallet", operations: operations)
}

private func anchorStore(_ operations: KeychainTestOperations) throws -> KeychainContinuityAnchorStore {
    try KeychainContinuityAnchorStore(accessGroup: "test.OpalAgent.Service", installationID: "installation", walletID: "wallet", operations: operations)
}

private func anchorItem(_ anchor: ContinuityAnchor) throws -> [String: Any] {
    keychainTestItem(service: "com.58opals.OpalAgent.continuityanchor", account: "v1:12:installation6:wallet",
                     data: try JSONEncoder().encode(anchor))
}

private func expectedQuery(service: String, account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account,
     kSecAttrAccessGroup as String: "test.OpalAgent.Service",
     kSecUseDataProtectionKeychain as String: true,
     kSecAttrSynchronizable as String: false,
     kSecReturnAttributes as String: true,
     kSecReturnData as String: true,
     kSecMatchLimit as String: kSecMatchLimitOne]
}

private func expectReadQuery(_ query: [String: Any], service: String, account: String) throws {
    let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
    #expect(context.interactionNotAllowed)
    var attributes = query
    attributes.removeValue(forKey: kSecUseAuthenticationContext as String)
    #expect(NSDictionary(dictionary: attributes).isEqual(to: expectedQuery(service: service, account: account)))
}

private func expectWriteQuery(_ query: [String: Any], includesData: Bool) throws {
    let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
    #expect(context.interactionNotAllowed)
    var attributes = query
    attributes.removeValue(forKey: kSecUseAuthenticationContext as String)
    if includesData {
        _ = try #require(attributes.removeValue(forKey: kSecValueData as String) as? Data)
    }
    let expected: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.58opals.OpalAgent.continuityanchor",
        kSecAttrAccount as String: "v1:12:installation6:wallet",
        kSecAttrAccessGroup as String: "test.OpalAgent.Service",
        kSecUseDataProtectionKeychain as String: true,
        kSecAttrSynchronizable as String: false,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    #expect(NSDictionary(dictionary: attributes).isEqual(to: expected))
}

private func expectAnchorWriteFailure(_ status: OSStatus, operation: () throws -> Void) throws {
    if status == errSecNotAvailable {
        do {
            try operation()
            Issue.record("Unavailable Keychain write must throw")
        } catch ContinuityStoreError.unavailable {}
    } else {
        #expect(throws: KeychainCustodyError.operationFailed(status)) { try operation() }
    }
}
