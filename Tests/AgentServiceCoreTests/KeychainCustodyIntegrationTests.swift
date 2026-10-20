import CryptoKit
import Foundation
import Security
import Testing
@testable import AgentServiceCore

struct KeychainCustodyIntegrationTests {
    @Test(arguments: CustodyKeyLoss.allCases)
    private func existingCiphertextCannotEnableOrReplaceCustodyWhenItsKeyIsLost(_ loss: CustodyKeyLoss) async throws {
        let accounts = CustodyIntegrationAccounts()
        let originalVault = WalletSeedVault(keys: InjectedWrappingKeySource {
            .available(SymmetricKey(data: Data(repeating: 7, count: 32)))
        }, accounts: accounts)
        let custody = try await originalVault.protect(mnemonic: Data("disposable synthetic custody fixture".utf8),
            walletID: "wallet", network: "mainnet")
        var state = custodyIntegrationState()
        state.mode = .restricted
        state.authorization.grants[0].revoked = true
        state.approvals[0].active = false
        state.custody = custody
        let fixture = try CustodyIntegrationFixture(state: state)
        defer { fixture.remove() }
        let keyOperations = KeychainTestOperations(items: loss == .missing ? [] : [
            keychainTestItem(data: Data(repeating: loss == .wrong ? 9 : 7, count: 32))
        ])
        if loss == .inaccessible {
            for call in 1...3 { keyOperations.overrideCopy(call: call, status: errSecInteractionNotAllowed) }
        }
        let source = try KeychainWrappingKeySource(accessGroup: "test.OpalAgent.Service", walletID: "wallet",
            operations: keyOperations)
        let vault = WalletSeedVault(keys: source, accounts: accounts)
        let beforeDatabase = try Data(contentsOf: URL(fileURLWithPath: fixture.databasePath))
        let beforeKeyItems = keyOperations.storedItems as NSArray
        let beforeAnchorWrites = fixture.operations.updateCount + fixture.operations.addCount

        await #expect(throws: loss.expected) { try await vault.open(custody) }
        #expect(throws: loss.expected) { try vault.requireAvailable(custody) }
        #expect(throws: loss.expected) {
            try fixture.coordinator.enable(ownerAuthorized: true) { stored in
                guard let retainedCustody = stored.custody else { throw ContinuityError.invalidState }
                try vault.requireAvailable(retainedCustody)
            }
        }

        #expect(try fixture.journal.read() == state.canonicalized())
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.databasePath)) == beforeDatabase)
        #expect(beforeKeyItems.isEqual(keyOperations.storedItems as NSArray))
        #expect(keyOperations.addCount == 0 && keyOperations.updateCount == 0)
        #expect(fixture.operations.updateCount + fixture.operations.addCount == beforeAnchorWrites)
        #expect(try fixture.anchor.read()?.committed == state.reference())
        #expect(fixture.coordinator.status() == .trusted(mode: .restricted, history: .complete, generation: 3))
    }

    @Test(arguments: AnchorBarrierStage.allCases, AnchorBarrierFailure.allCases)
    private func failedKeychainAnchorBarrierNeverProjectsAnAcknowledgment(
        _ stage: AnchorBarrierStage, _ failure: AnchorBarrierFailure
    ) throws {
        let initial = custodyIntegrationState()
        let fixture = try CustodyIntegrationFixture(state: initial)
        defer { fixture.remove() }
        try configure(failure, at: stage, fixture: fixture, initial: initial)
        var projected = false

        #expect(throws: (any Error).self) {
            try fixture.coordinator.transaction(classification: "receive", mutation: { state in
                state.allocations[0].issuedIndices.append(2)
                state.allocations[0].issuedHighWater = 2
            }, projection: { _, _ in projected = true })
        }

        #expect(!projected)
        #expect(fixture.coordinator.status() == .quarantined)
        let stored = try #require(try fixture.journal.read())
        if stage == .staging {
            #expect(stored == initial.canonicalized())
        } else {
            var expected = initial
            expected.allocations[0].issuedIndices.append(2)
            expected.allocations[0].issuedHighWater = 2
            expected.commitID = stored.commitID
            #expect(stored.commitID != initial.commitID)
            #expect(stored == expected.canonicalized())
        }
        // A failed response can coexist with durable promotion; only a clean fresh read
        // can distinguish that outcome from a staged, interrupted command.
        let restarted = ContinuityCoordinator(database: try SQLiteJournal(path: fixture.databasePath), anchor: fixture.anchor)
        if (stage == .staging && failure.didNotPersist) || (stage == .promotion && !failure.didNotPersist) {
            #expect(restarted.status() == .trusted(mode: .enabled, history: .complete, generation: 3))
        } else {
            #expect(restarted.status() == .quarantined)
        }
    }

    @Test func ambiguousAnchorErrorsAcknowledgeOnlyAfterBothPersistedValuesAreReadBack() throws {
        let fixture = try CustodyIntegrationFixture(state: custodyIntegrationState())
        defer { fixture.remove() }
        let nextUpdate = fixture.operations.updateCount + 1
        fixture.operations.overrideUpdate(call: nextUpdate, status: errSecNotAvailable, persist: true)
        fixture.operations.overrideUpdate(call: nextUpdate + 1, status: errSecNotAvailable, persist: true)
        var projections = 0

        let acknowledged = try fixture.coordinator.transaction(classification: "receive", mutation: { state in
            state.allocations[0].issuedIndices.append(2)
            state.allocations[0].issuedHighWater = 2
        }, projection: { state, _ in
            projections += 1
            let anchor = try #require(try fixture.anchor.read())
            #expect(anchor.pending == nil && anchor.recovery == nil)
            #expect(try anchor.committed == state.reference())
            #expect(try fixture.journal.read() == state.canonicalized())
            return state
        })

        #expect(projections == 1)
        #expect(acknowledged.allocations[0].issuedHighWater == 2)
        let reopened = try SQLiteJournal(path: fixture.databasePath)
        #expect(try reopened.read() == acknowledged.canonicalized())
        #expect(try fixture.anchor.read()?.committed == acknowledged.reference())
    }

    @Test(arguments: FirstAnchorAddOutcome.allCases)
    private func missingAnchorRecoveryRequiresTheActualFirstAddedLatch(_ outcome: FirstAnchorAddOutcome) throws {
        let initial = custodyIntegrationState()
        let fixture = try CustodyIntegrationFixture(state: initial, seedAnchor: false)
        defer { fixture.remove() }
        switch outcome {
        case .errorAfterPersistence:
            fixture.operations.overrideAdd(call: 1, status: errSecNotAvailable, persist: true)
        case .errorBeforePersistence:
            fixture.operations.overrideAdd(call: 1, status: errSecNotAvailable, persist: false)
        case .successWithoutPersistence:
            fixture.operations.overrideAdd(call: 1, status: errSecSuccess, persist: false)
        case .duplicateWithMissingReadback:
            fixture.operations.overrideAdd(call: 1, status: errSecDuplicateItem, persist: false)
        case .duplicateWithForeignReadback:
            var foreign = initial
            foreign.installationID = "foreign-installation"
            let data = try JSONEncoder().encode(ContinuityAnchor(committed: foreign.reference()))
            fixture.operations.insert(keychainTestItem(service: "com.58opals.OpalAgent.continuityanchor",
                account: "v1:12:installation6:wallet", data: data))
            // Model a competing item appearing after both missing-item reads: the
            // attempted update still misses, then Add encounters the actual duplicate.
            fixture.operations.overrideCopy(call: 1, status: errSecItemNotFound)
            fixture.operations.overrideCopy(call: 2, status: errSecItemNotFound)
            fixture.operations.overrideUpdate(call: 1, status: errSecItemNotFound, persist: false)
        }
        let beforeItems = fixture.operations.storedItems as NSArray
        let beforeDatabase = try Data(contentsOf: URL(fileURLWithPath: fixture.databasePath))

        if outcome == .errorAfterPersistence {
            let recovered = try fixture.coordinator.recover(ownerAuthorized: true, recoveryID: "missing-anchor")
            #expect(recovered.mode == .restricted && recovered.history == .incomplete)
            #expect(recovered.historyProvenance.kind == .unproven)
            #expect(recovered.authorization.generation == 4)
            #expect(recovered.authorization.grants.allSatisfy { $0.revoked })
            #expect(recovered.approvals.allSatisfy { !$0.active })
            #expect(recovered.requests == initial.requests && recovered.payments == initial.payments)
            #expect(recovered.gates == initial.gates)
            #expect(try fixture.journal.read() == recovered.canonicalized())
            let finalAnchor = try #require(try fixture.anchor.read())
            #expect(try finalAnchor.committed == recovered.reference())
            #expect(finalAnchor.pending == nil && finalAnchor.recovery == nil)
            #expect(throws: ContinuityError.incompleteHistory) {
                try fixture.coordinator.enable(ownerAuthorized: true)
            }
            #expect(fixture.coordinator.status() == .trusted(mode: .restricted, history: .incomplete, generation: 4))
        } else {
            #expect(throws: ContinuityError.recoveryRequired) {
                try fixture.coordinator.recover(ownerAuthorized: true, recoveryID: "missing-anchor")
            }
            #expect(try fixture.journal.read() == initial.canonicalized())
            #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.databasePath)) == beforeDatabase)
            #expect(beforeItems.isEqual(fixture.operations.storedItems as NSArray))
            #expect(fixture.operations.updateCount == 1)
            #expect(fixture.coordinator.status() == .quarantined)
            let restarted = ContinuityCoordinator(database: fixture.journal, anchor: fixture.anchor)
            #expect(restarted.status() == .quarantined)
        }
        // In particular, a duplicate never triggers an overwrite/retry or replacement.
        #expect(fixture.operations.addCount == 1)
    }

    @Test func interruptedKeychainAnchorPromotionRecoversRetainedLiabilityWithoutRevivingAuthority() throws {
        let initial = custodyIntegrationState()
        let fixture = try CustodyIntegrationFixture(state: initial)
        defer { fixture.remove() }
        fixture.operations.overrideUpdate(call: fixture.operations.updateCount + 2,
            status: errSecNotAvailable, persist: false)
        #expect(throws: ContinuityError.recoveryRequired) {
            try fixture.coordinator.transaction(classification: "receive") { state in
                state.allocations[0].issuedIndices.append(2)
                state.allocations[0].issuedHighWater = 2
            }
        }
        let interrupted = try #require(try fixture.journal.read())
        let pending = try #require(try fixture.anchor.read()?.pending)
        #expect(try pending.parent == initial.reference())
        #expect(try pending.target == interrupted.reference())
        let reopened = try SQLiteJournal(path: fixture.databasePath)
        let anchor = try KeychainContinuityAnchorStore(accessGroup: "test.OpalAgent.Service",
            installationID: "installation", walletID: "wallet", operations: fixture.operations)
        let restarted = ContinuityCoordinator(database: reopened, anchor: anchor)
        #expect(restarted.status() == .quarantined)

        let recovered = try restarted.recover(ownerAuthorized: true, recoveryID: "recovery")

        #expect(recovered.mode == .restricted && recovered.history == .complete)
        #expect(recovered.authorization.generation == 4)
        #expect(recovered.authorization.grants.allSatisfy { $0.revoked })
        #expect(recovered.approvals.allSatisfy { !$0.active })
        #expect(recovered.requests == initial.requests)
        #expect(recovered.payments == initial.payments)
        #expect(recovered.gates == initial.gates)
        #expect(recovered.payments[0].liabilityUnresolved)
        #expect(recovered.requests[0].consumedAttemptID == "attempt" && recovered.requests[0].tombstone)
        #expect(recovered.allocations == interrupted.allocations)
        #expect(recovered.historyProvenance.kind == .stagedTarget)
        #expect(try reopened.read() == recovered.canonicalized())
        let finalAnchor = try #require(try anchor.read())
        #expect(finalAnchor.pending == nil && finalAnchor.recovery == nil)
        #expect(try finalAnchor.committed == recovered.reference())
        #expect(restarted.status() == .trusted(mode: .restricted, history: .complete, generation: 4))
    }
}

private enum CustodyKeyLoss: CaseIterable, Sendable {
    case missing, inaccessible, wrong
    var expected: PayloadProtectionError {
        switch self {
        case .missing: .wrappingKeyMissing
        case .inaccessible: .wrappingKeyInaccessible
        case .wrong: .authenticationFailed
        }
    }
}

private enum AnchorBarrierStage: CaseIterable, Sendable {
    case staging, promotion
    var writeOffset: Int { self == .staging ? 1 : 2 }
    // Trusted read, then a write preflight and verification at each barrier.
    var readOffset: Int { self == .staging ? 3 : 5 }
}

private enum AnchorBarrierFailure: CaseIterable, Sendable {
    case beforePersistence, successWithoutPersistence, unavailableReadback, malformedReadback, foreignReadback
    var didNotPersist: Bool { self == .beforePersistence || self == .successWithoutPersistence }
}

private enum FirstAnchorAddOutcome: CaseIterable, Sendable {
    case errorAfterPersistence, errorBeforePersistence, successWithoutPersistence
    case duplicateWithMissingReadback, duplicateWithForeignReadback
}

private func configure(_ failure: AnchorBarrierFailure, at stage: AnchorBarrierStage,
                       fixture: CustodyIntegrationFixture, initial: CanonicalState) throws {
    let operations = fixture.operations
    switch failure {
    case .beforePersistence:
        operations.overrideUpdate(call: operations.updateCount + stage.writeOffset,
            status: errSecNotAvailable, persist: false)
    case .successWithoutPersistence:
        operations.overrideUpdate(call: operations.updateCount + stage.writeOffset,
            status: errSecSuccess, persist: false)
    case .unavailableReadback:
        operations.overrideCopy(call: operations.copyCount + stage.readOffset, status: errSecInteractionNotAllowed)
    case .malformedReadback, .foreignReadback:
        let data: Data
        if failure == .malformedReadback {
            data = Data([0xff])
        } else {
            var foreign = initial
            foreign.installationID = "foreign-installation"
            data = try JSONEncoder().encode(ContinuityAnchor(committed: foreign.reference()))
        }
        let result = keychainTestItem(service: "com.58opals.OpalAgent.continuityanchor",
            account: "v1:12:installation6:wallet", data: data)
        operations.overrideCopy(call: operations.copyCount + stage.readOffset,
            status: errSecSuccess, result: result as NSDictionary)
    }
}

private struct CustodyIntegrationFixture {
    let directory: URL
    let databasePath: String
    let journal: SQLiteJournal
    let operations: KeychainTestOperations
    let anchor: KeychainContinuityAnchorStore
    let coordinator: ContinuityCoordinator

    init(state: CanonicalState, seedAnchor: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        databasePath = directory.appendingPathComponent("wallet.sqlite").path
        journal = try SQLiteJournal(path: databasePath)
        try journal.write(state)
        operations = KeychainTestOperations()
        anchor = try KeychainContinuityAnchorStore(accessGroup: "test.OpalAgent.Service",
            installationID: "installation", walletID: "wallet", operations: operations)
        if seedAnchor { try anchor.write(ContinuityAnchor(committed: state.reference())) }
        coordinator = ContinuityCoordinator(database: journal, anchor: anchor)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private struct CustodyIntegrationAccounts: SeedAccountProvider {
    func generateMnemonic() throws -> Data { Data("disposable synthetic custody fixture".utf8) }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        DerivedSeedAccount(accountID: "account", publicDescriptor: Data("public fixture descriptor".utf8))
    }
}

private func custodyIntegrationState() -> CanonicalState {
    let grant = GrantRecord(id: "grant", integrationID: "integration", accountIDs: ["account"],
        capabilities: ["pay"], credentialDigest: Data([1, 2]), credentialGeneration: 3, expiresAt: nil, revoked: false)
    var state = CanonicalState(installationID: "installation",
        authorization: AuthorizationLedger(walletID: "wallet", network: "mainnet", generation: 3, grants: [grant]),
        commitID: "original", mode: .enabled, history: .complete)
    state.approvals = [ApprovalRecord(id: "approval", paymentID: "possible", generation: 3,
        context: Data([7]), active: true)]
    state.requests = [RequestRecord(id: "request", principalID: "principal", paymentID: "possible", method: "pay",
        key: "key", binding: Data([9]), disposition: .consumed, result: Data([8]), consumedAttemptID: "attempt", tombstone: true)]
    state.payments = [PaymentRecord(id: "possible", accountID: "account", network: "mainnet", originGrantID: "grant",
        canonicalBytes: Data([10, 11]), transactionDigest: Data([12]), selectedInputs: ["input"], change: Data([13]),
        disposition: .possiblyRelayed, liabilityUnresolved: true,
        attempts: [AttemptRecord(id: "attempt", number: 1, commandID: "owner-command", outcome: "unknown")],
        evidence: [], closures: [])]
    state.gates = [SpendingGate(accountID: "account", liabilityIDs: ["possible"], restrictions: ["uncertain"])]
    state.allocations = [AllocationRecord(accountID: "account", branch: "receive", issuedIndices: [0, 1],
        issuedHighWater: 1, confirmedHistoryHorizon: 0, issuanceEvidence: Data([15]))]
    return state
}
