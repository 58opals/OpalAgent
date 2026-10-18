import CSQLite
import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

private enum OperationTestFailure: Error { case deadline, fixture }
private func operationEventually(_ description: String, _ predicate: () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("\(description)")
    throw OperationTestFailure.deadline
}

private final class OperationClock: PaymentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Int64 = 100
    func advance(to wall: Int64) { lock.withLock { self.wall = wall } }
    func read() -> PaymentClockReading { lock.withLock { .init(wall: wall, monotonic: UInt64(wall)) } }
}

/// Holds only injected public observations. Every mutation under test uses the real engine and SQLite journal.
private actor OperationChain: AccountChainBoundary {
    private var refreshCount = 0
    private var derivationCount = 0
    private var pending: [Int: (String, String, CheckedContinuation<AccountSyncRecord, any Error>)] = [:]
    private var addressPending: CheckedContinuation<String, Never>?
    private let holdAddress: Bool
    init(holdAddress: Bool = false) { self.holdAddress = holdAddress }
    func counts() -> (Int, Int) { (refreshCount, derivationCount) }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        refreshCount += 1
        let ticket = refreshCount
        return try await withCheckedThrowingContinuation { pending[ticket] = (accountID, network, $0) }
    }
    func release(_ ticket: Int, complete: Bool = true, fresh: Bool = true) {
        guard let value = pending.removeValue(forKey: ticket) else { preconditionFailure("Missing operation refresh") }
        value.2.resume(returning: AccountSyncRecord(accountID: value.0, network: value.1, providerID: "fixture-provider",
            viewID: "fixture-view-\(ticket)", chainTip: "fixture-tip", observedAt: 100, complete: complete, fresh: fresh,
            balance: complete ? 0 : nil, snapshot: Data("{}".utf8), receivingHorizon: -1, changeHorizon: -1))
    }
    func fail(_ ticket: Int) {
        guard let value = pending.removeValue(forKey: ticket) else { preconditionFailure("Missing operation refresh") }
        value.2.resume(throwing: PaymentFailure.networkUnavailable)
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        derivationCount += 1
        if holdAddress { return await withCheckedContinuation { addressPending = $0 } }
        return "disposable-operation-address-\(index)"
    }
    func releaseAddress() {
        guard let continuation = addressPending else { preconditionFailure("Missing operation derivation") }
        addressPending = nil
        continuation.resume(returning: "disposable-operation-address-0")
    }
}

private extension ReceiveFixture {
    func operationRequest(_ index: Int) -> AccountOperationRequest {
        let value = request(index)
        return .init(accountID: value.accountID, network: value.network, requestKey: value.requestKey)
    }
    func operationEngine(_ chain: any AccountChainBoundary, clock: any PaymentClock = ReceiveClock()) -> ReceiveEngine {
        ReceiveEngine(continuity: continuity, policy: policy, boundary: chain, clock: clock)
    }
}

@Test func keyedSynchronizationRetainsOneEffectAndCompletedReplyAcrossSQLiteReopen() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let chain = OperationChain()
    let engine = fixture.operationEngine(chain)
    let request = fixture.operationRequest(101)
    let first = try await engine.synchronize(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    #expect(first.state == .pending && first.effect == .synchronize)
    try await operationEventually("First keyed sync must start one refresh") { await chain.counts().0 == 1 }
    let reconnected = try fixture.authority.authenticate(connectionID: "reconnected", peer: fixture.peer,
        credential: fixture.credential, now: 100)
    let duplicate = try await engine.synchronize(request, session: reconnected, connectionID: "reconnected", peer: fixture.peer)
    #expect(duplicate.operationID == first.operationID)
    let reference = try fixture.continuity.inspect { try $0.reference() }
    for _ in 0..<3 {
        let byID = try await engine.get(id: first.operationID, accountID: "account", network: "mainnet",
            session: reconnected, connectionID: "reconnected", peer: fixture.peer)
        let byKey = try await engine.lookup(request: request, effect: .synchronize, session: reconnected,
            connectionID: "reconnected", peer: fixture.peer)
        #expect(byID.state == .pending && byKey == byID)
    }
    #expect(try fixture.continuity.inspect { try $0.reference() } == reference)
    #expect(await chain.counts() == (1, 0))
    await chain.release(1)
    try await operationEventually("Keyed synchronization must retain its completed observation") {
        try await engine.get(id: first.operationID, accountID: "account", network: "mainnet", session: reconnected,
            connectionID: "reconnected", peer: fixture.peer).state == .completed
    }
    let completed = try await engine.get(id: first.operationID, accountID: "account", network: "mainnet",
        session: reconnected, connectionID: "reconnected", peer: fixture.peer)
    #expect(completed.observation?.fresh == true && completed.observation?.generation == 1)
    let journal = try SQLiteJournal(path: fixture.folder.appendingPathComponent("journal.sqlite").path)
    let continuity = ContinuityCoordinator(database: journal, anchor: fixture.anchor)
    let authority = try ServiceAuthority(continuity: continuity, policy: fixture.policy)
    let session = try authority.authenticate(connectionID: "restart", peer: fixture.peer, credential: fixture.credential, now: 100)
    let restarted = ReceiveEngine(continuity: continuity, policy: fixture.policy, boundary: chain, clock: ReceiveClock())
    let replay = try await restarted.synchronize(request, session: session, connectionID: "restart", peer: fixture.peer)
    #expect(replay == completed)
    #expect(try await restarted.lookup(request: request, effect: .synchronize, session: session,
        connectionID: "restart", peer: fixture.peer) == completed)
    let state = try continuity.inspect { $0 }
    #expect(state.requests.count == 1 && state.requests.first?.principalID == "receive-integration")
    #expect(state.requests.first?.originGrantID == "receive-grant" && state.allocations.isEmpty)
    #expect(await chain.counts() == (1, 0))
}

@Test func pendingReceiveCoalescesLostReplyAndPollsWithoutAllocatingTwice() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let chain = OperationChain()
    let engine = fixture.operationEngine(chain)
    let request = fixture.request(102)
    let first = try await engine.createOperation(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    try await operationEventually("Receive must start its retained work") { await chain.counts().0 == 1 }
    let duplicate = try await engine.createOperation(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    #expect(duplicate.operationID == first.operationID && duplicate.state == .pending)
    let reference = try fixture.continuity.inspect { try $0.reference() }
    let pending = try await engine.get(id: first.operationID, accountID: "account", network: "mainnet",
        session: fixture.session, connectionID: "connection", peer: fixture.peer)
    #expect(pending.state == .pending && pending.allocation == nil)
    #expect(try fixture.continuity.inspect { try $0.reference() } == reference)
    let awaited = Task { try await engine.create(request, session: fixture.session, connectionID: "connection", peer: fixture.peer) }
    await chain.release(1)
    let allocation = try await awaited.value
    #expect(allocation.operationID == first.operationID && allocation.index == 0)
    let retained = try await engine.createOperation(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    #expect(retained.state == .allocated && retained.allocation == allocation)
    #expect(try await engine.lookup(request: fixture.operationRequest(102), effect: .receive, session: fixture.session,
        connectionID: "connection", peer: fixture.peer) == retained)
    #expect(await chain.counts() == (1, 1))
    let state = try fixture.continuity.inspect { $0 }
    #expect(state.allocations.first?.issuedIndices == [0] && state.allocations.first?.issuedHighWater == 0)
    #expect(state.requests.count == 1)
}

@Test func cancelReceiveNeedsOnlyCancelScopeAndLateDerivationCannotIssue() async throws {
    let fixture = try ReceiveFixture.make(capabilities: ["receive", "cancel"])
    defer { fixture.remove() }
    let chain = OperationChain(holdAddress: true)
    let engine = fixture.operationEngine(chain)
    let request = fixture.request(103)
    let pending = try await engine.createOperation(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    let awaited = Task { try await engine.create(request, session: fixture.session, connectionID: "connection", peer: fixture.peer) }
    try await operationEventually("Receive refresh must become ready") { await chain.counts().0 == 1 }
    await chain.release(1)
    try await operationEventually("Receive must stop at injected derivation boundary") { await chain.counts().1 == 1 }
    let closed = try await engine.cancel(id: pending.operationID, accountID: "account", network: "mainnet",
        session: fixture.session, connectionID: "connection", peer: fixture.peer)
    #expect(closed.state == .closed && closed.closeReason == .cancelled && closed.allocation == nil)
    await #expect(throws: AuthorizationFailure.scopeDenied) {
        try await engine.get(id: pending.operationID, accountID: "account", network: "mainnet",
            session: fixture.session, connectionID: "connection", peer: fixture.peer)
    }
    await chain.releaseAddress()
    await #expect(throws: PaymentFailure.invalidTransition) { try await awaited.value }
    let replay = try await engine.createOperation(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    #expect(replay == closed)
    #expect(try fixture.continuity.inspect { $0.allocations.isEmpty })
    #expect(await chain.counts() == (1, 1))
}

@Test func failedSynchronizationClosesTruthfullyAndReplayDoesNotRetry() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let chain = OperationChain()
    let engine = fixture.operationEngine(chain)
    let request = fixture.operationRequest(104)
    let pending = try await engine.synchronize(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    try await operationEventually("Sync must reach injected failure") { await chain.counts().0 == 1 }
    await chain.fail(1)
    try await operationEventually("Failed sync must close") {
        try await engine.get(id: pending.operationID, accountID: "account", network: "mainnet", session: fixture.session,
            connectionID: "connection", peer: fixture.peer).state == .closed
    }
    let closed = try await engine.synchronize(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    #expect(closed.closeReason == .failed && closed.blocker == .networkUnavailable && closed.observation == nil)
    #expect(try await engine.cached(accountID: "account", network: "mainnet", session: fixture.session,
        connectionID: "connection", peer: fixture.peer)?.fresh == false)
    #expect(await chain.counts() == (1, 0))
}

@Test(arguments: [AccountOperationEffect.receive, .synchronize])
func pendingAccountOperationIsInvalidatedBySQLiteRestart(effect: AccountOperationEffect) async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let chain = OperationChain()
    let engine = fixture.operationEngine(chain)
    let request = fixture.operationRequest(105)
    let pending: AccountOperationSnapshot
    if effect == .receive {
        pending = try await engine.createOperation(fixture.request(105), session: fixture.session, connectionID: "connection", peer: fixture.peer)
    } else {
        pending = try await engine.synchronize(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    }
    try await operationEventually("Pending operation must reach its refresh before restart") { await chain.counts().0 == 1 }
    let journal = try SQLiteJournal(path: fixture.folder.appendingPathComponent("journal.sqlite").path)
    let continuity = ContinuityCoordinator(database: journal, anchor: fixture.anchor)
    let authority = try ServiceAuthority(continuity: continuity, policy: fixture.policy)
    let session = try authority.authenticate(connectionID: "restart", peer: fixture.peer, credential: fixture.credential, now: 100)
    let restarted = ReceiveEngine(continuity: continuity, policy: fixture.policy, boundary: chain, clock: ReceiveClock())
    let invalidated = try await restarted.get(id: pending.operationID, accountID: "account", network: "mainnet",
        session: session, connectionID: "restart", peer: fixture.peer)
    #expect(invalidated.state == .closed && invalidated.closeReason == .invalidated)
    #expect(invalidated.allocation == nil && invalidated.observation == nil)
    #expect(try await restarted.lookup(request: request, effect: effect, session: session,
        connectionID: "restart", peer: fixture.peer) == invalidated)
    let reference = try continuity.inspect { try $0.reference() }
    if effect == .receive {
        #expect(try await restarted.createOperation(fixture.request(105), session: session,
            connectionID: "restart", peer: fixture.peer) == invalidated)
    } else {
        #expect(try await restarted.synchronize(request, session: session, connectionID: "restart", peer: fixture.peer) == invalidated)
    }
    #expect(try continuity.inspect { try $0.reference() } == reference)
    #expect(try continuity.inspect { $0.allocations.isEmpty && $0.publicSnapshots.first?.fresh == false })
    #expect(await chain.counts() == (1, 0))
    await chain.release(1)
}

@Test func rotatedPendingReceiveRemainsClosedForFreshCredentialAndOldCredentialFails() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let chain = OperationChain()
    let engine = fixture.operationEngine(chain)
    let request = fixture.request(106)
    let pending = try await engine.createOperation(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    let awaited = Task { try await engine.create(request, session: fixture.session, connectionID: "connection", peer: fixture.peer) }
    try await operationEventually("Pending receive must reach refresh before rotation") { await chain.counts().0 == 1 }
    let issued = try fixture.authority.rotate(id: "receive-grant", owner: fixture.owner, now: 100)
    let session = try fixture.authority.authenticate(connectionID: "rotated", peer: fixture.peer, credential: issued.rawValue, now: 100)
    #expect(throws: AuthorizationFailure.invalidCredential) {
        try fixture.authority.authenticate(connectionID: "old", peer: fixture.peer, credential: fixture.credential, now: 100)
    }
    let closed = try await engine.get(id: pending.operationID, accountID: "account", network: "mainnet",
        session: session, connectionID: "rotated", peer: fixture.peer)
    #expect(closed.state == .closed && closed.closeReason == .authorizationInvalidated)
    #expect(try await engine.createOperation(request, session: session, connectionID: "rotated", peer: fixture.peer) == closed)
    await chain.release(1)
    await #expect(throws: (any Error).self) { try await awaited.value }
    #expect(try fixture.continuity.inspect { $0.allocations.isEmpty && $0.publicSnapshots.first?.fresh == false })
    #expect(await chain.counts() == (1, 0))
}

@Test func revocationDuringReceiveRefreshPreventsAllocationAndForeignReenrollmentDisclosure() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let chain = OperationChain()
    let engine = fixture.operationEngine(chain)
    let request = fixture.request(107)
    let pending = try await engine.createOperation(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    let awaited = Task { try await engine.create(request, session: fixture.session, connectionID: "connection", peer: fixture.peer) }
    try await operationEventually("Pending receive must reach refresh before revocation") { await chain.counts().0 == 1 }
    try fixture.authority.revoke(id: "receive-grant", owner: fixture.owner, now: 100)
    await chain.release(1)
    await #expect(throws: AuthorizationFailure.revoked) { try await awaited.value }
    let replacement = try fixture.authority.enroll(id: "replacement", integrationID: "receive-integration", accounts: ["account"],
        capabilities: ["read", "receive"], expiry: nil, owner: fixture.owner, now: 100)
    let session = try fixture.authority.authenticate(connectionID: "replacement", peer: fixture.peer, credential: replacement.rawValue, now: 100)
    await #expect(throws: PaymentFailure.unavailable) {
        try await engine.get(id: pending.operationID, accountID: "account", network: "mainnet", session: session,
            connectionID: "replacement", peer: fixture.peer)
    }
    await #expect(throws: PaymentFailure.unavailable) {
        try await engine.lookup(request: fixture.operationRequest(107), effect: .receive, session: session,
            connectionID: "replacement", peer: fixture.peer)
    }
    #expect(try fixture.continuity.inspect { $0.allocations.isEmpty && $0.publicSnapshots.first?.fresh == false })
    #expect(await chain.counts() == (1, 0))
}

@Test func readTimeExpiryMaintenanceInvalidatesPendingWithoutStartingEffects() async throws {
    let clock = OperationClock()
    let fixture = try ReceiveFixture.make(expiry: 110, clock: clock)
    defer { fixture.remove() }
    let chain = OperationChain()
    let engine = fixture.operationEngine(chain, clock: clock)
    let request = fixture.request(108)
    let pending = try await engine.createOperation(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    let awaited = Task { try await engine.create(request, session: fixture.session, connectionID: "connection", peer: fixture.peer) }
    try await operationEventually("Pending receive must reach refresh before expiry") { await chain.counts().0 == 1 }
    clock.advance(to: 111)
    await #expect(throws: AuthorizationFailure.expired) {
        try await engine.get(id: pending.operationID, accountID: "account", network: "mainnet", session: fixture.session,
            connectionID: "connection", peer: fixture.peer)
    }
    let state = try fixture.continuity.inspect { $0 }
    #expect(state.authorization.grants.first?.expiredObserved == true)
    #expect(state.requests.first?.disposition == .invalidated && state.allocations.isEmpty)
    #expect(await chain.counts() == (1, 0))
    await chain.release(1)
    await #expect(throws: AuthorizationFailure.expired) { try await awaited.value }
    #expect(try fixture.continuity.inspect { $0.allocations.isEmpty })
}

@Test func receiveAndSyncCommandRepliesDoNotRequireReadScope() async throws {
    let receive = try ReceiveFixture.make(capabilities: ["receive"])
    defer { receive.remove() }
    let allocation = try await receive.create(109)
    #expect(allocation.index == 0)
    await #expect(throws: AuthorizationFailure.scopeDenied) {
        try await receive.engine.cached(accountID: "account", network: "mainnet", session: receive.session,
            connectionID: "connection", peer: receive.peer)
    }
    let sync = try ReceiveFixture.make(capabilities: ["sync"])
    defer { sync.remove() }
    let request = sync.operationRequest(110)
    let first = try await sync.engine.synchronize(request, session: sync.session, connectionID: "connection", peer: sync.peer)
    try await operationEventually("Sync-only grant must receive a completed command response") {
        try await sync.engine.synchronize(request, session: sync.session, connectionID: "connection", peer: sync.peer).state == .completed
    }
    #expect(first.state == .pending)
    #expect(await sync.chain.counts().0 == 1)
    await #expect(throws: AuthorizationFailure.scopeDenied) {
        try await sync.engine.get(id: first.operationID, accountID: "account", network: "mainnet", session: sync.session,
            connectionID: "connection", peer: sync.peer)
    }
}

@Test(arguments: [["read"], ["prepare"], ["submit"], ["cancel"]])
func unrelatedCapabilitiesCannotStartReceiveOrSync(capabilities: [String]) async throws {
    let fixture = try ReceiveFixture.make(capabilities: capabilities)
    defer { fixture.remove() }
    await #expect(throws: AuthorizationFailure.scopeDenied) { try await fixture.create(111) }
    await #expect(throws: AuthorizationFailure.scopeDenied) {
        try await fixture.engine.synchronize(fixture.operationRequest(111), session: fixture.session,
            connectionID: "connection", peer: fixture.peer)
    }
    #expect(try fixture.continuity.inspect { $0.requests.isEmpty && $0.allocations.isEmpty && $0.publicSnapshots.isEmpty })
    #expect(await fixture.chain.counts() == (0, 0))
    if capabilities == ["read"] {
        #expect(try await fixture.engine.cached(accountID: "account", network: "mainnet", session: fixture.session,
            connectionID: "connection", peer: fixture.peer) == nil)
    }
}


@Test(arguments: [AccountOperationEffect.receive, .synchronize])
func restoredUnknownAccountOperationVersionCannotReachStartupOrEffects(effect: AccountOperationEffect) async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let request = fixture.operationRequest(112)
    var state = try fixture.continuity.inspect { $0 }
    var record = RequestRecord(id: "future-account-operation", principalID: "receive-integration",
        method: effect.method, key: request.requestKey, binding: try paymentEncoding(request), disposition: .unsubmitted,
        result: try paymentEncoding(AccountOperationResult(generation: 1, credentialGeneration: 1)),
        consumedAttemptID: nil, tombstone: false, formatVersion: 2, ownerGeneration: 1, originGrantID: "receive-grant")
    state.requests.append(record)
    #expect(try accountOperationSnapshot(record, in: state).state == .pending)
    try fixture.journal.write(state)
    try fixture.anchor.write(.init(committed: state.reference()))

    // Emulate a newer writer's restored row. Its inner payload is fully valid for this
    // implementation, and its independent anchor commits the exact complete future bytes.
    // Raw fixture preparation deliberately bypasses the current writer's version validator.
    record.formatVersion = 3
    state.requests[0] = record
    let payload = try paymentEncoding(record)
    do {
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(fixture.folder.appendingPathComponent("journal.sqlite").path,
            &connection, SQLITE_OPEN_READWRITE, nil)
        guard opened == SQLITE_OK, let connection else { throw OperationTestFailure.fixture }
        defer { sqlite3_close_v2(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "UPDATE requests SET payload = ? WHERE id = 'future-account-operation'",
            -1, &statement, nil) == SQLITE_OK, let statement else { throw OperationTestFailure.fixture }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(connection) == 1 else { throw OperationTestFailure.fixture }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let futureReference = StateReference(installationID: state.installationID, walletID: state.authorization.walletID,
        network: state.authorization.network, generation: state.authorization.generation, commitID: state.commitID,
        formatVersion: state.formatVersion, commitment: Data(SHA256.hash(data: try encoder.encode(state.canonicalized()))),
        history: state.history)
    try fixture.anchor.write(.init(committed: futureReference))
    let path = fixture.folder.appendingPathComponent("journal.sqlite")
    let databaseBytes = try Data(contentsOf: path)
    let anchorBytes = try Data(contentsOf: fixture.anchor.path)
    #expect(throws: ContinuityError.incompatibleSchema) { try accountOperationSnapshot(record, in: state) }
    let journal = try SQLiteJournal(path: path.path)
    #expect(throws: ContinuityError.incompatibleSchema) { try journal.read() }
    let continuity = ContinuityCoordinator(database: journal, anchor: fixture.anchor)
    let engine = ReceiveEngine(continuity: continuity, policy: fixture.policy, boundary: fixture.chain, clock: ReceiveClock())
    await #expect(throws: ContinuityError.recoveryRequired) {
        try await engine.get(id: record.id, accountID: "account", network: "mainnet", session: fixture.session,
            connectionID: "connection", peer: fixture.peer)
    }
    let startup = ContinuityCoordinator(database: journal, anchor: fixture.anchor)
    #expect(throws: ContinuityError.recoveryRequired) { try startup.startup() }
    if effect == .receive {
        await #expect(throws: ContinuityError.recoveryRequired) {
            try await engine.createOperation(fixture.request(112), session: fixture.session,
                connectionID: "connection", peer: fixture.peer)
        }
    } else {
        await #expect(throws: ContinuityError.recoveryRequired) {
            try await engine.synchronize(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
        }
    }
    #expect(await fixture.chain.counts() == (0, 0))
    #expect(try Data(contentsOf: path) == databaseBytes)
    #expect(try Data(contentsOf: fixture.anchor.path) == anchorBytes)
}

@Test func legacyFormatOneReceiveAllocationRetainsReplyAcrossSQLiteRestart() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let request = fixture.request(113)
    let allocation = ReceiveAllocation(operationID: "legacy-receive-operation", accountID: request.accountID,
        network: request.network, index: 0, address: "disposable-legacy-address")
    var state = try fixture.continuity.inspect { $0 }
    state.requests.append(RequestRecord(id: allocation.operationID, principalID: "receive-integration",
        method: "create_receive_request", key: request.requestKey, binding: try paymentEncoding(request), disposition: .closed,
        result: try paymentEncoding(allocation), consumedAttemptID: nil, tombstone: false,
        originGrantID: "receive-grant"))
    state.allocations.append(AllocationRecord(accountID: "account", branch: "receiving", issuedIndices: [0],
        issuedHighWater: 0, confirmedHistoryHorizon: nil, issuanceEvidence: Data("legacy-evidence".utf8)))
    let reference = try state.reference()
    try fixture.journal.write(state)
    try fixture.anchor.write(.init(committed: reference))
    let journal = try SQLiteJournal(path: fixture.folder.appendingPathComponent("journal.sqlite").path)
    let continuity = ContinuityCoordinator(database: journal, anchor: fixture.anchor)
    let authority = try ServiceAuthority(continuity: continuity, policy: fixture.policy)
    let session = try authority.authenticate(connectionID: "legacy-restart", peer: fixture.peer,
        credential: fixture.credential, now: 100)
    let engine = ReceiveEngine(continuity: continuity, policy: fixture.policy, boundary: fixture.chain, clock: ReceiveClock())
    #expect(try await engine.create(request, session: session, connectionID: "legacy-restart", peer: fixture.peer) == allocation)
    let retained = try await engine.get(id: allocation.operationID, accountID: "account", network: "mainnet",
        session: session, connectionID: "legacy-restart", peer: fixture.peer)
    #expect(retained.state == .allocated && retained.allocation == allocation)
    #expect(try journal.read()?.requests.first?.formatVersion == 1)
    #expect(try continuity.inspect { try $0.reference() } == reference)
    #expect(await fixture.chain.counts() == (0, 0))
}
