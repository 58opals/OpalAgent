import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AgentServiceCore

private final class PaymentTestClock: PaymentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var reading = PaymentClockReading(wall: 1_000, monotonic: 100)
    func read() -> PaymentClockReading { lock.withLock { reading } }
    func advance(_ seconds: UInt64) { lock.withLock { reading.wall += Int64(seconds); reading.monotonic += seconds } }
}
private final class PaymentFileAnchor: ContinuityAnchorStore, @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var beforeWrite: (@Sendable (ContinuityAnchor) throws -> Void)?
    func setBeforeWrite(_ hook: @escaping @Sendable (ContinuityAnchor) throws -> Void) { lock.withLock { beforeWrite = hook } }
    init(_ path: String) { self.path = path }
    func read() throws -> ContinuityAnchor? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try JSONDecoder().decode(ContinuityAnchor.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    func write(_ value: ContinuityAnchor) throws {
        try lock.withLock { beforeWrite }?(value)
        try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
private actor PaymentLatch {
    private var opened = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var hasSuspendedWaiter: Bool { !waiters.isEmpty }
    func close() { opened = false }
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}
private final class PaymentBoundaryFixture: PaymentExecutionBoundary, @unchecked Sendable {
    let clock: PaymentTestClock
    let preparationLatch = PaymentLatch()
    let signingLatch = PaymentLatch()
    let preflightLatch = PaymentLatch()
    let handoffLatch = PaymentLatch()
    let resultLatch = PaymentLatch()
    let observationLatch = PaymentLatch()
    private let lock = NSLock()
    private var sent: [SignedPayment] = []
    private var outcome: PaymentTransportResult = .unknown(source: "fixture")
    private var observation: PaymentObservation?
    private var cleanupFails = false
    private var delayObservation = false
    private var observations = 0
    private var inputOverride: String?
    private var preflightFailure: PaymentFailure?
    private var preflights = 0
    private var preparations = 0
    private var disposals = 0
    private var signatures = 0
    private var admissionFailure: PaymentFailure?
    init(_ clock: PaymentTestClock) { self.clock = clock }
    var sentPayments: [SignedPayment] { lock.withLock { sent } }
    func setOutcome(_ value: PaymentTransportResult) { lock.withLock { outcome = value } }
    func setObservation(_ value: PaymentObservation?) { lock.withLock { observation = value } }
    var observationCount: Int { lock.withLock { observations } }
    var preflightCount: Int { lock.withLock { preflights } }
    var preparationCount: Int { lock.withLock { preparations } }
    var disposalCount: Int { lock.withLock { disposals } }
    var signingCount: Int { lock.withLock { signatures } }
    func delayNextObservation() { lock.withLock { delayObservation = true } }
    func setAdmissionFailure(_ value: PaymentFailure?) { lock.withLock { admissionFailure = value } }
    func setPreflightFailure(_ value: PaymentFailure?) { lock.withLock { preflightFailure = value } }
    func setInput(_ value: String?) { lock.withLock { inputOverride = value } }
    func setCleanupFailure(_ value: Bool) { lock.withLock { cleanupFails = value } }
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview {
        await preparationLatch.wait()
        lock.withLock { preparations += 1 }
        return PaymentPreview(operationID: request.operationID, accountID: request.accountID, network: request.network,
            destinationScript: request.destinationScript, amount: request.amount, fee: 100,
            selectedInputs: [lock.withLock { inputOverride } ?? "fixture-input-\(request.operationID)"], change: Data("change".utf8),
            templateDigest: paymentDigest(try paymentEncoding(request)), leaseDeadline: clock.read().wall + 3_600)
    }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment {
        lock.withLock { signatures += 1 }
        await signingLatch.wait()
        // This adapter supplies bytes only. Every state/admission/evidence outcome is decided by the engine.
        let bytes = try paymentEncoding(preview)
        return SignedPayment(operationID: preview.operationID, bytes: bytes, digest: paymentDigest(bytes))
    }
    func preflight(_ payment: SignedPayment) async throws {
        let failure = lock.withLock { preflights += 1; return preflightFailure }
        await preflightLatch.wait()
        if let failure { throw failure }
    }
    func validateAdmission(_ payment: SignedPayment) throws {
        if let failure = lock.withLock({ admissionFailure }) { throw failure }
    }
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        await handoffLatch.wait()
        return try admission {
            lock.withLock { sent.append(payment) }
            return PaymentTransportInvocation(id: UUID().uuidString, result: {
                await self.resultLatch.wait()
                return self.lock.withLock { self.outcome }
            }, cancel: { await self.resultLatch.open() })
        }
    }
    func dispose(operationID: String) async throws {
        lock.withLock { disposals += 1 }
        if lock.withLock({ cleanupFails }) { throw PaymentFailure.networkUnavailable }
    }
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation {
        let captured = lock.withLock { () -> (PaymentObservation?, Bool) in
            observations += 1
            let delayed = delayObservation
            delayObservation = false
            return (observation, delayed)
        }
        if captured.1 { await observationLatch.wait() }
        return captured.0 ?? PaymentObservation(source: "fixture", view: "view", chainTip: "tip",
            observedAt: clock.read().wall, complete: true, fresh: true)
    }
}
private struct PaymentFixture {
    let directory: URL
    let databasePath: String
    let anchor: PaymentFileAnchor
    let journal: SQLiteJournal
    let continuity: ContinuityCoordinator
    let engine: PaymentEngine
    let boundary: PaymentBoundaryFixture
    let clock: PaymentTestClock
    let policy: AuthorityPolicy
    let owner: OwnerAuthenticationEvidence
    let peer: PeerEvidence
    let session: AuthorizationSession
    let credential: Data
    func state() throws -> CanonicalState { try #require(try journal.read()) }
    func request(_ key: String = String(repeating: "a", count: 32)) -> PaymentRequest {
        PaymentRequest(accountID: "account", network: "mainnet", requestKey: key,
                       destinationScript: Data([0x51]), amount: 1_000)
    }
    func prepare(_ key: String = String(repeating: "a", count: 32)) async throws -> String {
        let result = try await engine.prepare(request(key), session: session, connectionID: "connection", peer: peer)
        try await wait(result.payment.id, disposition: .prepared)
        return result.payment.id
    }
    // This waits for a committed SQL phase, including deliberate crash prefixes.
    // Use continuity.inspect when completion requires a clean promoted anchor.
    func wait(_ id: String, disposition: PaymentDisposition) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try state().payments.first(where: { $0.id == id })?.disposition == disposition { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Payment \(id) did not reach \(disposition); actual \(try state().payments.first(where: { $0.id == id })?.disposition.rawValue ?? "missing")")
        throw PaymentFailure.invalidTransition
    }
    func ownerCommand(_ id: String, key: String = String(repeating: "b", count: 32)) throws -> OwnerRelayCommand {
        let state = try state(); let payment = try #require(state.payments.first { $0.id == id })
        return OwnerRelayCommand(key: key, operationID: id, accountID: payment.accountID, network: payment.network,
            transactionDigest: payment.transactionDigest, generation: state.authorization.generation,
            policyRevision: state.paymentPolicy.revision, evidenceRevision: payment.evidenceRevision,
            liabilityContextDigest: accountLiabilityContextDigest(accountID: payment.accountID, state: state))
    }
}
private func paymentFixture(approvalRequired: Bool = false,
    journalFault: @escaping @Sendable (SQLiteJournalFaultPoint) throws -> Void = { _ in }) throws -> PaymentFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("payment-engine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path, fault: journalFault)
    let anchor = PaymentFileAnchor(directory.appendingPathComponent("anchor.json").path)
    let credential = Data(repeating: 0x36, count: 32)
    let ledger = AuthorizationLedger(walletID: "wallet", network: "mainnet", generation: 1,
        grants: [GrantRecord(id: "grant", integrationID: "integration", accountIDs: ["account"],
            capabilities: ["read", "prepare", "submit", "cancel"], credentialDigest: paymentDigest(credential),
            credentialGeneration: 1, expiresAt: nil, revoked: false)])
    let ownerIdentity = SignedPeerIdentity(teamIdentifier: "fixture", signingIdentifier: "owner")
    let bridgeIdentity = SignedPeerIdentity(teamIdentifier: "fixture", signingIdentifier: "bridge")
    let peer = PeerEvidence(identity: bridgeIdentity, signatureValidated: true)
    let owner = OwnerAuthenticationEvidence(peer: PeerEvidence(identity: ownerIdentity, signatureValidated: true),
                                            authenticationSucceeded: true, authenticatedAt: 1_000)
    let policy = AuthorityPolicy(bridge: bridgeIdentity, owner: ownerIdentity, accountIDs: ["account"],
        capabilities: ["read", "prepare", "submit", "cancel"], ownerAuthenticationAge: 10_000)
    let payload = try PayloadProtector(profile: .encrypted, walletID: "wallet",
        wrappingKey: .available(SymmetricKey(data: Data(repeating: 0x44, count: 32)))).protect(Data("disposable fixture".utf8))
    var state = CanonicalState(installationID: "installation", authorization: ledger, mode: .enabled, history: .complete)
    state.custody = WalletCustodyRecord(walletID: "wallet", network: "mainnet", accountID: "account",
        encryptedMnemonic: payload, publicDescriptor: Data("fixture".utf8))
    state.paymentPolicy.approvalRequired = approvalRequired
    try journal.write(state)
    try anchor.write(ContinuityAnchor(committed: state.reference()))
    let continuity = ContinuityCoordinator(database: journal, anchor: anchor)
    let clock = PaymentTestClock(); let boundary = PaymentBoundaryFixture(clock)
    let engine = PaymentEngine(continuity: continuity, authorityPolicy: policy, boundary: boundary, clock: clock)
    let authority = AuthorizationAuthority(ledger: ledger, expectedBridgeIdentity: bridgeIdentity,
        trustedOwnerIdentity: ownerIdentity, maximumOwnerAuthenticationAge: 10_000)
    let session = try authority.authenticate(connectionID: "connection", peer: peer, credential: credential, now: 1_000)
    return PaymentFixture(directory: directory, databasePath: directory.appendingPathComponent("journal.sqlite").path,
        anchor: anchor, journal: journal, continuity: continuity, engine: engine, boundary: boundary, clock: clock,
        policy: policy, owner: owner, peer: peer, session: session, credential: credential)
}

@Test func paymentRequestIdentityAndCurrentDisclosureUseActualSQLite() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let first = try await f.engine.prepare(f.request(), session: f.session, connectionID: "connection", peer: f.peer)
    let equal = try await f.engine.prepare(f.request(), session: f.session, connectionID: "connection", peer: f.peer)
    #expect(first.payment.id == equal.payment.id)
    var changed = f.request(); changed.amount += 1
    await #expect(throws: PaymentFailure.conflictingRequest) {
        try await f.engine.prepare(changed, session: f.session, connectionID: "connection", peer: f.peer)
    }
    var malformed = f.request(); malformed.requestKey = String(repeating: "A", count: 32)
    await #expect(throws: PaymentFailure.invalidRequest) {
        try await f.engine.prepare(malformed, session: f.session, connectionID: "connection", peer: f.peer)
    }
    try await f.wait(first.payment.id, disposition: .prepared)
    let lookedUp = try await f.engine.lookup(requestKey: f.request().requestKey, session: f.session,
                                            connectionID: "connection", peer: f.peer)
    #expect(lookedUp.payment.disposition == .prepared)
    #expect(try f.state().requests.count == 1)
    #expect(try SQLiteJournal(path: f.databasePath).read()?.payments.count == 1)
    let wrong = PeerEvidence(identity: f.peer.identity, signatureValidated: false)
    await #expect(throws: PaymentFailure.unavailable) {
        try await f.engine.get(operationID: first.payment.id, session: f.session, connectionID: "connection", peer: wrong)
    }
}

@Test func pendingApprovalIsExactAndDuplicateApprovalCannotDuplicateFirstRelay() async throws {
    let f = try paymentFixture(approvalRequired: true); defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    let pending = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    #expect(pending.payment.disposition == .pendingApproval)
    #expect(f.boundary.sentPayments.isEmpty)
    async let a = f.engine.approve(operationID: id, owner: f.owner)
    async let b = f.engine.approve(operationID: id, owner: f.owner)
    _ = try? await (a, b)
    try await f.wait(id, disposition: .uncertain)
    #expect(f.boundary.sentPayments.count == 1)
    #expect(try f.state().approvals.count == 1)
    #expect(try f.state().payments.first?.ordinaryAdmissions == 1)
}

@Test func cancellationWhilePreparationSuspendsRetainsIdentityAndDisposesGate() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.boundary.preparationLatch.close()
    do {
        let operation = try await f.engine.prepare(f.request(), session: f.session, connectionID: "connection", peer: f.peer)
        try await waitBoundary { await f.boundary.preparationLatch.hasSuspendedWaiter }
        #expect(f.boundary.preparationCount == 0)
        let cancelled = try await f.engine.cancel(operationID: operation.payment.id, session: f.session,
                                                 connectionID: "connection", peer: f.peer)
        #expect(cancelled.payment.terminalReason == "cancelled")
        let retainedRequest = try #require(f.state().requests.first { $0.paymentID == operation.payment.id })
        let initialDisposals = f.boundary.disposalCount
        #expect(initialDisposals == 1)
        await f.boundary.preparationLatch.open()
        // A late returned plan must be disposed before shutdown closes new disposal admission.
        try await waitBoundary { f.boundary.disposalCount == initialDisposals + 1 }
        let replay = try await f.engine.prepare(f.request(), session: f.session, connectionID: "connection", peer: f.peer)
        #expect(replay.payment.id == operation.payment.id && replay.payment.disposition == .closed)
        await f.engine.shutdown()
        let final = try f.continuity.inspect { $0 }
        #expect(f.boundary.preparationCount == 1 && f.boundary.disposalCount == initialDisposals + 1)
        #expect(final.payments.first?.disposition == .closed && final.payments.first?.terminalReason == "cancelled")
        #expect(final.gates.isEmpty && final.requests.first { $0.paymentID == operation.payment.id } == retainedRequest)
        #expect(f.boundary.sentPayments.isEmpty)
    } catch {
        await f.boundary.preparationLatch.open()
        await f.engine.shutdown()
        throw error
    }
}

@Test func revocationWinsSuspendedHandoffAndDisallowsLaterResultDisclosure() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = try ServiceAuthority(continuity: f.continuity, policy: f.policy)
    await f.boundary.handoffLatch.close()
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .submitting)
    try service.revoke(id: "grant", owner: f.owner, now: f.clock.read().wall)
    await f.boundary.handoffLatch.open()
    try await f.wait(id, disposition: .closed)
    #expect(f.boundary.sentPayments.isEmpty)
    #expect(try f.state().payments.first?.terminalReason == "failedUnsubmitted")
    #expect(try f.state().payments.first?.evidence.contains { $0.source == "liveFirstAdmissionRefusal" && $0.valid } == true)
    await #expect(throws: PaymentFailure.unavailable) {
        try await f.engine.get(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    }
}

@Test func ordinaryThreeAdmissionBudgetAndOwnerReceiptSurviveReopen() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = try ServiceAuthority(continuity: f.continuity, policy: f.policy)
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .uncertain)
    await f.engine.continuePending()
    #expect(f.boundary.sentPayments.count == 1)
    f.clock.advance(30)
    await f.engine.continuePending()
    try await waitAdmission(f, id: id, count: 2)
    f.clock.advance(119)
    await f.engine.continuePending()
    #expect(try f.state().payments.first?.ordinaryAdmissions == 2)
    f.clock.advance(1)
    await f.engine.continuePending()
    try await waitAdmission(f, id: id, count: 3)
    f.clock.advance(1_000)
    await f.engine.continuePending()
    #expect(try f.state().payments.first?.ordinaryAdmissions == 3)
    let preflights = f.boundary.preflightCount
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    let rotated = try service.rotate(id: "grant", owner: f.owner, now: f.clock.read().wall)
    await #expect(throws: AuthorizationFailure.staleSession) {
        try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    }
    let currentSession = try service.authenticate(connectionID: "reconnected", peer: f.peer,
        credential: rotated.rawValue, now: f.clock.read().wall)
    let rotatedReplay = try await f.engine.prepare(f.request(), session: currentSession, connectionID: "reconnected", peer: f.peer)
    #expect(rotatedReplay.payment.id == id)
    let rotatedLookup = try await f.engine.lookup(requestKey: f.request().requestKey, session: currentSession,
        connectionID: "reconnected", peer: f.peer)
    #expect(rotatedLookup.payment.id == id && rotatedLookup.payment.ordinaryAdmissions == 3)
    _ = try await f.engine.submit(operationID: id, session: currentSession, connectionID: "reconnected", peer: f.peer)
    try await Task.sleep(for: .milliseconds(10))
    #expect(try f.state().payments.first?.blocker == "automaticRelayBudgetExhausted")
    #expect(f.boundary.preflightCount == preflights)
    #expect(f.boundary.sentPayments.count == 3)
    let command = try f.ownerCommand(id)
    _ = try await f.engine.authorizeRelay(command, owner: f.owner)
    try await waitAttemptCount(f, count: 4)
    _ = try await f.engine.authorizeRelay(command, owner: f.owner)
    #expect(f.boundary.sentPayments.count == 4)
    let reopened = try SQLiteJournal(path: f.databasePath)
    let continuity = ContinuityCoordinator(database: reopened, anchor: PaymentFileAnchor(f.anchor.path))
    _ = try continuity.startup()
    let engine = PaymentEngine(continuity: continuity, authorityPolicy: f.policy, boundary: f.boundary, clock: f.clock)
    _ = try await engine.authorizeRelay(command, owner: f.owner)
    #expect(f.boundary.sentPayments.count == 4)
    #expect(try reopened.read()?.requests.filter { $0.method == "authorize_payment_relay" }.count == 1)
    #expect(try reopened.read()?.payments.first?.ordinaryAdmissions == 3)
}

private func waitAdmission(_ f: PaymentFixture, id: String, count: UInt64) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        let row = try #require(f.state().payments.first { $0.id == id })
        if row.ordinaryAdmissions == count && row.disposition == .uncertain { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Expected \(count) ordinary admissions")
    throw PaymentFailure.invalidTransition
}
private func waitOrdinaryRejection(_ f: PaymentFixture, id: String, count: UInt64) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        let snapshot = try await f.engine.get(operationID: id, session: f.session,
            connectionID: "connection", peer: f.peer)
        if snapshot.payment.ordinaryAdmissions == count && snapshot.payment.disposition == .uncertain &&
            snapshot.payment.blocker == "relayNotEligible" { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Expected completed ineligible ordinary admission")
    throw PaymentFailure.invalidTransition
}
private func waitAttemptCount(_ f: PaymentFixture, count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try f.state().payments.first?.attempts.count == count && f.state().payments.first?.disposition == .uncertain { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw PaymentFailure.invalidTransition
}
private func positive(_ payment: PaymentRecord, clock: PaymentTestClock) -> PaymentObservation {
    PaymentObservation(source: "fixture", view: "view", chainTip: "tip", observedAt: clock.read().wall,
        complete: true, fresh: true, exactTransactionBytes: payment.canonicalBytes,
        spentConsistently: payment.selectedInputs, accountedInputs: payment.selectedInputs, changeTracked: true)
}

@Test func shutdownRetainsLateDecisiveEvidenceWithoutStartingAnotherDisposal() async throws {
    let f = try paymentFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .uncertain)
    let before = try await f.engine.get(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    f.boundary.setObservation(positive(before.payment, clock: f.clock))
    await f.boundary.observationLatch.close()
    f.boundary.delayNextObservation()
    let count = f.boundary.observationCount
    let observation = Task { try await f.engine.reconcile(operationID: id) }
    defer { Task { await f.boundary.observationLatch.open() } }
    try await waitObservation(f, count: count + 1)
    let stop = Task { await f.engine.shutdown() }
    // Observe terminal public admission, rather than infer it from task scheduling.
    let deadline = ContinuousClock.now + .seconds(5)
    var closed = false
    while ContinuousClock.now < deadline {
        do { _ = try await f.engine.get(operationID: id, session: f.session, connectionID: "connection", peer: f.peer) }
        catch PaymentFailure.unavailable { closed = true; break }
        await Task.yield()
    }
    try #require(closed)
    let disposals = f.boundary.disposalCount
    await f.boundary.observationLatch.open()
    try await observation.value
    await stop.value
    let state = try f.continuity.inspect { $0 }
    let after = try #require(state.payments.first { $0.id == id })
    #expect(f.boundary.disposalCount == disposals)
    #expect(after.evidenceSupported && after.liabilityUnresolved && after.blocker == "leaseCleanupFailed")
    #expect(after.evidence.contains { $0.valid && $0.observation?.exactTransactionBytes == before.payment.canonicalBytes })
    #expect(after.canonicalBytes == before.payment.canonicalBytes && after.attempts == before.payment.attempts)
    #expect(state.gates.contains { $0.liabilityIDs.contains(id) })
}

@Test func shutdownRetainsCleanupGateWhenStalePreflightResumes() async throws {
    let f = try paymentFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    let before = try f.continuity.inspect { $0 }
    await f.boundary.preflightLatch.close()
    defer { Task { await f.boundary.preflightLatch.open() } }
    f.boundary.setPreflightFailure(.staleContext)
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await waitBoundary { f.boundary.preflightCount == 1 }
    let disposals = f.boundary.disposalCount
    let stop = Task { await f.engine.shutdown() }
    // The boundary stays paused until terminal public admission is observed.
    let deadline = ContinuousClock.now + .seconds(5)
    var closed = false
    while ContinuousClock.now < deadline {
        do { _ = try await f.engine.get(operationID: id, session: f.session, connectionID: "connection", peer: f.peer) }
        catch PaymentFailure.unavailable { closed = true; break }
        await Task.yield()
    }
    try #require(closed)
    await f.boundary.preflightLatch.open()
    await stop.value
    let state = try f.continuity.inspect { $0 }
    let after = try #require(state.payments.first { $0.id == id })
    #expect(f.boundary.disposalCount == disposals)
    #expect(f.boundary.sentPayments.isEmpty && after.attempts.isEmpty && after.ordinaryAdmissions == 0)
    #expect(after.disposition == .closed && after.terminalReason == "invalidated" && !after.liabilityUnresolved)
    #expect(after.closures.contains { $0.reason == "invalidated" && $0.evidenceIDs.isEmpty })
    #expect(after.evidence.isEmpty && after.canonicalBytes.isEmpty)
    #expect(state.gates == before.gates && state.gates.contains { $0.liabilityIDs.contains(id) })
    #expect(state.requests.contains { $0.paymentID == id && $0.disposition == .closed && $0.tombstone })
}

@Test func acceptanceClosureInvalidationAndOwnerReopenNeverRestoreOrdinaryAllowance() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    f.boundary.setOutcome(.accepted(source: "relay"))
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .accepted)
    #expect(try !f.state().gates.isEmpty)
    let accepted = try #require(f.state().payments.first)
    f.boundary.setObservation(positive(accepted, clock: f.clock))
    try await f.engine.reconcile(operationID: id)
    #expect(try f.state().gates.isEmpty)
    #expect(try f.state().payments.first?.terminalReason == "reconciledAccepted")
    f.boundary.setObservation(PaymentObservation(source: "replacement", view: "new", chainTip: "other",
        observedAt: f.clock.read().wall, complete: true, fresh: true, supportRemoved: true))
    try await f.engine.reconcile(operationID: id)
    #expect(try f.state().payments.first?.liabilityUnresolved == true)
    #expect(try !f.state().gates.isEmpty)
    let replay = try await f.engine.lookup(requestKey: f.request().requestKey, session: f.session,
        connectionID: "connection", peer: f.peer)
    #expect(replay.payment.id == id)
    #expect(f.boundary.sentPayments.count == 1)
    f.clock.advance(1_000)
    await f.engine.continuePending()
    #expect(f.boundary.sentPayments.count == 1)
    f.boundary.setOutcome(.unknown(source: "owner relay"))
    _ = try await f.engine.authorizeRelay(f.ownerCommand(id), owner: f.owner)
    try await waitAttemptCount(f, count: 2)
    #expect(try f.state().payments.first?.ordinaryAdmissions == 1)
    #expect(try f.state().payments.first?.closures.count == 1)
    #expect(try f.state().payments.first?.liabilityUnresolved == true)
}

@Test func incompleteObservationCannotUnlockOrAdmitRetryAndActiveCallHoldsSlot() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.boundary.resultLatch.close()
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .submitting)
    await #expect(throws: PaymentFailure.transportBusy) {
        try await f.engine.authorizeRelay(f.ownerCommand(id), owner: f.owner)
    }
    await f.engine.cancelLocalTransport()
    try await f.wait(id, disposition: .uncertain)
    f.boundary.setObservation(PaymentObservation(source: "fixture", view: "view", chainTip: "tip",
        observedAt: f.clock.read().wall, complete: false, fresh: true))
    f.clock.advance(1_000)
    await f.engine.continuePending()
    try await Task.sleep(for: .milliseconds(10))
    #expect(f.boundary.sentPayments.count == 1)
    #expect(try f.state().payments.first?.liabilityUnresolved == true)
    f.boundary.setObservation(nil)
    await f.engine.continuePending()
    try await waitAdmission(f, id: id, count: 2)
    #expect(f.boundary.sentPayments[0].bytes == f.boundary.sentPayments[1].bytes)
}

@Test func reversedObservationAndRecoveryGenerationCannotApplyStalePositiveEvidence() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    f.boundary.setOutcome(.accepted(source: "relay"))
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .accepted)
    let row = try #require(f.state().payments.first)
    f.boundary.setObservation(positive(row, clock: f.clock))
    await f.boundary.observationLatch.close()
    f.boundary.delayNextObservation()
    let old = Task { try await f.engine.reconcile(operationID: id) }
    try await waitObservation(f, count: 1)
    f.boundary.setObservation(PaymentObservation(source: "fixture", view: "view", chainTip: "newtip",
        observedAt: f.clock.read().wall, complete: true, fresh: true, supportRemoved: true))
    try await f.engine.reconcile(operationID: id)
    await f.boundary.observationLatch.open()
    try await old.value
    let invalidated = try #require(f.state().payments.first)
    #expect(invalidated.liabilityUnresolved && !invalidated.evidenceSupported)
    #expect(invalidated.closures.isEmpty)
    #expect(invalidated.evidence.contains { !$0.valid && $0.observation?.exactTransactionBytes == row.canonicalBytes })
    #expect(try !f.state().gates.isEmpty)

    // A late invalid observation must not become the baseline of a later provider change.
    var viewA = positive(row, clock: f.clock); viewA.view = "A"
    var viewB = positive(row, clock: f.clock); viewB.view = "B"
    f.boundary.setObservation(viewA)
    await f.boundary.observationLatch.close()
    f.boundary.delayNextObservation()
    let countBeforeLate = f.boundary.observationCount
    let lateA = Task { try await f.engine.reconcile(operationID: id) }
    try await waitObservation(f, count: countBeforeLate + 1)
    f.boundary.setObservation(viewB)
    try await f.engine.reconcile(operationID: id)
    await f.boundary.observationLatch.open()
    try await lateA.value
    #expect(try f.state().gates.isEmpty)
    f.boundary.setObservation(PaymentObservation(source: "fixture", view: "A", chainTip: "same",
        observedAt: f.clock.read().wall, complete: true, fresh: true))
    try await f.engine.reconcile(operationID: id)
    #expect(try f.state().payments.first?.liabilityUnresolved == true)
    #expect(try !f.state().gates.isEmpty)

    f.boundary.setObservation(positive(row, clock: f.clock))
    await f.boundary.observationLatch.close()
    f.boundary.delayNextObservation()
    let before = f.boundary.observationCount
    let oldGeneration = Task { try await f.engine.reconcile(operationID: id) }
    try await waitObservation(f, count: before + 1)
    let closuresBeforeReset = try #require(f.state().payments.first).closures
    let reset = try f.continuity.recover(ownerAuthorized: true, recoveryID: "payment-observation-reset")
    await f.boundary.observationLatch.open()
    try await oldGeneration.value
    let recovered = try f.state()
    #expect(recovered.authorization.generation == reset.authorization.generation)
    #expect(recovered.mode == .restricted)
    #expect(recovered.payments.first?.liabilityUnresolved == true)
    #expect(recovered.payments.first?.closures == closuresBeforeReset)
    #expect(recovered.payments.first?.evidence.contains { !$0.valid && $0.observation?.exactTransactionBytes == row.canonicalBytes } == true)
}

private func waitObservation(_ f: PaymentFixture, count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if f.boundary.observationCount >= count { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw PaymentFailure.invalidTransition
}

@Test(arguments: [false, true])
func multipleLiabilitiesAndUncertainChildDoNotVetoOwnerExactParentRelay(child: Bool) async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    f.boundary.setOutcome(.accepted(source: "relay"))
    let a = try await f.prepare()
    _ = try await f.engine.submit(operationID: a, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(a, disposition: .accepted)
    let parent = try #require(f.state().payments.first { $0.id == a })
    f.boundary.setObservation(positive(parent, clock: f.clock))
    try await f.engine.reconcile(operationID: a)
    if child { f.boundary.setInput("parent-change:\(parent.transactionDigest.base64EncodedString())") }
    f.boundary.setOutcome(child ? .unknown(source: "child") : .accepted(source: "relay"))
    let b = try await f.prepare(String(repeating: "c", count: 32))
    _ = try await f.engine.submit(operationID: b, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(b, disposition: child ? .uncertain : .accepted)
    let second = try #require(f.state().payments.first { $0.id == b })
    if !child {
        f.boundary.setObservation(positive(second, clock: f.clock))
        try await f.engine.reconcile(operationID: b)
    }
    f.boundary.setObservation(PaymentObservation(source: "replacement", view: "newview", chainTip: "other",
        observedAt: f.clock.read().wall, complete: true, fresh: true, supportRemoved: true))
    try await f.engine.reconcile(operationID: a)
    try await f.engine.reconcile(operationID: b)
    let held = try #require(f.state().gates.first)
    #expect(Set(held.liabilityIDs) == Set([a, b]))
    let bytesA = parent.canonicalBytes; let bytesB = second.canonicalBytes
    f.boundary.setOutcome(.unknown(source: "owner"))
    await f.boundary.resultLatch.close()
    let commandA = try f.ownerCommand(a)
    _ = try await f.engine.authorizeRelay(commandA, owner: f.owner)
    await #expect(throws: PaymentFailure.transportBusy) {
        try await f.engine.authorizeRelay(f.ownerCommand(b, key: String(repeating: "d", count: 32)), owner: f.owner)
    }
    await f.boundary.resultLatch.open()
    try await f.wait(a, disposition: .uncertain)
    let commandB = try f.ownerCommand(b, key: String(repeating: "d", count: 32))
    _ = try await f.engine.authorizeRelay(commandB, owner: f.owner)
    try await f.wait(b, disposition: .uncertain)
    let final = try f.state()
    #expect(Set(try #require(final.gates.first).liabilityIDs) == Set([a, b]))
    #expect(final.payments.first { $0.id == a }?.canonicalBytes == bytesA)
    #expect(final.payments.first { $0.id == b }?.canonicalBytes == bytesB)
    #expect(final.payments.first { $0.id == a }?.ordinaryAdmissions == 1)
    #expect(final.payments.first { $0.id == b }?.ordinaryAdmissions == 1)
    _ = try await f.engine.authorizeRelay(commandA, owner: f.owner)
    #expect(f.boundary.sentPayments.count == 4)
}

@Test func terminalOwnerDecisionIsRetainedAndChangedContextConflicts() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .uncertain)
    var stale = try f.ownerCommand(id); stale.evidenceRevision += 1
    await #expect(throws: PaymentFailure.staleContext) { try await f.engine.authorizeRelay(stale, owner: f.owner) }
    let replay = try await f.engine.authorizeRelay(stale, owner: f.owner)
    #expect(replay.ownerReceipt?.consumedAttemptID == nil)
    #expect(replay.ownerReceipt?.result.isEmpty == false)
    #expect(f.boundary.sentPayments.count == 1)
    var changed = stale; changed.evidenceRevision -= 1
    await #expect(throws: PaymentFailure.conflictingRequest) { try await f.engine.authorizeRelay(changed, owner: f.owner) }
}

@Test func closedSupportUnavailableBlocksSelectionUntilPositiveRevalidation() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .uncertain)
    let row = try #require(f.state().payments.first)
    f.boundary.setObservation(positive(row, clock: f.clock))
    try await f.engine.reconcile(operationID: id)
    #expect(try f.state().gates.isEmpty)
    f.boundary.setObservation(PaymentObservation(source: "fixture", view: "view", chainTip: "tip",
        observedAt: f.clock.read().wall, complete: false, fresh: false))
    try await f.engine.reconcile(operationID: id)
    #expect(try f.state().payments.first?.disposition == .closed)
    #expect(try f.state().payments.first?.evidenceSupported == true)
    await #expect(throws: PaymentFailure.accountRestricted) {
        try await f.engine.prepare(f.request(String(repeating: "e", count: 32)), session: f.session,
                                   connectionID: "connection", peer: f.peer)
    }
    f.boundary.setObservation(positive(row, clock: f.clock))
    try await f.engine.reconcile(operationID: id)
    #expect(try f.state().gates.isEmpty)
}

@Test func unavailablePreflightConsumesNothingAndRepairedEvidenceUsesOwnerOnlyAdmission() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    f.boundary.setPreflightFailure(.keyUnavailable)
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await waitBoundary { (try? f.continuity.inspect { $0.payments.first?.blocker }) == "keyUnavailable" }
    #expect(f.boundary.preflightCount == 1)
    #expect(try f.state().payments.first?.attempts.isEmpty == true)
    #expect(f.boundary.sentPayments.isEmpty)
    f.boundary.setPreflightFailure(nil)
    await f.engine.continuePending()
    try await f.wait(id, disposition: .uncertain)
    try await f.engine.requireEvidenceRepair(operationID: id, reason: "required previous-output source unavailable")
    let command = try f.ownerCommand(id)
    f.boundary.setPreflightFailure(.recoveryRequired)
    await #expect(throws: PaymentFailure.recoveryRequired) { try await f.engine.authorizeRelay(command, owner: f.owner) }
    #expect(try f.state().payments.first?.attempts.count == 1)
    f.boundary.setPreflightFailure(nil)
    _ = try await f.engine.authorizeRelay(command, owner: f.owner)
    try await waitAttemptCount(f, count: 2)
    #expect(try f.state().payments.first?.ordinaryAdmissions == 1)
    _ = try await f.engine.authorizeRelay(command, owner: f.owner)
    #expect(f.boundary.sentPayments.count == 2)
}

@Test func restrictedContinuationReconcilesWithoutLoadingKeysOrChangingDisabledAuthority() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .uncertain)
    try f.continuity.transaction { $0.authorization.grants[0].expiresAt = f.clock.read().wall + 5 }
    let row = try #require(f.state().payments.first)
    let reset = try f.continuity.recover(ownerAuthorized: true, recoveryID: "restricted-passive")
    f.clock.advance(10)
    let preflights = f.boundary.preflightCount
    f.boundary.setObservation(positive(row, clock: f.clock))
    await f.engine.continuePending()
    try await f.wait(id, disposition: .closed)
    let final = try f.state()
    #expect(final.mode == .restricted)
    #expect(final.authorization.generation == reset.authorization.generation)
    #expect(final.authorization.grants[0].revoked)
    #expect(!final.authorization.grants[0].expiredObserved)
    #expect(final.gates.isEmpty)
    #expect(f.boundary.preflightCount == preflights)
    #expect(f.boundary.sentPayments.count == 1)
}

@Test func newPreparationRevalidatesClosedEvidenceBeforeAnyValueSelection() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let a = try await f.prepare()
    _ = try await f.engine.submit(operationID: a, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(a, disposition: .uncertain)
    let parent = try #require(f.state().payments.first)
    f.boundary.setObservation(positive(parent, clock: f.clock))
    try await f.engine.reconcile(operationID: a)
    let selections = f.boundary.preparationCount
    f.boundary.setObservation(PaymentObservation(source: "replacement", view: "different", chainTip: "tip2",
        observedAt: f.clock.read().wall, complete: true, fresh: true, supportRemoved: true))
    // No explicit continuation or reconciliation precedes B: its owning preparation must do it.
    let b = try await f.engine.prepare(f.request(String(repeating: "c", count: 32)), session: f.session,
        connectionID: "connection", peer: f.peer)
    try await f.wait(b.payment.id, disposition: .closed)
    #expect(f.boundary.preparationCount == selections)
    let state = try f.state()
    #expect(state.payments.first { $0.id == a }?.liabilityUnresolved == true)
    #expect(state.payments.first { $0.id == b.payment.id }?.terminalReason == "invalidated")
    #expect(state.gates.contains { $0.liabilityIDs.contains(a) })
}

@Test func ownerReviewBindsMaterialOtherLiabilityChangesButConsumedReceiptSurvives() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let a = try await f.prepare()
    _ = try await f.engine.submit(operationID: a, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(a, disposition: .uncertain)
    let parent = try #require(f.state().payments.first { $0.id == a })
    f.boundary.setObservation(positive(parent, clock: f.clock))
    try await f.engine.reconcile(operationID: a)
    let b = try await f.prepare(String(repeating: "c", count: 32))
    _ = try await f.engine.submit(operationID: b, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(b, disposition: .uncertain)
    let other = try #require(f.state().payments.first { $0.id == b })
    f.boundary.setObservation(PaymentObservation(source: "changed", view: "changed", chainTip: "other",
        observedAt: f.clock.read().wall, complete: true, fresh: true, supportRemoved: true))
    try await f.engine.reconcile(operationID: a)
    let reviewed = try f.ownerCommand(a)
    f.boundary.setObservation(positive(other, clock: f.clock))
    try await f.engine.reconcile(operationID: b)
    await #expect(throws: PaymentFailure.staleContext) { try await f.engine.authorizeRelay(reviewed, owner: f.owner) }
    let fresh = try f.ownerCommand(a, key: String(repeating: "d", count: 32))
    _ = try await f.engine.authorizeRelay(fresh, owner: f.owner)
    try await f.wait(a, disposition: .uncertain)
    let admitted = try await f.engine.authorizeRelay(fresh, owner: f.owner)
    #expect(admitted.ownerReceipt?.consumedAttemptID != nil)
    // A later material change must not turn receipt lookup into a new admission or denial.
    f.boundary.setObservation(PaymentObservation(source: "removed", view: "removed", chainTip: "next",
        observedAt: f.clock.read().wall, complete: true, fresh: true, supportRemoved: true))
    try await f.engine.reconcile(operationID: b)
    let replay = try await f.engine.authorizeRelay(fresh, owner: f.owner)
    #expect(replay.ownerReceipt?.consumedAttemptID == admitted.ownerReceipt?.consumedAttemptID)
    #expect(f.boundary.sentPayments.count == 3)
}

@Test func reenrollmentWithReusedIntegrationLabelCannotDiscloseRevokedGrantHistory() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = try ServiceAuthority(continuity: f.continuity, policy: f.policy)
    let id = try await f.prepare()
    _ = try await f.engine.cancel(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try service.revoke(id: "grant", owner: f.owner, now: f.clock.read().wall)
    let new = try service.enroll(id: "different-grant", integrationID: "integration", accounts: ["account"],
        capabilities: ["read", "prepare", "submit", "cancel"], expiry: nil, owner: f.owner, now: f.clock.read().wall)
    let session = try service.authenticate(connectionID: "new-connection", peer: f.peer,
        credential: new.rawValue, now: f.clock.read().wall)
    await #expect(throws: PaymentFailure.unavailable) {
        try await f.engine.get(operationID: id, session: session, connectionID: "new-connection", peer: f.peer)
    }
    await #expect(throws: PaymentFailure.unavailable) {
        try await f.engine.prepare(f.request(), session: session, connectionID: "new-connection", peer: f.peer)
    }
    #expect(try f.state().payments.count == 1)
    #expect(try f.state().requests.count == 1)
}

@Test func confirmedConflictClosureReorgAndOwnerRelayKeepExactIdentity() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .uncertain)
    let row = try #require(f.state().payments.first)
    var conflict = PaymentObservation(source: "fixture", view: "view", chainTip: "tip", observedAt: f.clock.read().wall,
        complete: true, fresh: true, accountedInputs: row.selectedInputs, changeTracked: true,
        confirmedConflictInputs: row.selectedInputs, canonicalConflict: false)
    f.boundary.setObservation(conflict)
    try await f.engine.reconcile(operationID: id)
    #expect(try f.state().payments.first?.disposition == .uncertain)
    conflict.canonicalConflict = true
    f.boundary.setObservation(conflict)
    try await f.engine.reconcile(operationID: id)
    #expect(try f.state().payments.first?.terminalReason == "reconciledConflict")
    #expect(try f.state().gates.isEmpty)
    await #expect(throws: PaymentFailure.relayNotEligible) {
        try await f.engine.authorizeRelay(f.ownerCommand(id, key: String(repeating: "f", count: 32)), owner: f.owner)
    }
    f.boundary.setObservation(PaymentObservation(source: "fixture", view: "view", chainTip: "reorg",
        observedAt: f.clock.read().wall, complete: true, fresh: true, supportRemoved: true))
    try await f.engine.reconcile(operationID: id)
    let command = try f.ownerCommand(id)
    _ = try await f.engine.authorizeRelay(command, owner: f.owner)
    try await waitAttemptCount(f, count: 2)
    #expect(try f.state().payments.first?.canonicalBytes == row.canonicalBytes)
    #expect(try f.state().payments.first?.closures.first?.reason == "reconciledConflict")
    #expect(try f.state().payments.first?.liabilityUnresolved == true)
}

@Test func reversedAttemptUUIDsCannotShortenThirdDelayAcrossSQLiteReopen() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .uncertain)
    f.clock.advance(30)
    await f.engine.continuePending()
    try await waitAdmission(f, id: id, count: 2)
    // Join the result commit and runner cleanup before replacing persisted fixture state.
    _ = try await f.engine.get(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    // Establish a deterministic restored fixture whose UUID ordering opposes admission order.
    var retained = try f.state()
    let index = try #require(retained.payments.firstIndex { $0.id == id })
    retained.payments[index].attempts[0].id = "zzzz-first"
    retained.payments[index].attempts[1].id = "aaaa-second"
    try f.journal.write(retained)
    try f.anchor.write(ContinuityAnchor(committed: retained.reference()))
    let reopened = try SQLiteJournal(path: f.databasePath)
    #expect(try reopened.read()?.payments.first?.attempts.map(\.id) == ["zzzz-first", "aaaa-second"])
    #expect(try f.state().payments.first?.blocker == nil)
    f.clock.advance(119)
    await f.engine.continuePending()
    // Observe this refusal through the actor after its scheduled runner has relinquished ownership.
    try await waitOrdinaryRejection(f, id: id, count: 2)
    #expect(try f.state().payments.first?.ordinaryAdmissions == 2)
    f.clock.advance(1)
    await f.engine.continuePending()
    try await waitAdmission(f, id: id, count: 3)
    #expect(f.boundary.sentPayments.count == 3)
}

private func reopenPaymentFixture(databasePath: String, anchorPath: String,
                                  clock: PaymentTestClock = PaymentTestClock()) throws -> PaymentFixture {
    let journal = try SQLiteJournal(path: databasePath)
    let anchor = PaymentFileAnchor(anchorPath)
    let continuity = ContinuityCoordinator(database: journal, anchor: anchor)
    _ = try continuity.startup()
    let state = try #require(try journal.read())
    let ownerIdentity = SignedPeerIdentity(teamIdentifier: "fixture", signingIdentifier: "owner")
    let bridgeIdentity = SignedPeerIdentity(teamIdentifier: "fixture", signingIdentifier: "bridge")
    let policy = AuthorityPolicy(bridge: bridgeIdentity, owner: ownerIdentity, accountIDs: ["account"],
        capabilities: ["read", "prepare", "submit", "cancel"], ownerAuthenticationAge: 10_000)
    let peer = PeerEvidence(identity: bridgeIdentity, signatureValidated: true)
    let owner = OwnerAuthenticationEvidence(peer: PeerEvidence(identity: ownerIdentity, signatureValidated: true),
        authenticationSucceeded: true, authenticatedAt: 1_000)
    let credential = Data(repeating: 0x36, count: 32)
    let session = try AuthorizationAuthority(ledger: state.authorization, expectedBridgeIdentity: bridgeIdentity,
        trustedOwnerIdentity: ownerIdentity, maximumOwnerAuthenticationAge: 10_000).authenticate(
            connectionID: "connection", peer: peer, credential: credential, now: clock.read().wall)
    let boundary = PaymentBoundaryFixture(clock)
    let engine = PaymentEngine(continuity: continuity, authorityPolicy: policy, boundary: boundary, clock: clock)
    return PaymentFixture(directory: URL(fileURLWithPath: databasePath).deletingLastPathComponent(), databasePath: databasePath,
        anchor: anchor, journal: journal, continuity: continuity, engine: engine, boundary: boundary, clock: clock,
        policy: policy, owner: owner, peer: peer, session: session, credential: credential)
}

enum PaymentCrashPrefix: String, Codable, Sendable, CaseIterable {
    case cleanAdmission, transport, acceptedBeforePersistence, acceptedBeforeCleanup
}
@Test func knownProviderChangeBeforeAdmissionConsumesNoAttempt() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    f.boundary.setAdmissionFailure(.staleContext)
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .closed)
    let row = try #require(f.state().payments.first)
    #expect(row.terminalReason == "invalidated")
    #expect(row.attempts.isEmpty)
    #expect(row.ordinaryAdmissions == 0)
    #expect(f.boundary.sentPayments.isEmpty)
}

@Test func newRuntimeWaitsFullDelayDespiteOldWallEligibility() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .uncertain)
    // SQL phase visibility can precede anchor promotion. Join the original writer
    // through its verified read before assembling a separate restarted coordinator.
    let settled = try await f.engine.get(operationID: id, session: f.session,
        connectionID: "connection", peer: f.peer)
    #expect(settled.payment.disposition == .uncertain && settled.payment.ordinaryAdmissions == 1)
    f.clock.advance(1_000)
    let restarted = try reopenPaymentFixture(databasePath: f.databasePath, anchorPath: f.anchor.path, clock: f.clock)
    await restarted.engine.continuePending()
    try await Task.sleep(for: .milliseconds(10))
    #expect(try restarted.state().payments.first?.ordinaryAdmissions == 1)
    f.clock.advance(29)
    await restarted.engine.continuePending()
    try await Task.sleep(for: .milliseconds(10))
    #expect(try restarted.state().payments.first?.ordinaryAdmissions == 1)
    f.clock.advance(1)
    await restarted.engine.continuePending()
    try await waitAdmission(restarted, id: id, count: 2)
    #expect(restarted.boundary.sentPayments.count == 1)
}

private func waitBoundary(_ predicate: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("External boundary did not reach expected phase")
    throw PaymentFailure.invalidTransition
}

enum SigningRace: String, Sendable, CaseIterable {
    case cancel, revoke, rotate, policy, leaseExpiry
}
@Test(arguments: SigningRace.allCases)
func authorityOrCancellationWinnerDuringSigningCannotAdmit(race: SigningRace) async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = try ServiceAuthority(continuity: f.continuity, policy: f.policy)
    await f.boundary.signingLatch.close()
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await waitBoundary { f.boundary.signingCount == 1 }
    switch race {
    case .cancel:
        _ = try await f.engine.cancel(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    case .revoke: try service.revoke(id: "grant", owner: f.owner, now: f.clock.read().wall)
    case .rotate: _ = try service.rotate(id: "grant", owner: f.owner, now: f.clock.read().wall)
    case .policy: try await f.engine.changePolicy(approvalRequired: true, owner: f.owner)
    case .leaseExpiry: f.clock.advance(3_601); await f.engine.continuePending()
    }
    await f.boundary.signingLatch.open()
    try await waitBoundary { f.boundary.preflightCount == 1 }
    await f.engine.continuePending()
    let retained = try #require(try SQLiteJournal(path: f.databasePath).read()?.payments.first)
    #expect(retained.disposition == .closed || retained.disposition == .invalidated)
    #expect(retained.terminalReason != nil)
    #expect(retained.attempts.isEmpty)
    #expect(retained.ordinaryAdmissions == 0)
    #expect(try f.state().requests.first?.key == f.request().requestKey)
    #expect(try f.state().gates.isEmpty)
    #expect(f.boundary.sentPayments.isEmpty)
}

@Test func competingDistinctKeysHaveOneDurableGateBeforeSuspendedSelection() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.boundary.preparationLatch.close()
    let first = try await f.engine.prepare(f.request(), session: f.session, connectionID: "connection", peer: f.peer)
    await #expect(throws: PaymentFailure.accountRestricted) {
        try await f.engine.prepare(f.request(String(repeating: "c", count: 32)), session: f.session,
            connectionID: "connection", peer: f.peer)
    }
    #expect(try SQLiteJournal(path: f.databasePath).read()?.payments.count == 1)
    #expect(try f.state().gates.first?.liabilityIDs == [first.payment.id])
    #expect(f.boundary.preparationCount == 0)
    _ = try await f.engine.cancel(operationID: first.payment.id, session: f.session, connectionID: "connection", peer: f.peer)
    await f.boundary.preparationLatch.open()
}

private final class PaymentCommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var observed = 0
    let point: SQLiteJournalFaultPoint
    init(_ point: SQLiteJournalFaultPoint) { self.point = point }
    var count: Int { lock.withLock { observed } }
    func arm() { lock.withLock { armed = true } }
    func hit(_ actual: SQLiteJournalFaultPoint) throws {
        let fail = lock.withLock { () -> Bool in
            guard armed, actual == point else { return false }
            armed = false; observed += 1; return true
        }
        if fail { throw ContinuityStoreError.failed }
    }
}
@Test(arguments: [SQLiteJournalFaultPoint.beforeCommit, .afterCommit])
func acceptedReplySQLiteCommitFaultNeverBecomesNotSent(point: SQLiteJournalFaultPoint) async throws {
    let fault = PaymentCommitFault(point)
    let f = try paymentFixture(journalFault: { try fault.hit($0) })
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.boundary.setOutcome(.accepted(source: "remote fixture"))
    await f.boundary.resultLatch.close()
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await waitBoundary { f.boundary.sentPayments.count == 1 }
    let admitted = try #require(f.state().payments.first)
    fault.arm()
    await f.boundary.resultLatch.open()
    try await waitBoundary { fault.count == 1 }
    // Await coordinator completion without peeking into an uncommitted SQLite transaction.
    if point == .afterCommit { try await f.wait(id, disposition: .accepted) }
    else { try await waitBoundary { f.continuity.status() == .quarantined } }
    let disk = try #require(try SQLiteJournal(path: f.databasePath).read()?.payments.first)
    #expect(disk.canonicalBytes == admitted.canonicalBytes)
    #expect(disk.transactionDigest == admitted.transactionDigest)
    #expect(disk.ordinaryAdmissions == 1)
    #expect(disk.liabilityUnresolved)
    #expect(try f.state().gates.contains { $0.liabilityIDs.contains(id) })
    #expect(f.boundary.sentPayments.count == 1)
    if point == .afterCommit {
        #expect(disk.disposition == .accepted)
        #expect(f.continuity.status() != .quarantined)
    } else {
        #expect(disk.disposition == .submitting)
        #expect(f.continuity.status() == .quarantined)
        #expect(try f.anchor.read()?.pending?.classification == "payment.result")
        let repaired = try f.continuity.recover(ownerAuthorized: true, recoveryID: "accepted-result-fault")
        #expect(repaired.mode == .restricted)
        #expect(repaired.payments.first?.canonicalBytes == admitted.canonicalBytes)
        #expect(repaired.payments.first?.liabilityUnresolved == true)
        #expect(repaired.payments.first?.terminalReason != "failedUnsubmitted")
    }
}

enum PaymentAdmissionFault: String, Sendable, CaseIterable { case stage, beforeCommit, afterCommit, promotion }
@Test(arguments: PaymentAdmissionFault.allCases)
func durableAdmissionBarrierPrecedesEveryExternalHandoff(faultPoint: PaymentAdmissionFault) async throws {
    let commitFault = PaymentCommitFault(faultPoint == .afterCommit ? .afterCommit : .beforeCommit)
    let f = try paymentFixture(journalFault: { actual in
        if [.beforeCommit, .afterCommit].contains(faultPoint) { try commitFault.hit(actual) }
    })
    defer { try? FileManager.default.removeItem(at: f.directory) }
    await f.boundary.signingLatch.close()
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await waitBoundary { f.boundary.signingCount == 1 }
    if [.beforeCommit, .afterCommit].contains(faultPoint) { commitFault.arm() }
    else {
        f.anchor.setBeforeWrite { value in
            if faultPoint == .stage, value.pending?.classification == "payment.admit" {
                throw ContinuityStoreError.failed
            }
            if faultPoint == .promotion, value.pending == nil,
               try f.anchor.read()?.pending?.classification == "payment.admit" {
                throw ContinuityStoreError.failed
            }
        }
    }
    await f.boundary.signingLatch.open()
    if faultPoint == .afterCommit {
        try await f.wait(id, disposition: .uncertain)
        // The raw SQL phase can precede its result-anchor promotion. Join the command
        // pipeline before comparing the two independently persisted stores.
        try f.continuity.inspect { (completed: CanonicalState) throws -> Void in
            #expect(f.boundary.sentPayments.count == 1)
            #expect(try f.anchor.read()?.pending == nil)
            #expect(try f.anchor.read()?.committed == completed.reference())
            #expect(completed.payments.first?.ordinaryAdmissions == 1)
        }
    } else {
        try await waitBoundary { f.continuity.status() == .quarantined }
        #expect(f.boundary.sentPayments.isEmpty)
        let disk = try #require(try SQLiteJournal(path: f.databasePath).read()?.payments.first)
        if faultPoint == .promotion {
            #expect(disk.disposition == .submitting)
            #expect(disk.ordinaryAdmissions == 1)
            #expect(!disk.canonicalBytes.isEmpty)
            #expect(try f.anchor.read()?.pending?.classification == "payment.admit")
        } else {
            #expect(disk.disposition == .ready)
            #expect(disk.ordinaryAdmissions == 0)
        }
        #expect(try f.state().gates.contains { $0.liabilityIDs.contains(id) })
    }
}

// Serialize process-exit fixtures: each case owns exactly one child lifecycle.
@Suite(.serialized)
struct PaymentEngineCrashTests {
    @Test(arguments: [PaymentDisposition.preparing, .prepared, .pendingApproval, .ready])
    func childRestartInvalidatesEveryUnsubmittedStateAndPreservesKey(state: PaymentDisposition) async throws {
        let f = try paymentFixture(approvalRequired: state == .pendingApproval)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let databasePath = f.databasePath; let anchorPath = f.anchor.path
        await #expect(processExitsWith: .signal(SIGKILL)) {
            [databasePath = databasePath as String, anchorPath = anchorPath as String, state] in
            let child = try reopenPaymentFixture(databasePath: databasePath, anchorPath: anchorPath)
            if state == .preparing { await child.boundary.preparationLatch.close() }
            if state == .ready { await child.boundary.signingLatch.close() }
            let created = try await child.engine.prepare(child.request(), session: child.session,
                connectionID: "connection", peer: child.peer)
            if state != .preparing { try await child.wait(created.payment.id, disposition: .prepared) }
            if [.pendingApproval, .ready].contains(state) {
                _ = try await child.engine.submit(operationID: created.payment.id, session: child.session,
                    connectionID: "connection", peer: child.peer)
            }
            try await child.wait(created.payment.id, disposition: state)
            try child.continuity.inspect { #expect($0.payments.first?.disposition == state) }
            terminatePaymentChild()
        }
        let original = try #require(f.state().payments.first)
        #expect(original.disposition == state)
        let restarted = try reopenPaymentFixture(databasePath: databasePath, anchorPath: anchorPath)
        let invalidated = try #require(restarted.state().payments.first)
        #expect(invalidated.disposition == .invalidated)
        #expect(invalidated.terminalReason == "invalidated")
        #expect(try restarted.state().gates.isEmpty)
        let replay = try await restarted.engine.prepare(restarted.request(), session: restarted.session,
            connectionID: "connection", peer: restarted.peer)
        #expect(replay.payment.id == original.id)
        #expect(replay.payment.disposition == .invalidated)
        #expect(restarted.boundary.preparationCount == 0)
        #expect(restarted.boundary.signingCount == 0)
        #expect(restarted.boundary.sentPayments.isEmpty)
    }

    @Test(arguments: PaymentCrashPrefix.allCases)
    func childDeathAcrossRelayAndAcceptancePrefixesRetainsTruth(prefix: PaymentCrashPrefix) async throws {
        let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let databasePath = f.databasePath; let anchorPath = f.anchor.path
        await #expect(processExitsWith: .signal(SIGKILL)) {
            [databasePath = databasePath as String, anchorPath = anchorPath as String, prefix] in
            let child = try reopenPaymentFixture(databasePath: databasePath, anchorPath: anchorPath)
            if prefix == .cleanAdmission { await child.boundary.handoffLatch.close() }
            if prefix == .transport { await child.boundary.resultLatch.close() }
            if [.acceptedBeforePersistence, .acceptedBeforeCleanup].contains(prefix) {
                child.boundary.setOutcome(.accepted(source: "remote fixture"))
            }
            if prefix == .acceptedBeforePersistence {
                child.anchor.setBeforeWrite { value in
                    if value.pending?.classification == "payment.result" { terminatePaymentChild() }
                }
            }
            let id = try await child.prepare()
            _ = try await child.engine.submit(operationID: id, session: child.session, connectionID: "connection", peer: child.peer)
            if prefix == .acceptedBeforePersistence {
                try await Task.sleep(for: .seconds(5))
                Issue.record("Expected death at accepted-result staging")
            } else {
                if prefix == .acceptedBeforeCleanup { try await child.wait(id, disposition: .accepted) }
                else { try await child.wait(id, disposition: .submitting) }
                if prefix == .transport { try await waitBoundary { child.boundary.sentPayments.count == 1 } }
                try child.continuity.inspect { state in
                    #expect(state.payments.first?.ordinaryAdmissions == 1)
                    #expect(!state.payments[0].canonicalBytes.isEmpty)
                }
                terminatePaymentChild()
            }
        }
        let admitted = try #require(f.state().payments.first)
        #expect(admitted.disposition == (prefix == .acceptedBeforeCleanup ? .accepted : .submitting))
        let restarted = try reopenPaymentFixture(databasePath: databasePath, anchorPath: anchorPath)
        let recovered = try #require(restarted.state().payments.first)
        #expect(recovered.disposition == (prefix == .acceptedBeforeCleanup ? .accepted : .uncertain))
        #expect(recovered.canonicalBytes == admitted.canonicalBytes)
        #expect(recovered.transactionDigest == admitted.transactionDigest)
        #expect(recovered.ordinaryAdmissions == 1)
        #expect(try restarted.state().gates.contains { $0.liabilityIDs.contains(recovered.id) })
        let replay = try await restarted.engine.prepare(restarted.request(), session: restarted.session,
            connectionID: "connection", peer: restarted.peer)
        #expect(replay.payment.id == admitted.id)
        #expect(restarted.boundary.preparationCount == 0)
        #expect(restarted.boundary.signingCount == 0)
        #expect(restarted.boundary.sentPayments.isEmpty)
    }
}

private func terminatePaymentChild() -> Never {
    precondition(kill(getpid(), SIGKILL) == 0)
    // The exit-test runner must never win a normal-return race with signal delivery.
    while true { _ = Darwin.pause() }
}

@Test func rotationWithRemainingOrdinaryAllowanceRequiresOwnerExactRelay() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let service = try ServiceAuthority(continuity: f.continuity, policy: f.policy)
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await f.wait(id, disposition: .uncertain)
    let admitted = try #require(f.state().payments.first)
    let originalRequest = try #require(f.state().requests.first { $0.method == "prepare_payment" })
    #expect(admitted.ordinaryAdmissions == 1 && admitted.attempts.count == 1)
    #expect(!admitted.canonicalBytes.isEmpty && admitted.liabilityUnresolved)
    let preflights = f.boundary.preflightCount
    let rotated = try service.rotate(id: "grant", owner: f.owner, now: f.clock.read().wall)
    #expect(throws: AuthorizationFailure.invalidCredential) {
        try service.authenticate(connectionID: "old-reconnect", peer: f.peer, credential: f.credential, now: f.clock.read().wall)
    }
    await #expect(throws: AuthorizationFailure.staleSession) {
        try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    }
    let current = try service.authenticate(connectionID: "rotated-connection", peer: f.peer,
        credential: rotated.rawValue, now: f.clock.read().wall)
    f.clock.advance(1_000) // Beyond the first retry delay; two ordinary admissions remain unused.
    let submitted = try await f.engine.submit(operationID: id, session: current,
        connectionID: "rotated-connection", peer: f.peer)
    #expect(submitted.payment.id == id && submitted.payment.ordinaryAdmissions == 1)
    await f.engine.continuePending()
    try await waitBoundary { (try? f.state().payments.first?.blocker) == "staleContext" }
    let retained = try #require(f.state().payments.first)
    #expect(retained.disposition == .uncertain && retained.liabilityUnresolved)
    #expect(retained.ordinaryAdmissions == 1 && retained.attempts == admitted.attempts)
    #expect(retained.canonicalBytes == admitted.canonicalBytes && retained.transactionDigest == admitted.transactionDigest)
    #expect(retained.preview == admitted.preview && retained.request == admitted.request)
    #expect(try SQLiteJournal(path: f.databasePath).read()?.requests.first { $0.method == "prepare_payment" } == originalRequest)
    #expect(try f.state().gates.contains { $0.liabilityIDs.contains(id) })
    #expect(f.boundary.preflightCount == preflights && f.boundary.sentPayments.count == 1)
    let lookup = try await f.engine.lookup(requestKey: f.request().requestKey, session: current,
        connectionID: "rotated-connection", peer: f.peer)
    #expect(lookup.payment.id == id && lookup.payment.disposition == .uncertain)
    #expect(lookup.payment.canonicalBytes == admitted.canonicalBytes && lookup.payment.ordinaryAdmissions == 1)
    #expect(lookup.blocker == "staleContext" && lookup.accountRestricted)

    let command = try f.ownerCommand(id)
    _ = try await f.engine.authorizeRelay(command, owner: f.owner)
    try await waitAttemptCount(f, count: 2)
    let ownerResult = try await f.engine.authorizeRelay(command, owner: f.owner)
    #expect(ownerResult.ownerReceipt?.consumedAttemptID != nil)
    #expect(ownerResult.payment.ordinaryAdmissions == 1)
    #expect(ownerResult.payment.attempts.map(\.route) == ["ordinary", "owner"])
    #expect(ownerResult.payment.canonicalBytes == admitted.canonicalBytes && ownerResult.payment.liabilityUnresolved)
    #expect(f.boundary.sentPayments.map(\.bytes) == [admitted.canonicalBytes, admitted.canonicalBytes])
    #expect(try f.state().gates.contains { $0.liabilityIDs.contains(id) })
}

private func paymentWaitForSignal(_ signal: DispatchSemaphore,
                                  timeout: DispatchTimeInterval = .seconds(5)) async -> Bool {
    await withCheckedContinuation { continuation in
        Thread {
            continuation.resume(returning: signal.wait(timeout: .now() + timeout) == .success)
        }.start()
    }
}

private final class PaymentHeldPromotion: @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var held = false
    func pauseOnce() throws {
        guard lock.withLock({ if held { return false }; held = true; return true }) else { return }
        reached.signal()
        guard release.wait(timeout: .now() + 5) == .success else { throw ContinuityStoreError.failed }
    }
}

private final class PaymentTrustedReadProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<CanonicalState, any Error>?
    func start(_ continuity: ContinuityCoordinator) {
        Thread {
            self.started.signal()
            let result = Result { try continuity.inspect { $0 } }
            self.lock.withLock { self.result = result }
            self.completed.signal()
        }.start()
    }
    func outcome() -> Result<CanonicalState, any Error>? { lock.withLock { result } }
}

enum PaymentPromotionPhase: CaseIterable, Sendable {
    case admission, result
    var classification: String { self == .admission ? "payment.admit" : "payment.result" }
    var disposition: PaymentDisposition { self == .admission ? .submitting : .uncertain }
}

@Test(arguments: PaymentPromotionPhase.allCases)
func ambiguousCommittedPromotionBlocksTrustedReadsAndHandoff(phase: PaymentPromotionPhase) async throws {
    let fault = PaymentCommitFault(.afterCommit)
    let f = try paymentFixture(journalFault: { try fault.hit($0) })
    let promotion = PaymentHeldPromotion()
    defer {
        promotion.release.signal()
        f.anchor.setBeforeWrite { _ in }
        try? FileManager.default.removeItem(at: f.directory)
    }
    await f.boundary.signingLatch.close()
    await f.boundary.resultLatch.close()
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    try await waitBoundary { f.boundary.signingCount == 1 }
    f.anchor.setBeforeWrite { proposed in
        if proposed.pending == nil, try f.anchor.read()?.pending?.classification == phase.classification {
            try promotion.pauseOnce()
        }
    }
    if phase == .admission { fault.arm() }
    await f.boundary.signingLatch.open()
    if phase == .result {
        try await waitBoundary { f.boundary.sentPayments.count == 1 }
        // The transport result is still held, so this observes the clean admission.
        try f.continuity.inspect { (admitted: CanonicalState) throws -> Void in
            #expect(admitted.payments.first?.disposition == .submitting)
            #expect(try f.anchor.read()?.pending == nil)
            #expect(try f.anchor.read()?.committed == admitted.reference())
        }
        fault.arm()
        await f.boundary.resultLatch.open()
    }
    let reachedPromotion = await paymentWaitForSignal(promotion.reached)
    try #require(reachedPromotion)
    #expect(fault.count == 1) // An actual committed write threw before coordinator read-back.

    // Intentional raw observation of a known held fault prefix, not a trusted completion.
    let raw = try #require(try SQLiteJournal(path: f.databasePath).read())
    #expect(raw.payments.first?.disposition == phase.disposition)
    #expect(raw.payments.first?.ordinaryAdmissions == 1 && raw.payments.first?.attempts.count == 1)
    #expect(try f.anchor.read()?.pending?.classification == phase.classification)
    #expect(f.boundary.sentPayments.count == (phase == .admission ? 0 : 1))

    let publicRead = PaymentTrustedReadProbe()
    publicRead.start(f.continuity)
    let readStarted = await paymentWaitForSignal(publicRead.started)
    try #require(readStarted)
    let crossedHeldPromotion = await paymentWaitForSignal(publicRead.completed, timeout: .milliseconds(100))
    #expect(!crossedHeldPromotion)
    #expect(f.boundary.sentPayments.count == (phase == .admission ? 0 : 1))
    promotion.release.signal()
    if !crossedHeldPromotion { #expect(await paymentWaitForSignal(publicRead.completed)) }
    let observed = try #require(publicRead.outcome()).get()
    #expect(observed.payments.first?.disposition == phase.disposition)
    #expect(observed.payments.first?.canonicalBytes == raw.payments.first?.canonicalBytes)
    try f.continuity.inspect { (completed: CanonicalState) throws -> Void in
        #expect(try f.anchor.read()?.pending == nil)
        #expect(try f.anchor.read()?.committed == completed.reference())
        #expect(completed.payments.first?.ordinaryAdmissions == 1 && completed.payments.first?.attempts.count == 1)
    }
    try await waitBoundary { f.boundary.sentPayments.count == 1 }
    if phase == .admission { await f.boundary.resultLatch.open() }
    try await f.wait(id, disposition: .uncertain)
    try f.continuity.inspect { (completed: CanonicalState) throws -> Void in
        #expect(try f.anchor.read()?.pending == nil)
        #expect(try f.anchor.read()?.committed == completed.reference())
        #expect(completed.payments.first?.ordinaryAdmissions == 1 && completed.payments.first?.attempts.count == 1)
        #expect(f.boundary.sentPayments.count == 1)
    }
}

@Test func cancellationReturnsUnderCancelScopeWithoutRead() async throws {
    let f = try paymentFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    try f.continuity.transaction { state in
        state.authorization.grants[0].capabilities = ["prepare", "cancel"]
    }
    let id = try await f.prepare()
    let result = try await f.engine.cancel(operationID: id, session: f.session,
        connectionID: "connection", peer: f.peer)
    #expect(result.payment.terminalReason == "cancelled")
    await #expect(throws: PaymentFailure.unavailable) {
        try await f.engine.get(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    }
    #expect(f.boundary.sentPayments.isEmpty)
}

@Test func exactPreviewDigestIsComparedInsideApprovalAndRejectionTransactions() async throws {
    let f = try paymentFixture(approvalRequired: true)
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let id = try await f.prepare()
    _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
    let review = try await f.engine.ownerStatus(operationID: id, owner: f.owner)
    #expect(review.previewContextDigest.count == 32)
    await #expect(throws: PaymentFailure.staleContext) {
        try await f.engine.reject(operationID: id, owner: f.owner,
            expectedPreviewContextDigest: Data(repeating: 0xAB, count: 32))
    }
    #expect(try f.state().payments.first?.disposition == .pendingApproval)
    try await f.engine.changePolicy(approvalRequired: false, owner: f.owner)
    await #expect(throws: PaymentFailure.staleContext) {
        try await f.engine.approve(operationID: id, owner: f.owner,
            expectedPreviewContextDigest: review.previewContextDigest)
    }
    #expect(f.boundary.sentPayments.isEmpty)
}
