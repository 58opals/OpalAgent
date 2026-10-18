import CSQLite
import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

struct RecoveryIntegrationTests {
    @Test func oldSQLiteBackupAfterEnginePaymentAndRevocationCannotRestoreAuthority() async throws {
        var initial = try recoveryState()
        initial.payments = []; initial.requests = []; initial.approvals = []; initial.gates = []
        let fixture = try RecoveryFixture(state: initial)
        defer { fixture.remove() }
        let backup = fixture.folder.appendingPathComponent("old-backup.sqlite").path
        try backupSQLite(from: fixture.path, to: backup)
        let boundary = RecoveryPaymentBoundary()
        let engine = PaymentEngine(continuity: fixture.continuity, authorityPolicy: fixture.policy,
            boundary: boundary, clock: RecoveryClock())
        let authority = try ServiceAuthority(continuity: fixture.continuity, policy: fixture.policy)
        let session = try authority.authenticate(connectionID: "connection", peer: fixture.peer,
            credential: recoveryCredential, now: 1_000)
        let request = PaymentRequest(accountID: "account", network: "mainnet", requestKey: String(repeating: "a", count: 32),
            destinationScript: Data([0x51]), amount: 1_000)
        let operation = try await engine.prepare(request, session: session, connectionID: "connection", peer: fixture.peer)
        try await waitForRecoveryPayment(operation.payment.id, disposition: .prepared, journal: fixture.journal)
        _ = try await engine.submit(operationID: operation.payment.id, session: session, connectionID: "connection", peer: fixture.peer)
        try await waitForRecoveryPayment(operation.payment.id, disposition: .accepted, journal: fixture.journal)
        try await engine.reconcile(operationID: operation.payment.id)
        try await waitForRecoveryPayment(operation.payment.id, disposition: .closed, journal: fixture.journal)
        #expect(boundary.handoffs == 1)
        try authority.revoke(id: "grant", owner: fixture.owner, now: 1_000)
        let complete = try #require(try fixture.journal.read())
        #expect(complete.authorization.grants[0].revoked)
        #expect(complete.payments.first?.closures.contains { $0.reason == "reconciledAccepted" } == true)
        let independent = try fixture.anchor.actual()
        let restored = try SQLiteJournal(path: backup)
        let rollback = ContinuityCoordinator(database: restored, anchor: fixture.anchor)
        let controls = OwnerWalletControl(continuity: rollback, policy: fixture.policy)
        #expect(rollback.status() == .quarantined)
        #expect(throws: ContinuityError.recoveryRequired) { try ServiceAuthority(continuity: rollback, policy: fixture.policy) }
        #expect(try fixture.anchor.actual() == independent)
        let reset = try controls.recover(owner: fixture.owner, now: 1_000)
        #expect(reset.mode == .restricted && reset.history == .incomplete)
        #expect(reset.authorization.grants.allSatisfy { $0.revoked })
        #expect(reset.payments.isEmpty) // Finding the known transaction cannot reconstruct the omitted journal.
        #expect(try fixture.anchor.actual()?.originalProofs.contains { $0.reference == (try? complete.reference()) } == true)
        #expect(throws: ContinuityError.incompleteHistory) { try controls.enable(vault: recoveryVault(), owner: fixture.owner, now: 1_000) }
        let restrictedAuthority = try ServiceAuthority(continuity: rollback, policy: fixture.policy)
        #expect(throws: (any Error).self) {
            try restrictedAuthority.authenticate(connectionID: "reconnect", peer: fixture.peer, credential: recoveryCredential, now: 1_000)
        }
        #expect(boundary.handoffs == 1)
    }

    @Test func engineUncertaintySurvivesInterruptedReceiveAllocationAndOwnerRecovery() async throws {
        var initial = try recoveryState()
        initial.payments = []; initial.requests = []; initial.approvals = []; initial.gates = []
        let fixture = try RecoveryFixture(state: initial)
        defer { fixture.remove() }
        let boundary = RecoveryPaymentBoundary(outcome: .unknown(source: "synthetic"))
        let engine = PaymentEngine(continuity: fixture.continuity, authorityPolicy: fixture.policy,
            boundary: boundary, clock: RecoveryClock())
        let authority = try ServiceAuthority(continuity: fixture.continuity, policy: fixture.policy)
        let session = try authority.authenticate(connectionID: "connection", peer: fixture.peer,
            credential: recoveryCredential, now: 1_000)
        let payment = try await engine.prepare(PaymentRequest(accountID: "account", network: "mainnet",
            requestKey: String(repeating: "a", count: 32), destinationScript: Data([0x51]), amount: 1_000),
            session: session, connectionID: "connection", peer: fixture.peer)
        try await waitForRecoveryPayment(payment.payment.id, disposition: .prepared, journal: fixture.journal)
        _ = try await engine.submit(operationID: payment.payment.id, session: session, connectionID: "connection", peer: fixture.peer)
        try await waitForRecoveryPayment(payment.payment.id, disposition: .uncertain, journal: fixture.journal)
        let liability = try #require(try fixture.journal.read())
        fixture.anchor.failReceivePromotion = true
        let receive = ReceiveEngine(continuity: fixture.continuity, policy: fixture.policy,
            boundary: RecoveryReceiveBoundary(), clock: RecoveryClock())
        await #expect(throws: ContinuityError.recoveryRequired) {
            try await receive.create(ReceiveRequest(accountID: "account", network: "mainnet", requestKey: String(repeating: "d", count: 32)),
                session: session, connectionID: "connection", peer: fixture.peer)
        }
        #expect(fixture.continuity.status() == .quarantined)
        let committedRows = try #require(try fixture.journal.read())
        #expect(committedRows.allocations.first?.issuedHighWater == 2)
        let receipt = try #require(committedRows.requests.first { $0.method == "create_receive_request" })
        #expect(try JSONDecoder().decode(ReceiveAllocation.self, from: receipt.result).index == 2)
        let reset = try fixture.controls.recover(owner: fixture.owner, now: 1_000)
        #expect(reset.mode == .restricted && reset.history == .complete)
        #expect(reset.payments == liability.payments && reset.gates == liability.gates)
        #expect(reset.requests.contains(receipt))
        #expect(reset.authorization.grants.allSatisfy { $0.revoked })
        #expect(boundary.handoffs == 1)
        let summary = try fixture.controls.inspect(owner: fixture.owner, now: 1_000)
        #expect(summary.unresolvedPayments == [payment.payment.id])
        let enabled = try fixture.controls.enable(vault: recoveryVault(), owner: fixture.owner, now: 1_000)
        #expect(enabled.authorization.grants.allSatisfy { $0.revoked })
        await #expect(throws: (any Error).self) {
            try await engine.get(operationID: payment.payment.id, session: session, connectionID: "connection", peer: fixture.peer)
        }
        let retained = try #require(enabled.payments.first { $0.id == payment.payment.id })
        let command = OwnerRelayCommand(key: String(repeating: "e", count: 32), operationID: retained.id,
            accountID: retained.accountID, network: retained.network, transactionDigest: retained.transactionDigest,
            generation: enabled.authorization.generation, policyRevision: enabled.paymentPolicy.revision,
            evidenceRevision: retained.evidenceRevision,
            liabilityContextDigest: accountLiabilityContextDigest(accountID: retained.accountID, state: enabled))
        _ = try await engine.authorizeRelay(command, owner: fixture.owner)
        try await waitForRecoveryPayment(retained.id, disposition: .uncertain, journal: fixture.journal)
        _ = try await engine.authorizeRelay(command, owner: fixture.owner)
        let relayed = try #require(try fixture.journal.read()?.payments.first { $0.id == retained.id })
        #expect(boundary.handoffs == 2 && relayed.attempts.count == 2)
        #expect(relayed.canonicalBytes == retained.canonicalBytes && relayed.ordinaryAdmissions == retained.ordinaryAdmissions)
        #expect(relayed.attempts.last?.route == "owner")
        #expect(try fixture.journal.read()?.gates == liability.gates)
    }

    @Test(arguments: RecoveryDiskFault.allCases)
    private func everyRecoveryFailurePrefixUsesActualSQLiteAndResumesTheDurableLatch(_ fault: RecoveryDiskFault) throws {
        let original = try recoveryState()
        var target = original
        target.commitID = "pending-target"
        target.allocations[0].issuedHighWater = 2
        let anchor = ContinuityAnchor(committed: try original.reference(),
            pending: PendingState(parent: try original.reference(), target: try target.reference(), classification: "receive.allocate"))
        let fixture = try RecoveryFixture(state: target, anchor: anchor)
        defer { fixture.remove() }
        fixture.database.arm(fault)
        fixture.anchor.arm(fault)
        #expect(throws: (any Error).self) { try fixture.controls.recover(owner: fixture.owner, now: 1_000) }
        let firstLatch = fixture.anchor.history.compactMap(\.recovery).first
        if let firstLatch {
            #expect(firstLatch.targetGeneration == 2)
            #expect(firstLatch.observedCommitted == (try original.reference()))
            #expect(firstLatch.observedDatabase == (try target.reference()))
            #expect(firstLatch.reason == .interruptedUpdate)
            #expect(fixture.anchor.history.allSatisfy { $0.recovery == firstLatch || $0.recovery == nil })
        }
        fixture.database.clearFaults()
        fixture.anchor.clearFaults()
        let reopened = try SQLiteJournal(path: fixture.path)
        let restarted = ContinuityCoordinator(database: reopened, anchor: fixture.anchor)
        let physicalAnchor = try fixture.anchor.actual()
        if physicalAnchor?.recovery == nil && fault != .latchBefore {
            #expect(restarted.status() == .trusted(mode: .restricted, history: .complete, generation: 2))
        } else { #expect(restarted.status() == .quarantined) }
        let owner = OwnerWalletControl(continuity: restarted, policy: fixture.policy)
        let reset = try owner.recover(owner: fixture.owner, now: 1_000)
        #expect(reset.mode == .restricted && reset.history == .complete)
        #expect(reset.authorization.grants.allSatisfy { $0.revoked })
        #expect(reset.approvals.allSatisfy { !$0.active })
        #expect(reset.payments.first { $0.id == "possible" } == original.payments[0])
        #expect(reset.gates == original.gates && reset.allocations[0].issuedHighWater == 2)
        #expect(reset.requests.first { $0.id == "unsubmitted-request" }?.disposition == .invalidated)
        if let firstLatch, fault != .clearReadback {
            #expect(reset.commitID == firstLatch.id && reset.authorization.generation == firstLatch.targetGeneration)
        }
        #expect(try fixture.anchor.actual()?.recovery == nil && fixture.anchor.actual()?.pending == nil)
        #expect(try reopened.read()?.reference() == fixture.anchor.actual()?.committed)
        let enabled = try owner.enable(vault: recoveryVault(), owner: fixture.owner, now: 1_000)
        #expect(enabled.mode == .enabled && enabled.authorization.generation >= 2)
        #expect(enabled.authorization.grants.allSatisfy { $0.revoked } && enabled.approvals.allSatisfy { !$0.active })
        #expect(enabled.gates == original.gates && enabled.payments.first { $0.id == "possible" } == original.payments[0])
    }

    @Test func incompleteSQLiteCannotProveCoverageButAnOriginalCompleteArchiveCan() throws {
        let original = try recoveryState()
        let fixture = try RecoveryFixture(state: original)
        defer { fixture.remove() }
        let archivePath = fixture.folder.appendingPathComponent("complete-archive.sqlite").path
        try backupSQLite(from: fixture.path, to: archivePath)
        var partial = original
        partial.requests = []; partial.payments = []; partial.approvals = []; partial.gates = []
        let partialPath = fixture.folder.appendingPathComponent("partial.sqlite").path
        let journal = try SQLiteJournal(path: partialPath)
        try journal.write(partial) // Same stored identity/header, actual complete rows differ.
        #expect(try journal.read()?.reference() != original.reference())
        let continuity = ContinuityCoordinator(database: journal, anchor: fixture.anchor)
        let controls = OwnerWalletControl(continuity: continuity, policy: fixture.policy)
        #expect(continuity.status() == .quarantined)
        let incomplete = try controls.recover(owner: fixture.owner, now: 1_000)
        #expect(incomplete.history == .incomplete && incomplete.mode == .restricted)
        #expect(throws: ContinuityError.incompleteHistory) { try controls.enable(vault: recoveryVault(), owner: fixture.owner, now: 1_000) }
        #expect(try fixture.anchor.actual()?.originalProofs.contains { $0.reference == (try? original.reference()) } == true)
        let stillIncomplete = try controls.recover(owner: fixture.owner, now: 1_000)
        #expect(stillIncomplete.history == .incomplete)
        let archive = try #require(try SQLiteJournal(path: archivePath).read())
        let complete = try controls.recover(owner: fixture.owner, now: 1_000, source: archive)
        #expect(complete.mode == .restricted && complete.history == .complete)
        #expect(complete.payments.first { $0.id == "possible" } == original.payments[0])
        #expect(complete.gates == original.gates)
        #expect(complete.authorization.grants.allSatisfy { $0.revoked })
        #expect(complete.approvals.allSatisfy { !$0.active })
        #expect(try fixture.anchor.actual()?.originalProofs.isEmpty == true)
        let enabled = try controls.enable(vault: recoveryVault(), owner: fixture.owner, now: 1_000)
        #expect(enabled.gates == original.gates && enabled.authorization.grants.allSatisfy { $0.revoked })
    }
}

private enum RecoveryDiskFault: CaseIterable, Sendable {
    case latchBefore, latchReadback, baselineBefore, baselineReadback, stageBefore, stageReadback
    case databaseBefore, databaseReadback, promotionBefore, promotionReadback, finalDatabaseReadback, clearBefore, clearReadback
}
private final class RecoveryDatabase: ContinuityDatabase, @unchecked Sendable {
    let journal: SQLiteJournal
    private var reads = 0
    private var failRead: Int?
    private var failWrite = false
    init(_ journal: SQLiteJournal) { self.journal = journal }
    func arm(_ fault: RecoveryDiskFault) {
        reads = 0
        failRead = fault == .databaseReadback ? 2 : fault == .finalDatabaseReadback ? 3 : nil
        failWrite = fault == .databaseBefore
    }
    func clearFaults() { failRead = nil; failWrite = false }
    func read() throws -> CanonicalState? {
        reads += 1
        if reads == failRead { throw ContinuityStoreError.failed }
        return try journal.read()
    }
    func write(_ state: CanonicalState) throws {
        if failWrite { throw ContinuityStoreError.failed }
        try journal.write(state)
    }
}
private final class RecoveryAnchor: ContinuityAnchorStore, @unchecked Sendable {
    let path: URL
    private var reads = 0
    private var writes = 0
    private var failRead: Int?
    private var failWrite: Int?
    private(set) var history: [ContinuityAnchor] = []
    var failReceivePromotion = false
    init(_ path: URL) { self.path = path }
    func arm(_ fault: RecoveryDiskFault) {
        reads = 0; writes = 0; history = []
        switch fault {
        case .latchBefore: failWrite = 1
        case .latchReadback: failRead = 2
        case .baselineBefore: failWrite = 2
        case .baselineReadback: failRead = 3
        case .stageBefore: failWrite = 3
        case .stageReadback: failRead = 4
        case .promotionBefore: failWrite = 4
        case .promotionReadback: failRead = 5
        case .clearBefore: failWrite = 5
        case .clearReadback: failRead = 7
        default: break
        }
    }
    func clearFaults() { failRead = nil; failWrite = nil }
    func actual() throws -> ContinuityAnchor? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(ContinuityAnchor.self, from: Data(contentsOf: path))
    }
    func read() throws -> ContinuityAnchor? {
        reads += 1
        if reads == failRead { throw ContinuityStoreError.unavailable }
        return try actual()
    }
    func write(_ anchor: ContinuityAnchor) throws {
        writes += 1
        if writes == failWrite { throw ContinuityStoreError.failed }
        if failReceivePromotion, anchor.pending == nil, anchor.recovery == nil,
           try actual()?.pending?.classification == "receive.allocate" { throw ContinuityStoreError.failed }
        try JSONEncoder().encode(anchor).write(to: path, options: .atomic)
        history.append(anchor)
    }
}
private struct RecoveryFixture {
    let folder: URL
    let path: String
    let journal: SQLiteJournal
    let database: RecoveryDatabase
    let anchor: RecoveryAnchor
    let continuity: ContinuityCoordinator
    let policy: AuthorityPolicy
    let owner: OwnerAuthenticationEvidence
    let peer: PeerEvidence
    var controls: OwnerWalletControl { OwnerWalletControl(continuity: continuity, policy: policy) }
    init(state: CanonicalState, anchor initialAnchor: ContinuityAnchor? = nil) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        path = folder.appendingPathComponent("store.sqlite").path
        journal = try SQLiteJournal(path: path)
        try journal.write(state)
        database = RecoveryDatabase(journal)
        anchor = RecoveryAnchor(folder.appendingPathComponent("independent-anchor.json"))
        try anchor.write(initialAnchor ?? ContinuityAnchor(committed: state.reference()))
        continuity = ContinuityCoordinator(database: database, anchor: anchor)
        let ownerID = SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "owner")
        let bridgeID = SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "bridge")
        policy = AuthorityPolicy(bridge: bridgeID, owner: ownerID, accountIDs: ["account"],
            capabilities: ["read", "prepare", "submit", "cancel", "receive", "sync"], ownerAuthenticationAge: 1_000)
        owner = OwnerAuthenticationEvidence(peer: PeerEvidence(identity: ownerID, signatureValidated: true),
            authenticationSucceeded: true, authenticatedAt: 1_000)
        peer = PeerEvidence(identity: bridgeID, signatureValidated: true)
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}
private let recoveryCredential = Data(repeating: 0x36, count: 32)
private struct RecoveryClock: PaymentClock {
    func read() -> PaymentClockReading { .init(wall: 1_000, monotonic: 100) }
}
private struct UnusedRecoverySeedProvider: SeedAccountProvider {
    func generateMnemonic() throws -> Data { throw ContinuityError.invalidState }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount { throw ContinuityError.invalidState }
}
private func recoveryVault() -> WalletSeedVault {
    WalletSeedVault(keys: InjectedWrappingKeySource(read: { .available(SymmetricKey(data: Data(repeating: 7, count: 32))) }),
        accounts: UnusedRecoverySeedProvider())
}
private func recoveryState() throws -> CanonicalState {
    let ledger = AuthorizationLedger(walletID: "wallet", network: "mainnet", generation: 1, grants: [
        GrantRecord(id: "grant", integrationID: "integration", accountIDs: ["account"],
            capabilities: ["read", "prepare", "submit", "cancel", "receive", "sync"], credentialDigest: paymentDigest(recoveryCredential),
            credentialGeneration: 1, expiresAt: nil, revoked: false)])
    var state = CanonicalState(installationID: "installation", authorization: ledger, commitID: "original", mode: .enabled, history: .complete)
    let payload = try PayloadProtector(profile: .encrypted, walletID: "wallet",
        wrappingKey: .available(SymmetricKey(data: Data(repeating: 7, count: 32)))).protect(Data("disposable fixture".utf8))
    state.custody = WalletCustodyRecord(walletID: "wallet", network: "mainnet", accountID: "account",
        encryptedMnemonic: payload, publicDescriptor: Data("synthetic-descriptor".utf8))
    state.payments = [PaymentRecord(id: "possible", accountID: "account", network: "mainnet", originGrantID: "grant",
        canonicalBytes: Data([1, 2, 3]), transactionDigest: Data([4]), selectedInputs: ["input"], change: Data([5]),
        disposition: .possiblyRelayed, liabilityUnresolved: true, attempts: [], evidence: [], closures: []),
        PaymentRecord(id: "unsubmitted", accountID: "account", network: "mainnet", originGrantID: "grant",
        canonicalBytes: Data([6]), transactionDigest: Data([7]), selectedInputs: ["other-input"], change: Data(),
        disposition: .unsubmitted, liabilityUnresolved: false, attempts: [], evidence: [], closures: [])]
    state.requests = [RequestRecord(id: "request", principalID: "integration", paymentID: "possible", method: "prepare_payment",
        key: String(repeating: "b", count: 32), binding: Data([8]), disposition: .consumed, result: Data([9]),
        consumedAttemptID: nil, tombstone: true),
        RequestRecord(id: "unsubmitted-request", principalID: "integration", paymentID: "unsubmitted", method: "prepare_payment",
        key: String(repeating: "c", count: 32), binding: Data([10]), disposition: .unsubmitted, result: Data([11]),
        consumedAttemptID: nil, tombstone: false)]
    state.approvals = [ApprovalRecord(id: "approval", paymentID: "unsubmitted", generation: 1, context: Data([12]), active: true)]
    state.gates = [SpendingGate(accountID: "account", liabilityIDs: ["possible"], restrictions: ["uncertain"])]
    state.allocations = [AllocationRecord(accountID: "account", branch: "receiving", issuedIndices: [0, 1],
        issuedHighWater: 1, confirmedHistoryHorizon: 0, issuanceEvidence: Data([13]))]
    return state
}
private final class RecoveryPaymentBoundary: PaymentExecutionBoundary, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let outcome: PaymentTransportResult
    init(outcome: PaymentTransportResult = .accepted(source: "synthetic")) { self.outcome = outcome }
    var handoffs: Int { lock.withLock { count } }
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview {
        PaymentPreview(operationID: request.operationID, accountID: request.accountID, network: request.network,
            destinationScript: request.destinationScript, amount: request.amount, fee: 100, selectedInputs: ["input"],
            change: Data([1]), templateDigest: paymentDigest(try paymentEncoding(request)), leaseDeadline: 10_000)
    }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment {
        let bytes = try paymentEncoding(preview)
        return SignedPayment(operationID: preview.operationID, bytes: bytes, digest: paymentDigest(bytes))
    }
    func preflight(_ payment: SignedPayment) async throws {}
    func validateAdmission(_ payment: SignedPayment) throws {
        guard !payment.bytes.isEmpty, payment.digest == paymentDigest(payment.bytes) else { throw PaymentFailure.invalidRequest }
    }
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        try admission {
            lock.withLock { count += 1 }
            return PaymentTransportInvocation(id: UUID().uuidString, result: { self.outcome }, cancel: {})
        }
    }
    func dispose(operationID: String) async throws {}
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation {
        if case .unknown = outcome {
            return PaymentObservation(source: "synthetic", view: "view", chainTip: "tip", observedAt: 1_000, complete: true, fresh: true)
        }
        return PaymentObservation(source: "synthetic", view: "view", chainTip: "tip", observedAt: 1_000, complete: true, fresh: true,
            exactTransactionBytes: payment.canonicalBytes, spentConsistently: payment.selectedInputs,
            accountedInputs: payment.selectedInputs, changeTracked: true)
    }
}
private func waitForRecoveryPayment(_ id: String, disposition: PaymentDisposition, journal: SQLiteJournal) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try journal.read()?.payments.first(where: { $0.id == id })?.disposition == disposition { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw PaymentFailure.invalidTransition
}
private func backupSQLite(from source: String, to destination: String) throws {
    var sourceDB: OpaquePointer?
    var destinationDB: OpaquePointer?
    guard sqlite3_open_v2(source, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let sourceDB else {
        throw SQLiteJournalError.corruptState
    }
    defer { sqlite3_close_v2(sourceDB) }
    guard sqlite3_open_v2(destination, &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let destinationDB else { throw SQLiteJournalError.corruptState }
    defer { sqlite3_close_v2(destinationDB) }
    guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else { throw SQLiteJournalError.corruptState }
    let result = sqlite3_backup_step(backup, -1)
    let finished = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finished == SQLITE_OK else { throw SQLiteJournalError.corruptState }
}


private struct RecoveryReceiveBoundary: AccountChainBoundary {
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        AccountSyncRecord(accountID: accountID, network: network, providerID: "synthetic", viewID: "view", chainTip: "tip",
            observedAt: 1_000, complete: true, fresh: true, balance: 0, snapshot: Data(), receivingHorizon: -1, changeHorizon: -1)
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        "synthetic-address-\(index)"
    }
}
