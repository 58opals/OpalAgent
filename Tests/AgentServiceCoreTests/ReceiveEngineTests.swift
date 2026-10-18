import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

private final class ReceiveAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    let path: URL
    let fault: ReceiveWriteFault?
    init(path: URL, fault: ReceiveWriteFault? = nil) { self.path = path; self.fault = fault }
    func read() throws -> ContinuityAnchor? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return try JSONDecoder().decode(ContinuityAnchor.self, from: Data(contentsOf: path))
        }
    }
    func write(_ anchor: ContinuityAnchor) throws {
        try lock.withLock {
            let existing = FileManager.default.fileExists(atPath: path.path)
                ? try JSONDecoder().decode(ContinuityAnchor.self, from: Data(contentsOf: path)) : nil
            if fault == .stageBefore && anchor.pending?.classification == "receive.allocate" { throw ReceiveInjectedFailure.stop }
            if fault == .promotionBefore && existing?.pending?.classification == "receive.allocate" && anchor.pending == nil && anchor.recovery == nil {
                throw ReceiveInjectedFailure.stop
            }
            try JSONEncoder().encode(anchor).write(to: path, options: .atomic)
        }
    }
}
private struct ReceiveClock: PaymentClock {
    func read() -> PaymentClockReading { .init(wall: 100, monotonic: 100) }
}
private actor ReceiveChain: AccountChainBoundary {
    var receiving: Int64 = -1
    var change: Int64 = -1
    var refreshes = 0
    var derivations = 0
    var complete = true
    var fresh = true
    func horizon(_ value: Int64) { receiving = value }
    func horizons(receiving: Int64, change: Int64) { self.receiving = receiving; self.change = change }
    func availability(complete: Bool, fresh: Bool) { self.complete = complete; self.fresh = fresh }
    func counts() -> (Int, Int) { (refreshes, derivations) }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        refreshes += 1
        return AccountSyncRecord(accountID: accountID, network: network, providerID: "disposable-provider",
            viewID: "view", chainTip: "tip", observedAt: 100, complete: complete, fresh: fresh,
            balance: complete ? 0 : nil, snapshot: Data("{}".utf8), receivingHorizon: receiving, changeHorizon: change)
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        derivations += 1
        return "synthetic-address-\(network)-\(index)"
    }
}
private struct ReceiveFixture {
    let folder: URL
    let journal: SQLiteJournal
    let anchor: ReceiveAnchor
    let continuity: ContinuityCoordinator
    let authority: ServiceAuthority
    let policy: AuthorityPolicy
    let peer: PeerEvidence
    let owner: OwnerAuthenticationEvidence
    let credential: Data
    let session: AuthorizationSession
    let chain: ReceiveChain
    let engine: ReceiveEngine

    static func make(fault: ReceiveWriteFault? = nil, withCustody: Bool = true) throws -> Self {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let anchor = ReceiveAnchor(path: folder.appendingPathComponent("independent-anchor.json"), fault: fault)
        let journal = try SQLiteJournal(path: folder.appendingPathComponent("journal.sqlite").path) { point in
            if fault == .databaseBefore && point == .beforeCommit,
               try anchor.read()?.pending?.classification == "receive.allocate" { throw ReceiveInjectedFailure.stop }
        }
        var state = CanonicalState(installationID: "receive-installation",
            authorization: .init(walletID: "receive-wallet", network: "mainnet", generation: 1, grants: []),
            mode: .enabled, history: .complete)
        let protected = try PayloadProtector(profile: .encrypted, walletID: "receive-wallet",
            wrappingKey: .available(SymmetricKey(data: Data(repeating: 3, count: 32)))).protect(Data("disposable".utf8))
        if withCustody {
            state.custody = WalletCustodyRecord(walletID: "receive-wallet", network: "mainnet", accountID: "account",
                encryptedMnemonic: protected, publicDescriptor: Data("test-boundary-descriptor".utf8))
        }
        try journal.write(state); try anchor.write(.init(committed: state.reference()))
        let continuity = ContinuityCoordinator(database: journal, anchor: anchor)
        let identity = SignedPeerIdentity(teamIdentifier: "disposable-team", signingIdentifier: "owner")
        let bridge = SignedPeerIdentity(teamIdentifier: "disposable-team", signingIdentifier: "bridge")
        let policy = AuthorityPolicy(bridge: bridge, owner: identity, accountIDs: ["account"],
            capabilities: ["read", "sync", "receive"], ownerAuthenticationAge: 30)
        let peer = PeerEvidence(identity: bridge, signatureValidated: true)
        let owner = OwnerAuthenticationEvidence(peer: .init(identity: identity, signatureValidated: true),
            authenticationSucceeded: true, authenticatedAt: 100)
        let authority = try ServiceAuthority(continuity: continuity, policy: policy)
        let issued = try authority.enroll(id: "receive-grant", integrationID: "receive-integration",
            accounts: ["account"], capabilities: ["read", "sync", "receive"], expiry: nil, owner: owner, now: 100)
        let session = try authority.authenticate(connectionID: "connection", peer: peer, credential: issued.rawValue, now: 100)
        let chain = ReceiveChain()
        let engine = ReceiveEngine(continuity: continuity, policy: policy, boundary: chain, clock: ReceiveClock())
        return Self(folder: folder, journal: journal, anchor: anchor, continuity: continuity,
            authority: authority, policy: policy, peer: peer, owner: owner, credential: issued.rawValue,
            session: session, chain: chain, engine: engine)
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
    func request(_ index: Int) -> ReceiveRequest {
        let suffix = String(index, radix: 16)
        return ReceiveRequest(accountID: "account", network: "mainnet",
                              requestKey: String(repeating: "0", count: 32 - suffix.count) + suffix)
    }
    func create(_ index: Int) async throws -> ReceiveAllocation {
        try await engine.create(request(index), session: session, connectionID: "connection", peer: peer)
    }
}

@Test func receiveWindowRetainsRequestsAndBlocksTheTwentyFirstAllocation() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    var results: [ReceiveAllocation] = []
    for index in 0..<20 { results.append(try await fixture.create(index)) }
    #expect(results.map(\.index) == Array(0..<20).map(UInt32.init))
    #expect(Set(results.map(\.address)).count == 20)
    await #expect(throws: PaymentFailure.accountRestricted) { try await fixture.create(20) }
    let replay = try await fixture.create(19)
    #expect(replay == results[19])
    await fixture.chain.horizon(19)
    let expanded = try await fixture.create(20)
    #expect(expanded.index == 20)
    let state = try #require(try fixture.journal.read())
    #expect(state.allocations.first?.issuedHighWater == 20)
    #expect(state.allocations.first?.confirmedHistoryHorizon == 19)
}

@Test func receiveReplayAndCachedReadsRemainObservationalAcrossRestart() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let first = try await fixture.create(1)
    let reference = try #require(try fixture.journal.read()).reference()
    let counts = await fixture.chain.counts()
    _ = try await fixture.engine.cached(accountID: "account", network: "mainnet", session: fixture.session,
                                       connectionID: "connection", peer: fixture.peer)
    #expect(try await fixture.create(1) == first)
    #expect(try #require(try fixture.journal.read()).reference() == reference)
    let after = await fixture.chain.counts()
    #expect(after.0 == counts.0 && after.1 == counts.1)
    let reopened = try SQLiteJournal(path: fixture.folder.appendingPathComponent("journal.sqlite").path)
    let coordinator = ContinuityCoordinator(database: reopened, anchor: fixture.anchor)
    let authority = try ServiceAuthority(continuity: coordinator, policy: fixture.policy)
    let session = try authority.authenticate(connectionID: "reconnected", peer: fixture.peer, credential: fixture.credential, now: 100)
    let engine = ReceiveEngine(continuity: coordinator, policy: fixture.policy, boundary: fixture.chain, clock: ReceiveClock())
    #expect(try await engine.create(fixture.request(1), session: session, connectionID: "reconnected", peer: fixture.peer) == first)
    #expect(try #require(try reopened.read()).allocations.first?.issuedHighWater == 0)
    let cached = try await engine.cached(accountID: "account", network: "mainnet", session: session,
        connectionID: "reconnected", peer: fixture.peer)
    #expect(cached?.fresh == true && cached?.generation == 1)
    #expect(try reopened.read()?.reference() == reference)
}

@Test func receiveRevocationRejectsRetainedResultDisclosureAndForgedPeers() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    _ = try await fixture.create(1)
    let wrong = PeerEvidence(identity: .init(teamIdentifier: "other", signingIdentifier: "bridge"), signatureValidated: true)
    await #expect(throws: (any Error).self) {
        try await fixture.engine.create(fixture.request(1), session: fixture.session, connectionID: "connection", peer: wrong)
    }
    try fixture.authority.revoke(id: "receive-grant", owner: fixture.owner, now: 100)
    await #expect(throws: (any Error).self) { try await fixture.create(1) }
    #expect(try #require(try fixture.journal.read()).allocations.first?.issuedHighWater == 0)
}

@Test func receiveIncompleteEvidenceCannotAllocateAndRecoveryKeepsHighWater() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    await fixture.chain.availability(complete: false, fresh: true)
    await #expect(throws: PaymentFailure.networkUnavailable) { try await fixture.create(1) }
    #expect(try #require(try fixture.journal.read()).allocations.isEmpty)
    await fixture.chain.availability(complete: true, fresh: true)
    _ = try await fixture.create(1)
    let reset = try fixture.continuity.recover(ownerAuthorized: true)
    #expect(reset.mode == .restricted)
    #expect(reset.allocations.first?.issuedHighWater == 0)
    await #expect(throws: PaymentFailure.recoveryRequired) { try await fixture.create(2) }
}


@Test(arguments: [Int64(-2), Int64(0x8000_0000), Int64.max])
private func receiveRejectsOutOfRangeConfirmedFrontiers(_ horizon: Int64) async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    await fixture.chain.horizons(receiving: horizon, change: -1)
    await #expect(throws: PaymentFailure.staleContext) { try await fixture.create(1) }
    #expect(try fixture.journal.read()?.allocations.isEmpty == true)
    await fixture.chain.horizons(receiving: -1, change: horizon)
    await #expect(throws: PaymentFailure.staleContext) { try await fixture.create(1) }
    #expect(try fixture.journal.read()?.allocations.isEmpty == true)
}

@Test(arguments: [UInt64(0x7fff_ffff), UInt64.max])
private func receiveHighWaterCannotOverflowOrEnterTheHardenedRange(_ high: UInt64) async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    try fixture.continuity.transaction { state in
        state.allocations.append(AllocationRecord(accountID: "account", branch: "receiving", issuedIndices: [high],
            issuedHighWater: high, confirmedHistoryHorizon: nil, issuanceEvidence: Data()))
    }
    await fixture.chain.horizon(0x7fff_ffff)
    await #expect(throws: PaymentFailure.accountRestricted) { try await fixture.create(1) }
    #expect(try fixture.journal.read()?.allocations.first?.issuedHighWater == high)
    #expect(await fixture.chain.counts().1 == 0)
}

@Test func receiveRequiresTheCustodyAccountEvenWhenAGrantNamesAnotherAccount() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    try fixture.continuity.transaction { state in state.authorization.grants[0].accountIDs.append("foreign-account") }
    let request = ReceiveRequest(accountID: "foreign-account", network: "mainnet", requestKey: fixture.request(1).requestKey)
    await #expect(throws: PaymentFailure.unavailable) {
        try await fixture.engine.create(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    }
    #expect(try fixture.journal.read()?.requests.isEmpty == true)
    #expect(await fixture.chain.counts().0 == 0)
}

@Test func receiveWithoutCustodyCannotUseAnOtherwiseValidGrant() async throws {
    let fixture = try ReceiveFixture.make(withCustody: false)
    defer { fixture.remove() }
    await #expect(throws: PaymentFailure.unavailable) { try await fixture.create(1) }
    #expect(try fixture.journal.read()?.requests.isEmpty == true)
    #expect(await fixture.chain.counts().0 == 0)
}

@Test func receiveOutOfOrderRefreshCannotReplaceANewerPublicSnapshot() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let boundary = ControlledReceiveChain()
    let engine = ReceiveEngine(continuity: fixture.continuity, policy: fixture.policy, boundary: boundary, clock: ReceiveClock())
    let first = Task { try await engine.synchronize(accountID: "account", network: "mainnet", session: fixture.session,
        connectionID: "connection", peer: fixture.peer) }
    await boundary.waitForCount(1)
    let second = Task { try await engine.synchronize(accountID: "account", network: "mainnet", session: fixture.session,
        connectionID: "connection", peer: fixture.peer) }
    await boundary.waitForCount(2)
    await boundary.release(2, horizon: 19)
    #expect(try await second.value.receivingHorizon == 19)
    await boundary.release(1, horizon: 0)
    await #expect(throws: PaymentFailure.staleContext) { try await first.value }
    #expect(try fixture.journal.read()?.publicSnapshots.first?.receivingHorizon == 19)
    #expect(try fixture.journal.read()?.publicSnapshots.first?.viewID == "view-2")
}

@Test func receiveConcurrentIdenticalKeysRetainOneAllocation() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let boundary = ControlledReceiveChain()
    let engine = ReceiveEngine(continuity: fixture.continuity, policy: fixture.policy, boundary: boundary, clock: ReceiveClock())
    let request = fixture.request(1)
    let first = Task { try await engine.create(request, session: fixture.session, connectionID: "connection", peer: fixture.peer) }
    await boundary.waitForCount(1)
    let second = Task { try await engine.create(request, session: fixture.session, connectionID: "connection", peer: fixture.peer) }
    await boundary.waitForCount(2)
    await boundary.release(2, horizon: -1)
    let allocation = try await second.value
    await boundary.release(1, horizon: -1)
    await #expect(throws: PaymentFailure.staleContext) { try await first.value }
    let replay = try await engine.create(request, session: fixture.session, connectionID: "connection", peer: fixture.peer)
    #expect(replay == allocation)
    #expect(try fixture.journal.read()?.requests.count == 1)
    #expect(try fixture.journal.read()?.allocations.first?.issuedIndices == [0])
    #expect(await boundary.derivationCount == 1)
}

@Test func receiveRevocationDuringRefreshPreventsResultDisclosureAndAllocation() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let boundary = ControlledReceiveChain()
    let engine = ReceiveEngine(continuity: fixture.continuity, policy: fixture.policy, boundary: boundary, clock: ReceiveClock())
    let pending = Task { try await engine.create(fixture.request(1), session: fixture.session, connectionID: "connection", peer: fixture.peer) }
    await boundary.waitForCount(1)
    try fixture.authority.revoke(id: "receive-grant", owner: fixture.owner, now: 100)
    await boundary.release(1, horizon: 19)
    await #expect(throws: AuthorizationFailure.revoked) { try await pending.value }
    #expect(try fixture.journal.read()?.allocations.isEmpty == true)
    #expect(try fixture.journal.read()?.publicSnapshots.first?.fresh == false)
    #expect(await boundary.derivationCount == 0)
}

@Test func receiveOwnerDiscoveryInRestrictedIncompleteStateCannotIssueAuthorityOrAddresses() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    _ = try await fixture.create(1)
    var source = try #require(try fixture.journal.read())
    source.commitID = "unproven-source"
    try fixture.journal.write(source) // Actual mismatched storage, not an unqualified replacement of located facts.
    let reset = try fixture.continuity.recover(ownerAuthorized: true)
    #expect(reset.mode == .restricted && reset.history == .incomplete)
    let anchorBefore = try fixture.anchor.read()
    let control = OwnerWalletControl(continuity: fixture.continuity, policy: fixture.policy)
    await fixture.chain.horizon(19)
    let discovered = try await control.discover(accountID: "account", network: "mainnet", boundary: fixture.chain,
        owner: fixture.owner, now: 100)
    #expect(discovered.receivingHorizon == 19)
    let after = try #require(try fixture.journal.read())
    #expect(after.mode == .restricted && after.history == .incomplete)
    #expect(after.authorization == reset.authorization && after.allocations == reset.allocations)
    #expect(after.requests == reset.requests && after.gates == reset.gates && after.approvals == reset.approvals)
    #expect(try fixture.anchor.read()?.originalProofs == anchorBefore?.originalProofs)
    await #expect(throws: PaymentFailure.recoveryRequired) { try await fixture.create(2) }
    let forged = OwnerAuthenticationEvidence(peer: fixture.peer, authenticationSucceeded: true, authenticatedAt: 100)
    let beforeForgery = try after.reference()
    await #expect(throws: AuthorizationFailure.untrustedPeer) {
        try await control.discover(accountID: "account", network: "mainnet", boundary: fixture.chain, owner: forged, now: 100)
    }
    #expect(try fixture.journal.read()?.reference() == beforeForgery)
}

@Test(arguments: ReceiveWriteFault.allCases)
private func receiveAllocationInterruptionPreservesAnUnrelatedLiabilityAndRecoversRestricted(_ fault: ReceiveWriteFault) async throws {
    let fixture = try ReceiveFixture.make(fault: fault)
    defer { fixture.remove() }
    try fixture.continuity.transaction { state in
        state.payments.append(PaymentRecord(id: "possible", accountID: "account", network: "mainnet", originGrantID: "receive-grant",
            canonicalBytes: Data([1, 2, 3]), transactionDigest: Data([4]), selectedInputs: ["input"], change: Data([5]),
            disposition: .possiblyRelayed, liabilityUnresolved: true, attempts: [], evidence: [], closures: []))
        state.gates.append(SpendingGate(accountID: "account", liabilityIDs: ["possible"], restrictions: ["uncertain"]))
    }
    let original = try #require(try fixture.journal.read())
    await #expect(throws: ContinuityError.recoveryRequired) { try await fixture.create(1) }
    #expect(fixture.continuity.status() == .quarantined)
    let stored = try #require(try fixture.journal.read())
    #expect(stored.payments == original.payments && stored.gates == original.gates)
    #expect(stored.allocations.first?.issuedHighWater == (fault == .promotionBefore ? 0 : nil))
    let reset = try fixture.continuity.recover(ownerAuthorized: true, recoveryID: "receive-reset")
    #expect(reset.mode == .restricted && reset.history == .complete)
    #expect(reset.authorization.grants.allSatisfy { $0.revoked })
    #expect(reset.payments == original.payments && reset.gates == original.gates)
    #expect(reset.allocations == stored.allocations)
    if fault == .promotionBefore {
        let retained = try #require(reset.requests.first { $0.method == "create_receive_request" })
        #expect(try JSONDecoder().decode(ReceiveAllocation.self, from: retained.result).index == 0)
    }
    #expect(try fixture.anchor.read()?.pending == nil && fixture.anchor.read()?.recovery == nil)
}

private enum ReceiveWriteFault: CaseIterable, Sendable { case stageBefore, databaseBefore, promotionBefore }
private enum ReceiveInjectedFailure: Error { case stop }

private actor ControlledReceiveChain: AccountChainBoundary {
    private var count = 0
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    private var pending: [Int: (String, String, CheckedContinuation<AccountSyncRecord, Never>)] = [:]
    private(set) var derivationCount = 0
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        count += 1
        let ticket = count
        for waiter in waiting where waiter.0 <= count { waiter.1.resume() }
        waiting.removeAll { $0.0 <= count }
        return await withCheckedContinuation { pending[ticket] = (accountID, network, $0) }
    }
    func waitForCount(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiting.append((target, $0)) }
    }
    func release(_ ticket: Int, horizon: Int64) {
        guard let value = pending.removeValue(forKey: ticket) else { preconditionFailure("Missing refresh fixture") }
        value.2.resume(returning: AccountSyncRecord(accountID: value.0, network: value.1, providerID: "fixture",
            viewID: "view-\(ticket)", chainTip: "tip", observedAt: 100, complete: true, fresh: true,
            balance: 0, snapshot: Data(), receivingHorizon: horizon, changeHorizon: -1))
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        derivationCount += 1
        return "synthetic-address-\(index)"
    }
}


@Test func receiveReenrollmentWithTheSameIntegrationLabelCannotDiscloseOldRequests() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    let original = try await fixture.create(1)
    try fixture.authority.revoke(id: "receive-grant", owner: fixture.owner, now: 100)
    let replacement = try fixture.authority.enroll(id: "replacement-grant", integrationID: "receive-integration",
        accounts: ["account"], capabilities: ["read", "sync", "receive"], expiry: nil, owner: fixture.owner, now: 100)
    let session = try fixture.authority.authenticate(connectionID: "replacement", peer: fixture.peer,
        credential: replacement.rawValue, now: 100)
    let before = try #require(try fixture.journal.read()).reference()
    let counts = await fixture.chain.counts()
    await #expect(throws: PaymentFailure.unavailable) {
        try await fixture.engine.create(fixture.request(1), session: session, connectionID: "replacement", peer: fixture.peer)
    }
    #expect(try fixture.journal.read()?.reference() == before)
    let afterCounts = await fixture.chain.counts()
    #expect(afterCounts.0 == counts.0 && afterCounts.1 == counts.1)
    let fresh = try await fixture.engine.create(fixture.request(2), session: session, connectionID: "replacement", peer: fixture.peer)
    #expect(fresh.index == original.index + 1 && fresh.operationID != original.operationID)
    let records = try #require(try fixture.journal.read()).requests
    #expect(records.first { $0.id == original.operationID }?.originGrantID == "receive-grant")
    #expect(records.first { $0.id == fresh.operationID }?.originGrantID == "replacement-grant")
}


@Test func receiveCachedSnapshotAfterRecoveryIsStaleUntilExplicitCurrentGenerationRefresh() async throws {
    let fixture = try ReceiveFixture.make()
    defer { fixture.remove() }
    _ = try await fixture.create(1)
    let controls = OwnerWalletControl(continuity: fixture.continuity, policy: fixture.policy)
    let reset = try controls.recover(owner: fixture.owner, now: 100)
    #expect(reset.publicSnapshots.first?.fresh == true && reset.publicSnapshots.first?.generation == 1)
    let vault = WalletSeedVault(keys: InjectedWrappingKeySource(read: {
        .available(SymmetricKey(data: Data(repeating: 3, count: 32)))
    }), accounts: ReceiveUnusedSeedProvider())
    _ = try controls.enable(vault: vault, owner: fixture.owner, now: 100)
    let credential = try fixture.authority.enroll(id: "post-recovery", integrationID: "post-recovery",
        accounts: ["account"], capabilities: ["read", "sync", "receive"], expiry: nil, owner: fixture.owner, now: 100)
    let session = try fixture.authority.authenticate(connectionID: "post-recovery", peer: fixture.peer,
        credential: credential.rawValue, now: 100)
    let before = try #require(try fixture.journal.read()).reference()
    let counts = await fixture.chain.counts()
    let cached = try await fixture.engine.cached(accountID: "account", network: "mainnet", session: session,
        connectionID: "post-recovery", peer: fixture.peer)
    #expect(cached?.fresh == false && cached?.generation == 1)
    #expect(try fixture.journal.read()?.reference() == before)
    let afterCounts = await fixture.chain.counts()
    #expect(afterCounts.0 == counts.0 && afterCounts.1 == counts.1)
    let refreshed = try await fixture.engine.synchronize(accountID: "account", network: "mainnet", session: session,
        connectionID: "post-recovery", peer: fixture.peer)
    #expect(refreshed.fresh && refreshed.generation == reset.authorization.generation)
    let current = try await fixture.engine.cached(accountID: "account", network: "mainnet", session: session,
        connectionID: "post-recovery", peer: fixture.peer)
    #expect(current == refreshed)
    #expect(try fixture.journal.read()?.allocations == reset.allocations)
}
private struct ReceiveUnusedSeedProvider: SeedAccountProvider {
    func generateMnemonic() throws -> Data { throw ContinuityError.invalidState }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount { throw ContinuityError.invalidState }
}
