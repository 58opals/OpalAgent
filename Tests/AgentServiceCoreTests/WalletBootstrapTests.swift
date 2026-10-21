import AgentValues
import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import AgentServiceCore

struct WalletBootstrapTests {
    @Test func sameStoreReopensWithIdenticalCustodyAndNoCreationCapability() async throws {
        let fixture = BootstrapFixture()
        defer { fixture.remove() }
        let original = try await fixture.initializeAndClose()
        let files = try fixture.files()
        let items = fixture.operations.backend.storedItems as NSArray
        let writes = fixture.operations.writes
        let store = try fixture.reopen()
        let reopened = try store.continuity.inspect { $0 }
        #expect(reopened == original)
        #expect(store.scope?.installationID.uuidString == original.installationID)
        #expect(store.scope?.walletID.uuidString == original.authorization.walletID)
        #expect(reopened.mode == .restricted && reopened.history == .complete)
        #expect(reopened.authorization.generation == 1 && reopened.authorization.grants.isEmpty)
        #expect(try fixture.files() == files)
        #expect(items.isEqual(fixture.operations.backend.storedItems as NSArray))
        #expect(fixture.operations.writes == writes)
        #expect(fixture.seeds.generated == 1 && fixture.seeds.keys == 1)
        #expect(try await #require(store.vault).open(#require(reopened.custody)) == bootstrapMnemonic)

        let service = try fixture.service(store)
        await #expect(throws: ServiceProblem(.unavailable)) {
            try await service.send(OwnerControlRequest(call: .createWallet(network: .mainnet)),
                                   connection: fixture.connection())
        }
        #expect(try store.continuity.inspect { $0 } == original)
        #expect(fixture.seeds.generated == 1 && fixture.seeds.keys == 1)
        #expect(fixture.operations.writes == writes)
    }

    @Test func retainedOwnerEndpointSeesTheEngineConfiguredAfterCreation() async throws {
        let fixture = BootstrapFixture()
        defer { fixture.remove() }
        let store = try fixture.fresh()
        let service = try fixture.service(store)
        let connection = fixture.connection()
        let created = try await service.send(OwnerControlRequest(call: .createWallet(network: .mainnet)),
                                             connection: connection)
        guard case .createWallet(let status) = created.result else { Issue.record("Expected created status"); return }
        let wallet = try #require(status.wallet)
        _ = try await service.send(OwnerControlRequest(call: .enableWallet(wallet)), connection: connection)
        _ = try store.paymentEngine(boundary: BootstrapUnusedBoundary(), clock: BootstrapClock())
        let result = try await service.send(OwnerControlRequest(call: .setApprovalPolicy(
            ApprovalPolicyRequest(wallet: wallet, expectedRevision: 1, approvalRequired: true))), connection: connection)
        guard case .setApprovalPolicy(let policy) = result.result else { Issue.record("Expected policy projection"); return }
        #expect(policy.revision == 2 && policy.approvalRequired)
        #expect(try store.continuity.inspect { $0.paymentPolicy.approvalRequired })
        #expect(throws: DurableWalletStoreError.effectEngineAlreadyConfigured) {
            try store.paymentEngine(boundary: BootstrapUnusedBoundary())
        }
    }

    @Test(arguments: BootstrapScopeFault.allCases)
    private func inconsistentOrMissingEvidenceNeverCreatesOrSelectsAnotherNamespace(_ fault: BootstrapScopeFault) async throws {
        let fixture = BootstrapFixture()
        let other = BootstrapFixture(operations: fixture.operations)
        defer { fixture.remove(); other.remove() }
        _ = try await fixture.initializeAndClose()
        _ = try await other.initializeAndClose()
        let scope = fixture.directory.appendingPathComponent("custody.scope")
        let journal = fixture.directory.appendingPathComponent("journal.sqlite")
        let lease = fixture.directory.appendingPathComponent("writer.lock")
        switch fault {
        case .missingLocator: try FileManager.default.removeItem(at: scope)
        case .emptyLocator: try Data().write(to: scope)
        case .malformedLocator: try Data([0xff]).write(to: scope)
        case .futureLocator:
            let text = try String(contentsOf: scope, encoding: .utf8)
            try text.replacingOccurrences(of: "scope-v1", with: "scope-v2").write(to: scope, atomically: false, encoding: .utf8)
        case .symlinkLocator:
            try FileManager.default.removeItem(at: scope)
            try FileManager.default.createSymbolicLink(at: scope,
                withDestinationURL: other.directory.appendingPathComponent("custody.scope"))
        case .fifoLocator:
            try FileManager.default.removeItem(at: scope)
            #expect(mkfifo(scope.path, S_IRUSR | S_IWUSR) == 0)
        case .foreignLocator:
            try Data(contentsOf: other.directory.appendingPathComponent("custody.scope")).write(to: scope)
        case .foreignJournal:
            try Data(contentsOf: other.directory.appendingPathComponent("journal.sqlite")).write(to: journal)
        case .missingJournal: try FileManager.default.removeItem(at: journal)
        case .emptyJournal: try Data().write(to: journal)
        case .missingLease: try FileManager.default.removeItem(at: lease)
        case .fifoLease:
            try FileManager.default.removeItem(at: lease)
            #expect(mkfifo(lease.path, S_IRUSR | S_IWUSR) == 0)
        }
        let files = try fixture.files()
        let items = fixture.operations.backend.storedItems as NSArray
        let writes = fixture.operations.writes
        #expect(throws: (any Error).self) { try fixture.reopen() }
        #expect(throws: DurableWalletStoreError.initializationExists) { try fixture.fresh() }
        #expect(try fixture.files() == files)
        #expect(items.isEqual(fixture.operations.backend.storedItems as NSArray))
        #expect(fixture.operations.writes == writes)
        #expect(fixture.seeds.generated == 1 && fixture.seeds.keys == 1)
    }

    @Test func missingRootAndExistingEmptyRootAreNeverImplicitlyInitialized() throws {
        let fixture = BootstrapFixture()
        defer { fixture.remove() }
        #expect(throws: DurableWalletStoreError.scopeUnavailable) { try fixture.reopen() }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
        #expect(throws: DurableWalletStoreError.initializationExists) { try fixture.fresh() }
        #expect(throws: (any Error).self) { try fixture.reopen() }
        #expect(try fixture.files().isEmpty)
        #expect(fixture.operations.backend.calls.isEmpty)
        #expect(fixture.seeds.generated == 0 && fixture.seeds.keys == 0)
    }

    @Test(arguments: BootstrapInterruption.allCases)
    private func interruptedInitializationRetainsScopeAndCannotReopenOrRestartCreation(_ interruption: BootstrapInterruption) async throws {
        let fixture = BootstrapFixture()
        defer { fixture.remove() }
        try await fixture.interruptAndClose(interruption)
        let files = try fixture.files()
        let items = fixture.operations.backend.storedItems as NSArray
        let writes = fixture.operations.writes
        let generated = fixture.seeds.generated
        let keys = fixture.seeds.keys
        #expect(throws: (any Error).self) { try fixture.reopen() }
        #expect(throws: DurableWalletStoreError.initializationExists) { try fixture.fresh() }
        #expect(try fixture.files() == files)
        #expect(items.isEqual(fixture.operations.backend.storedItems as NSArray))
        #expect(fixture.operations.writes == writes)
        #expect(fixture.seeds.generated == generated && fixture.seeds.keys == keys)
    }

    @Test(arguments: BootstrapRetainedOwner.allCases)
    private func escapedOwnerKeepsTheSameWriterLeaseUntilItsLastRelease(_ retained: BootstrapRetainedOwner) async throws {
        let fixture = BootstrapFixture()
        defer { fixture.remove() }
        var store: DurableWalletStore? = try await fixture.initializedStore()
        var owner: OwnerWalletControl? = retained == .facade ? try #require(store).ownerControl : nil
        var service: OwnerControlService? = retained == .service ? try fixture.service(#require(store)) : nil
        store = nil
        _ = withExtendedLifetime((owner, service)) {
            #expect(throws: StoreLockFailure.busy) { try fixture.reopen() }
        }
        owner = nil; service = nil
        let reopened = try fixture.reopen()
        #expect(reopened.continuity.status() == .trusted(mode: .restricted, history: .complete, generation: 1))
    }

    @Test(arguments: [false, true])
    func reopenCompletesStartupBeforeExposingAuthorityAndPreservesTheLedger(failPromotion: Bool) async throws {
        let fixture = BootstrapFixture()
        defer { fixture.remove() }
        let original = try await fixture.prepareRestart()
        if failPromotion { fixture.operations.armPromotionFailure() }
        if failPromotion {
            #expect(throws: (any Error).self) { try fixture.reopen() }
            let retained = try #require(try SQLiteJournal(
                path: fixture.directory.appendingPathComponent("journal.sqlite").path,
                createIfMissing: false).read())
            let item = try #require(fixture.operations.backend.storedItems.first {
                $0[kSecAttrService as String] as? String == "com.58opals.OpalAgent.continuityanchor"
            })
            let anchor = try JSONDecoder().decode(ContinuityAnchor.self,
                from: #require(item[kSecValueData as String] as? Data))
            #expect(anchor.committed == (try original.reference()))
            #expect(anchor.pending?.classification == "startupInvalidation")
            #expect(anchor.pending?.parent == (try original.reference()))
            #expect(anchor.pending?.target == (try retained.reference()))
            #expect(retained.authorization == original.authorization && retained.custody == original.custody)
            #expect(retained.requests.count == 1 && retained.requests[0].disposition == .invalidated)
            #expect(retained.requests[0].key == "retained-key" && retained.requests[0].result == Data([19]))
            let files = try fixture.files()
            let writes = fixture.operations.writes
            #expect(throws: (any Error).self) { try fixture.reopen() }
            #expect(try fixture.files() == files && fixture.operations.writes == writes)
            #expect(throws: DurableWalletStoreError.initializationExists) { try fixture.fresh() }
        } else {
            let store = try fixture.reopen()
            _ = try store.integrationAuthority()
            let ready = try store.continuity.inspect { $0 }
            #expect(ready.installationID == original.installationID && ready.custody == original.custody)
            #expect(ready.authorization == original.authorization)
            #expect(ready.mode == .enabled && ready.history == .complete)
            #expect(ready.requests.count == 1 && ready.requests[0].disposition == .invalidated)
            #expect(ready.requests[0].key == "retained-key" && ready.requests[0].result == Data([19]))
            #expect(ready.commitID != original.commitID)
        }
        #expect(fixture.seeds.generated == 1 && fixture.seeds.keys == 1)
    }

    @Test func missingWrappingKeyCannotBeReplacedDuringReopen() async throws {
        let fixture = BootstrapFixture()
        defer { fixture.remove() }
        _ = try await fixture.initializeAndClose()
        fixture.operations.hideWrappingKey()
        let files = try fixture.files()
        let items = fixture.operations.backend.storedItems as NSArray
        let writes = fixture.operations.writes
        #expect(throws: (any Error).self) { try fixture.reopen() }
        #expect(try fixture.files() == files)
        #expect(items.isEqual(fixture.operations.backend.storedItems as NSArray))
        #expect(fixture.operations.writes == writes)
        #expect(fixture.seeds.generated == 1 && fixture.seeds.keys == 1)
    }

    @Test func boundCreationStillRequiresAValidConnectionAndFreshConsent() async throws {
        let fixture = BootstrapFixture()
        defer { fixture.remove() }
        let store = try fixture.fresh()
        let invalid = fixture.connection(); invalid.invalidate()
        let service = try fixture.service(store)
        await #expect(throws: ServiceProblem(.unavailable)) {
            try await service.send(OwnerControlRequest(call: .createWallet(network: .mainnet)), connection: invalid)
        }
        let stale = try fixture.service(store, staleConsent: true)
        await #expect(throws: ServiceProblem(.unavailable)) {
            try await stale.send(OwnerControlRequest(call: .createWallet(network: .mainnet)), connection: fixture.connection())
        }
        #expect(fixture.seeds.generated == 0 && fixture.seeds.keys == 0 && fixture.operations.writes == 0)
        _ = try await service.send(OwnerControlRequest(call: .createWallet(network: .mainnet)), connection: fixture.connection())
        #expect(try store.continuity.inspect { $0.mode == .restricted && $0.authorization.grants.isEmpty })
    }
}

private enum BootstrapScopeFault: CaseIterable {
    case missingLocator, emptyLocator, malformedLocator, futureLocator, symlinkLocator, fifoLocator
    case foreignLocator, foreignJournal, missingJournal, emptyJournal, missingLease, fifoLease
}
private enum BootstrapInterruption: CaseIterable { case beforeOwner, afterMarker, afterKeyPersistence }
private enum BootstrapRetainedOwner: CaseIterable { case facade, service }
private enum BootstrapFailure: Error { case interrupted }
private let bootstrapMnemonic = Data("synthetic bootstrap material".utf8)
private let bootstrapPolicy = AuthorityPolicy(
    bridge: .init(teamIdentifier: "synthetic", signingIdentifier: "bridge"),
    owner: .init(teamIdentifier: "synthetic", signingIdentifier: "owner"),
    accountIDs: [], capabilities: ["read", "sync", "prepare", "submit"], ownerAuthenticationAge: 30)
private var bootstrapOwner: OwnerAuthenticationEvidence {
    .init(peer: .init(identity: bootstrapPolicy.owner, signatureValidated: true),
          authenticationSucceeded: true, authenticatedAt: 100)
}

private final class BootstrapFixture: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-\(UUID().uuidString)")
    let operations: BootstrapOperations
    let seeds = BootstrapSeeds()
    init(operations: BootstrapOperations = BootstrapOperations()) { self.operations = operations }
    func fresh() throws -> DurableWalletStore {
        try DurableWalletStore.initializeNew(directory: directory, accessGroup: "test.OpalAgent.Service",
            accounts: seeds, operations: operations, policy: bootstrapPolicy,
            generateKey: { [seeds] in try seeds.key() })
    }
    func reopen() throws -> DurableWalletStore {
        try DurableWalletStore.reopen(directory: directory, accessGroup: "test.OpalAgent.Service",
            accounts: seeds, operations: operations, policy: bootstrapPolicy)
    }
    func service(_ store: DurableWalletStore, staleConsent: Bool = false) throws -> OwnerControlService {
        try OwnerControlService(store: store, accounts: BootstrapUnusedBoundary(),
            consent: BootstrapConsent(stale: staleConsent), clock: BootstrapClock())
    }
    func connection() -> OwnerConnectionContext {
        OwnerConnectionContext(connectionID: "bootstrap-owner", peer: bootstrapOwner.peer)
    }
    func initializedStore() async throws -> DurableWalletStore {
        let store = try fresh()
        _ = try await service(store).send(OwnerControlRequest(call: .createWallet(network: .mainnet)), connection: connection())
        return store
    }
    func initializeAndClose() async throws -> CanonicalState {
        let store = try await initializedStore()
        return try store.continuity.inspect { $0 }
    }
    func interruptAndClose(_ interruption: BootstrapInterruption) async throws {
        let store = try fresh()
        if interruption == .beforeOwner { return }
        if interruption == .afterMarker { seeds.failKey() }
        else { operations.failKeyAdd() }
        await #expect(throws: (any Error).self) {
            try await service(store).send(OwnerControlRequest(call: .createWallet(network: .mainnet)), connection: connection())
        }
    }
    func prepareRestart() async throws -> CanonicalState {
        let store = try await initializedStore()
        _ = try store.ownerControl.enable(vault: #require(store.vault), owner: bootstrapOwner, now: 100)
        let account = try store.continuity.inspect { try #require($0.custody).accountID }
        _ = try store.integrationAuthority().enroll(id: "retained-grant", integrationID: "integration",
            accounts: [account], capabilities: ["read"], expiry: nil, owner: bootstrapOwner, now: 100)
        try store.continuity.transaction { state in
            state.requests.append(RequestRecord(id: "retained-request", principalID: "integration", method: "prepare",
                key: "retained-key", binding: Data([17]), disposition: .unsubmitted, result: Data([19]),
                consumedAttemptID: nil, tombstone: false))
        }
        return try store.continuity.inspect { $0 }
    }
    func files() throws -> [String: String] {
        var result: [String: String] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if attributes.isSymbolicLink == true {
                result[url.lastPathComponent] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            } else if attributes.isRegularFile == true {
                result[url.lastPathComponent] = try Data(contentsOf: url).base64EncodedString()
            } else { result[url.lastPathComponent] = "nonregular" }
        }
        return result
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class BootstrapSeeds: SeedAccountProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var generatedCount = 0
    private var keyCount = 0
    private var keyFailure = false
    var generated: Int { lock.withLock { generatedCount } }
    var keys: Int { lock.withLock { keyCount } }
    func failKey() { lock.withLock { keyFailure = true } }
    func key() throws -> SymmetricKey {
        let fail = lock.withLock { keyCount += 1; return keyFailure }
        if fail { throw BootstrapFailure.interrupted }
        return SymmetricKey(data: Data(repeating: 29, count: 32))
    }
    func generateMnemonic() throws -> Data { lock.withLock { generatedCount += 1 }; return bootstrapMnemonic }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        guard mnemonic == bootstrapMnemonic else { throw BootstrapFailure.interrupted }
        return .init(accountID: "bootstrap-account", publicDescriptor: Data("synthetic bootstrap descriptor".utf8))
    }
}

private final class BootstrapOperations: KeychainItemOperations, @unchecked Sendable {
    let backend = KeychainTestOperations()
    private let lock = NSLock()
    private var keyAddFailure = false
    private var promotionFailure = false
    private var keyHidden = false
    var writes: Int { backend.addCount + backend.updateCount }
    func failKeyAdd() { lock.withLock { keyAddFailure = true } }
    func armPromotionFailure() { lock.withLock { promotionFailure = true } }
    func hideWrappingKey() { lock.withLock { keyHidden = true } }
    func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?) {
        let values = query as NSDictionary as! [String: Any]
        if values[kSecAttrService as String] as? String == "com.58opals.OpalAgent.wrapkey",
           lock.withLock({ keyHidden }) { return (errSecItemNotFound, nil) }
        return backend.copyMatching(query)
    }
    func add(_ attributes: CFDictionary) -> OSStatus {
        let values = attributes as NSDictionary as! [String: Any]
        let status = backend.add(attributes)
        if values[kSecAttrService as String] as? String == "com.58opals.OpalAgent.wrapkey",
           lock.withLock({ keyAddFailure }) { return errSecNotAvailable }
        return status
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        let values = attributes as NSDictionary as! [String: Any]
        if lock.withLock({ promotionFailure }), let data = values[kSecValueData as String] as? Data,
           let anchor = try? JSONDecoder().decode(ContinuityAnchor.self, from: data),
           anchor.pending == nil, anchor.recovery == nil { return errSecNotAvailable }
        return backend.update(query, attributes: attributes)
    }
}
private struct BootstrapConsent: OwnerConsentProvider {
    let stale: Bool
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        OwnerConsentProof(challenge: challenge, authenticatedAt: stale ? 69 : 100)
    }
}
private struct BootstrapClock: PaymentClock {
    func read() -> PaymentClockReading { .init(wall: 100, monotonic: 100) }
}
private struct BootstrapUnusedBoundary: AccountChainBoundary, PaymentExecutionBoundary {
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord { throw PaymentFailure.unavailable }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String { throw PaymentFailure.unavailable }
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview { throw PaymentFailure.unavailable }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment { throw PaymentFailure.unavailable }
    func preflight(_ payment: SignedPayment) async throws { throw PaymentFailure.unavailable }
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation { throw PaymentFailure.unavailable }
    func dispose(operationID: String) async throws {}
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation { throw PaymentFailure.unavailable }
}
