import AgentClient
import AgentAppIntents
import AgentValues
import CryptoKit
import Foundation
import OpalBaseCore
import Testing
@testable import AgentServiceCore

private final class CapabilityAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuityAnchor?
    func read() throws -> ContinuityAnchor? { lock.withLock { value } }
    func write(_ anchor: ContinuityAnchor) throws { lock.withLock { value = anchor } }
}
private final class CapabilityClock: PaymentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Int64 = 1_000
    func read() -> PaymentClockReading { lock.withLock { .init(wall: wall, monotonic: 100) } }
    func set(_ value: Int64) { lock.withLock { wall = value } }
}
private actor CapabilityLatch {
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func close() { blocked = true }
    func wait() async { if blocked { await withCheckedContinuation { waiters.append($0) } } }
    func open() { blocked = false; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}
private final class CapabilityEffects: PaymentExecutionBoundary, AccountChainBoundary, @unchecked Sendable {
    let preparation = CapabilityLatch()
    let disposal = CapabilityLatch()
    let refreshGate = CapabilityLatch()
    private let lock = NSLock()
    private var counters = [0, 0, 0, 0, 0, 0]
    var counts: [Int] { lock.withLock { counters } }
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview {
        lock.withLock { counters[0] += 1 }
        await preparation.wait()
        return PaymentPreview(operationID: request.operationID, accountID: request.accountID, network: request.network,
            destinationScript: request.destinationScript, amount: request.amount, fee: 100,
            selectedInputs: [String(repeating: "a", count: 64) + ":1"], change: Data(),
            templateDigest: paymentDigest(try paymentEncoding(request)), leaseDeadline: 2_000)
    }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment {
        lock.withLock { counters[1] += 1 }
        let bytes = try paymentEncoding(preview)
        return SignedPayment(operationID: preview.operationID, bytes: bytes, digest: paymentDigest(bytes), transactionID: String(repeating: "b", count: 64))
    }
    func preflight(_ payment: SignedPayment) async throws {}
    func validateAdmission(_ payment: SignedPayment) throws {}
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        try admission {
            lock.withLock { counters[2] += 1 }
            return PaymentTransportInvocation(id: UUID().uuidString,
                result: { .unknown(source: "synthetic-relay") }, cancel: {})
        }
    }
    func dispose(operationID: String) async throws {
        lock.withLock { counters[3] += 1 }
        await disposal.wait()
    }
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation {
        PaymentObservation(source: "synthetic-provider", view: "view", chainTip: "tip", observedAt: 1_000, complete: true, fresh: true)
    }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        lock.withLock { counters[4] += 1 }
        await refreshGate.wait()
        return try capabilityRecord(accountID: accountID, network: network)
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        lock.withLock { counters[5] += 1 }
        return try OpalBase.Address(script: .p2sh(scriptHash: Data(repeating: UInt8(index + 1), count: 20)), network: .mainnet).string
    }
}
private func capabilityRecord(accountID: String = "account", network: String = "mainnet") throws -> AccountSyncRecord {
    var utxos: [OpalBase.Account.Snapshot.AddressBook.UTXO] = []
    for index in 1...3 {
        let character = ["a", "b", "c"][index - 1]
        let hash = String(repeating: character, count: 64)
        let utxo = OpalBase.Account.Snapshot.AddressBook.UTXO(value: UInt64(index * 1_000), lockingScript: "51",
            tokenCategory: nil, tokenAmount: nil, nftCapability: nil, nftCommitment: nil,
            transactionHash: hash, outputIndex: UInt32(index))
        utxos.append(utxo)
    }
    let transaction = OpalBase.Account.Snapshot.AddressBook.Transaction(transactionHash: String(repeating: "d", count: 64),
        height: 100, fee: 100, scriptHashes: [], firstSeenAt: Date(timeIntervalSince1970: 900),
        lastUpdatedAt: Date(timeIntervalSince1970: 1_000), status: .confirmed, confirmationHeight: 100,
        confirmedAt: Date(timeIntervalSince1970: 1_000), verificationStatus: .pending, merkleProof: nil,
        lastVerifiedHeight: nil, lastCheckedAt: nil)
    let snapshot = OpalBase.Account.Snapshot(purpose: .bip44, coinType: .bitcoinCash, accountUnhardenedIndex: 0,
        addressBook: .init(receivingEntries: [], changeEntries: [], utxos: utxos, transactions: [transaction]))
    return AccountSyncRecord(accountID: accountID, network: network, providerID: "synthetic-provider", viewID: "view",
        chainTip: "opaque-tip-hash", observedAt: 1_000, complete: true, fresh: true, balance: 6_000,
        snapshot: try paymentEncoding(snapshot), receivingHorizon: -1, changeHorizon: -1, sequence: 3, generation: 1)
}
private struct CapabilityEndpointTransport: CapabilityTransport {
    let service: CapabilityService
    let context: CapabilityConnectionContext
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        try await service.handle(request, context: context)
    }
}
private struct CapabilityFixture {
    let directory: URL
    let journal: SQLiteJournal
    let continuity: ContinuityCoordinator
    let authority: ServiceAuthority
    let policy: AuthorityPolicy
    let effects: CapabilityEffects
    let payments: PaymentEngine
    let receives: ReceiveEngine
    let service: CapabilityService
    let owner: OwnerAuthenticationEvidence
    let context: CapabilityConnectionContext
    let credential: Data
    let clock: CapabilityClock
    let account: AccountScope
    static func make(scopes: [IntegrationScope] = IntegrationScope.allCases, snapshot: Bool = false,
                     approvalRequired: Bool = true, integrationID: String = "integration-distinct",
                     peerProfile: IntegrationPeerProfile = .mcp) throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = try SQLiteJournal(path: directory.appendingPathComponent("state.sqlite").path)
        let anchor = CapabilityAnchor()
        let credential = Data(repeating: 0x34, count: 32)
        let bridge = SignedPeerIdentity(teamIdentifier: "synthetic-team", signingIdentifier: "bridge")
        let ownerIdentity = SignedPeerIdentity(teamIdentifier: "synthetic-team", signingIdentifier: "owner")
        let policy = AuthorityPolicy(bridge: bridge, owner: ownerIdentity, accountIDs: ["account"],
            capabilities: Set(IntegrationScope.allCases.map(\.rawValue)), ownerAuthenticationAge: 100,
            appleIntegration: peerProfile == .appleAutomation ? ownerIdentity : nil)
        let ledger = AuthorizationLedger(walletID: "wallet", network: "mainnet", generation: 1,
            grants: [GrantRecord(id: "grant-distinct", integrationID: integrationID, accountIDs: ["account"],
                capabilities: scopes.map(\.rawValue), credentialDigest: paymentDigest(credential), credentialGeneration: 1,
                expiresAt: nil, revoked: false, peerProfile: peerProfile)])
        var state = CanonicalState(installationID: "installation", authorization: ledger, mode: .enabled, history: .complete)
        let protected = try PayloadProtector(profile: .encrypted, walletID: "wallet",
            wrappingKey: .available(SymmetricKey(data: Data(repeating: 0x45, count: 32)))).protect(Data("disposable synthetic seed payload".utf8))
        state.custody = WalletCustodyRecord(walletID: "wallet", network: "mainnet", accountID: "account",
            encryptedMnemonic: protected, publicDescriptor: Data("synthetic-public-descriptor".utf8))
        state.paymentPolicy.approvalRequired = approvalRequired
        if snapshot { state.publicSnapshots = [try capabilityRecord()] }
        try journal.write(state); try anchor.write(.init(committed: state.reference()))
        let continuity = ContinuityCoordinator(database: journal, anchor: anchor)
        let authority = try ServiceAuthority(continuity: continuity, policy: policy)
        let peer = PeerEvidence(identity: peerProfile == .mcp ? bridge : ownerIdentity, signatureValidated: true)
        let owner = OwnerAuthenticationEvidence(peer: .init(identity: ownerIdentity, signatureValidated: true),
            authenticationSucceeded: true, authenticatedAt: 1_000)
        let session = try authority.authenticate(connectionID: "connection", peer: peer, credential: credential, now: 1_000)
        let effects = CapabilityEffects()
        let clock = CapabilityClock()
        let payments = PaymentEngine(continuity: continuity, authorityPolicy: policy, boundary: effects, clock: clock)
        let receives = ReceiveEngine(continuity: continuity, policy: policy, boundary: effects, clock: clock)
        let service = CapabilityService(continuity: continuity, policy: policy, payments: payments, receives: receives, clock: clock)
        return Self(directory: directory, journal: journal, continuity: continuity, authority: authority, policy: policy,
            effects: effects, payments: payments, receives: receives, service: service, owner: owner,
            context: .init(session: session, connectionID: "connection", peer: peer), credential: credential, clock: clock,
            account: try AccountScope(wallet: WalletScope(walletID: "wallet", network: .mainnet), accountID: "account"))
    }
    func close() { try? FileManager.default.removeItem(at: directory) }
    func key(_ byte: Character = "a") throws -> RequestKey { try RequestKey(String(repeating: String(byte), count: 32)) }
    func payment(_ byte: Character = "a", address: String = "1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu", amount: Int64 = 1_000) throws -> PreparePaymentRequest {
        try PreparePaymentRequest(account: account, requestKey: key(byte), destinationAddress: address, amountSatoshis: amount)
    }
    func call(_ call: CapabilityCall, context override: CapabilityConnectionContext? = nil) async throws -> CapabilityResult {
        let transport = CapabilityEndpointTransport(service: service, context: override ?? context)
        return try await CapabilityClient(transport: transport).call(call)
    }
    func waitPayment(_ id: String, _ disposition: PaymentDisposition = .prepared) async throws {
        try await capabilityEventually {
            try continuity.inspect { $0.payments.first(where: { $0.id == id })?.disposition == disposition }
        }
        _ = try await payments.get(operationID: id, session: context.session, connectionID: context.connectionID, peer: context.peer)
    }
    func waitAccount(_ id: String, _ state: AccountOperationState) async throws {
        try await capabilityEventually {
            try continuity.inspect { value in
                guard let row = value.requests.first(where: { $0.id == id }) else { return false }
                return try accountOperationSnapshot(row, in: value).state == state
            }
        }
    }
}
private func capabilityEventually(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Synthetic capability state did not finish within five seconds")
    throw PaymentFailure.invalidTransition
}

@Test func capabilityAllTwelveCallsUseActualEnginesAndTypedProjections() async throws {
    let f = try CapabilityFixture.make(snapshot: true); defer { f.close() }
    guard case .listWallets(let wallets) = try await f.call(.listWallets(PageRequest())) else { throw CapabilityFailure.invalidResponse }
    #expect(wallets.items.map(\.scope) == [f.account.wallet])
    guard case .listAccounts(let accounts) = try await f.call(.listAccounts(WalletPageRequest(wallet: f.account.wallet, page: PageRequest()))) else { throw CapabilityFailure.invalidResponse }
    #expect(accounts.page.items.map(\.scope) == [f.account])
    guard case .getBalance(let balance) = try await f.call(.getBalance(f.account)) else { throw CapabilityFailure.invalidResponse }
    #expect(balance.totalSatoshis == 6_000 && balance.observation.providerID == "synthetic-provider")
    #expect(balance.readiness.state == .unavailable)
    guard case .listTransactions(let history) = try await f.call(.listTransactions(AccountPageRequest(account: f.account, page: PageRequest()))) else { throw CapabilityFailure.invalidResponse }
    #expect(history.page.items.count == 1 && history.page.items[0].height == 100)
    #expect(history.page.items[0].deltaSatoshis == nil && history.page.items[0].confirmations == nil)
    guard case .listUTXOs(let coins) = try await f.call(.listUTXOs(AccountPageRequest(account: f.account, page: PageRequest()))) else { throw CapabilityFailure.invalidResponse }
    #expect(coins.page.items.count == 3 && coins.page.items.allSatisfy { $0.reservation == .unreserved })
    guard case .getSyncStatus(let syncStatus) = try await f.call(.getSyncStatus(f.account)) else { throw CapabilityFailure.invalidResponse }
    #expect(syncStatus.observation?.sequence == 3)
    #expect(f.effects.counts == [0, 0, 0, 0, 0, 0])

    let syncRequest = KeyedAccountRequest(account: f.account, requestKey: try f.key("b"))
    guard case .synchronizeAccount(let sync) = try await f.call(.synchronizeAccount(syncRequest)) else { throw CapabilityFailure.invalidResponse }
    try await f.waitAccount(sync.identity.selector.operationID, .completed)
    guard case .getOperation(.synchronization(let completed)) = try await f.call(.getOperation(.request(account: f.account, effect: .synchronizeAccount, key: f.key("b")))) else { throw CapabilityFailure.invalidResponse }
    #expect(completed.state == .completed && completed.observation?.providerID == "synthetic-provider")
    guard case .createReceiveRequest(let receive) = try await f.call(.createReceiveRequest(KeyedAccountRequest(account: f.account, requestKey: f.key("c")))) else { throw CapabilityFailure.invalidResponse }
    try await f.waitAccount(receive.identity.selector.operationID, .allocated)
    guard case .getOperation(.receive(let allocated)) = try await f.call(.getOperation(.operation(receive.identity.selector))) else { throw CapabilityFailure.invalidResponse }
    #expect(allocated.state == .allocated && allocated.allocation?.index == 0)
    guard case .preparePayment(let payment) = try await f.call(.preparePayment(f.payment())) else { throw CapabilityFailure.invalidResponse }
    try await f.waitPayment(payment.identity.selector.operationID)
    guard case .getOperation(.payment(let prepared)) = try await f.call(.getOperation(.request(account: f.account, effect: .preparePayment, key: f.key()))) else { throw CapabilityFailure.invalidResponse }
    #expect(prepared.preview?.selectedInputs == [Outpoint(transactionID: String(repeating: "a", count: 64), outputIndex: 1)])
    #expect(prepared.preview?.feeSatoshis == 100 && prepared.accountRestriction == .held)
    guard case .submitPayment(let pendingApproval) = try await f.call(.submitPayment(payment.identity.selector)) else { throw CapabilityFailure.invalidResponse }
    #expect(pendingApproval.state == .pendingApproval)
    guard case .cancelOperation(.payment(let cancelled)) = try await f.call(.cancelOperation(payment.identity.selector)) else { throw CapabilityFailure.invalidResponse }
    #expect(cancelled.state == .closed && cancelled.terminalReason == .cancelled)
    #expect(cancelled.closures.last?.support == .notApplicable)
    #expect(f.effects.counts[1] == 0 && f.effects.counts[2] == 0)
}

@Test func capabilityMissingSnapshotsAndPollingNeverCreateAccountEffects() async throws {
    let f = try CapabilityFixture.make(); defer { f.close() }
    let before = try f.continuity.inspect { try $0.reference() }
    for call in [CapabilityCall.getBalance(f.account), .listTransactions(try AccountPageRequest(account: f.account, page: PageRequest())),
                 .listUTXOs(try AccountPageRequest(account: f.account, page: PageRequest()))] {
        await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(call) }
    }
    guard case .getSyncStatus(let status) = try await f.call(.getSyncStatus(f.account)) else { throw CapabilityFailure.invalidResponse }
    #expect(status.observation == nil && status.readiness.state == .blocked)
    let unknown = try OperationSelector(account: f.account, operationID: "unknown")
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.getOperation(.operation(unknown))) }
    #expect(f.effects.counts == [0, 0, 0, 0, 0, 0])
    #expect(try f.continuity.inspect { try $0.reference() } == before)
}

@Test func capabilityAddressNormalizationReplaysAndChangedPayloadConflicts() async throws {
    let f = try CapabilityFixture.make(); defer { f.close() }
    guard case .preparePayment(let initial) = try await f.call(.preparePayment(f.payment())) else { throw CapabilityFailure.invalidResponse }
    try await f.waitPayment(initial.identity.selector.operationID)
    let spelling = "bitcoincash:" + initial.request.destinationAddress
    guard case .preparePayment(let replay) = try await f.call(.preparePayment(f.payment(address: spelling.uppercased()))) else { throw CapabilityFailure.invalidResponse }
    #expect(initial.identity == replay.identity && replay.request.destinationAddress == initial.request.destinationAddress)
    #expect(f.effects.counts[0] == 1)
    await #expect(throws: ServiceProblem(.conflictingRequest)) { try await f.call(.preparePayment(f.payment(amount: 1_001))) }
    await #expect(throws: ServiceProblem(.invalidRequest)) { try await f.call(.preparePayment(f.payment("b", address: "bchtest:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"))) }
    _ = try await f.call(.cancelOperation(initial.identity.selector))
}

@Test func capabilityScopesAreIndependentAndCancelDoesNotRequireRead() async throws {
    for scope in IntegrationScope.allCases {
        let f = try CapabilityFixture.make(); defer { f.close() }
        guard case .preparePayment(let initial) = try await f.call(.preparePayment(f.payment())) else { throw CapabilityFailure.invalidResponse }
        try await f.waitPayment(initial.identity.selector.operationID)
        try f.continuity.transaction { $0.authorization.grants[0].capabilities = [scope.rawValue] }
        let method: CapabilityCall
        switch scope {
        case .read: method = .getSyncStatus(f.account)
        case .sync: method = .synchronizeAccount(KeyedAccountRequest(account: f.account, requestKey: try f.key("b")))
        case .receive: method = .createReceiveRequest(KeyedAccountRequest(account: f.account, requestKey: try f.key("c")))
        case .prepare: method = .preparePayment(try f.payment())
        case .submit: method = .submitPayment(initial.identity.selector)
        case .cancel: method = .cancelOperation(initial.identity.selector)
        }
        _ = try await f.call(method)
        for (required, denied) in [(IntegrationScope.read, CapabilityCall.getSyncStatus(f.account)),
            (.sync, .synchronizeAccount(try KeyedAccountRequest(account: f.account, requestKey: f.key("d")))),
            (.receive, .createReceiveRequest(try KeyedAccountRequest(account: f.account, requestKey: f.key("e")))),
            (.prepare, .preparePayment(try f.payment("f"))), (.submit, .submitPayment(initial.identity.selector)),
            (.cancel, .cancelOperation(initial.identity.selector))] where required != scope {
            await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(denied) }
        }
        if scope == .sync || scope == .receive {
            try await capabilityEventually { f.effects.counts[4] == 1 }
            // Join effect completion before fixture teardown.
            try await capabilityEventually { try f.continuity.inspect { $0.requests.filter { $0.paymentID == nil }.allSatisfy { $0.disposition == .closed } } }
        }
        #expect(f.effects.counts[1] == 0 && f.effects.counts[2] == 0)
    }
}

@Test func capabilityRotationAndReusedLabelsCannotDiscloseOldOrigins() async throws {
    let f = try CapabilityFixture.make(); defer { f.close() }
    guard case .preparePayment(let initial) = try await f.call(.preparePayment(f.payment())) else { throw CapabilityFailure.invalidResponse }
    try await f.waitPayment(initial.identity.selector.operationID)
    let rotated = try f.authority.rotate(id: "grant-distinct", owner: f.owner, now: 1_000)
    let session = try f.authority.authenticate(connectionID: "rotated", peer: f.context.peer, credential: rotated.rawValue, now: 1_000)
    let rotatedContext = CapabilityConnectionContext(session: session, connectionID: "rotated", peer: f.context.peer)
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.getOperation(.operation(initial.identity.selector))) }
    guard case .getOperation(.payment(let retained)) = try await f.call(.getOperation(.operation(initial.identity.selector)), context: rotatedContext) else { throw CapabilityFailure.invalidResponse }
    #expect(retained.identity == initial.identity && retained.terminalReason == .authorizationInvalidated)
    try f.authority.revoke(id: "grant-distinct", owner: f.owner, now: 1_000)
    let replacement = try f.authority.enroll(id: "replacement-grant", integrationID: "integration-distinct", accounts: ["account"],
        capabilities: IntegrationScope.allCases.map(\.rawValue), expiry: nil, owner: f.owner, now: 1_000)
    let replacementSession = try f.authority.authenticate(connectionID: "replacement", peer: f.context.peer, credential: replacement.rawValue, now: 1_000)
    let replacementContext = CapabilityConnectionContext(session: replacementSession, connectionID: "replacement", peer: f.context.peer)
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.getOperation(.operation(initial.identity.selector)), context: replacementContext) }
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.preparePayment(f.payment(amount: 2_000)), context: replacementContext) }
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.getOperation(.request(account: f.account, effect: .preparePayment, key: f.key())), context: replacementContext) }
}

@Test(arguments: ["revoke", "rotate", "generation"])
func capabilityAuthorityChangesDuringAwaitPreventDisclosure(_ change: String) async throws {
    let f = try CapabilityFixture.make(); defer { f.close() }
    guard case .preparePayment(let initial) = try await f.call(.preparePayment(f.payment())) else { throw CapabilityFailure.invalidResponse }
    try await f.waitPayment(initial.identity.selector.operationID)
    await f.effects.disposal.close()
    let task = Task { try await f.call(.cancelOperation(initial.identity.selector)) }
    try await capabilityEventually { f.effects.counts[3] > 0 }
    if change == "revoke" { try f.authority.revoke(id: "grant-distinct", owner: f.owner, now: 1_000) }
    else if change == "rotate" { _ = try f.authority.rotate(id: "grant-distinct", owner: f.owner, now: 1_000) }
    else { _ = try f.continuity.recover(ownerAuthorized: true) }
    await f.effects.disposal.open()
    await #expect(throws: ServiceProblem(change == "generation" ? .recoveryRequired : .unavailable)) { try await task.value }
    #expect(f.effects.counts[1] == 0 && f.effects.counts[2] == 0)
}

@Test func capabilityPaginationAndReservationsKeepForeignOperationsPrivate() async throws {
    let f = try CapabilityFixture.make(snapshot: true); defer { f.close() }
    guard case .preparePayment(let initial) = try await f.call(.preparePayment(f.payment())) else { throw CapabilityFailure.invalidResponse }
    try await f.waitPayment(initial.identity.selector.operationID)
    let request = try AccountPageRequest(account: f.account, page: PageRequest(limit: 1))
    guard case .listUTXOs(let first) = try await f.call(.listUTXOs(request)) else { throw CapabilityFailure.invalidResponse }
    #expect(first.page.items[0].reservation == .visibleOperation(initial.identity.selector.operationID))
    let cursor = try #require(first.page.nextCursor)
    guard case .listUTXOs(let second) = try await f.call(.listUTXOs(AccountPageRequest(account: f.account, page: PageRequest(limit: 1, cursor: cursor)))) else { throw CapabilityFailure.invalidResponse }
    #expect(second.page.items[0].outpoint != first.page.items[0].outpoint && second.page.items[0].reservation == .unreserved)
    let issued = try f.authority.enroll(id: "foreign-grant", integrationID: "foreign-integration", accounts: ["account"], capabilities: ["read"], expiry: nil, owner: f.owner, now: 1_000)
    let session = try f.authority.authenticate(connectionID: "foreign", peer: f.context.peer, credential: issued.rawValue, now: 1_000)
    let context = CapabilityConnectionContext(session: session, connectionID: "foreign", peer: f.context.peer)
    guard case .listUTXOs(let foreign) = try await f.call(.listUTXOs(request), context: context) else { throw CapabilityFailure.invalidResponse }
    #expect(foreign.page.items[0].reservation == .otherOperation)
    await #expect(throws: ServiceProblem(.staleContext)) {
        try await f.call(.listUTXOs(AccountPageRequest(account: f.account, page: PageRequest(limit: 1, cursor: cursor))), context: context)
    }
    let encoded = String(decoding: try paymentEncoding(foreign), as: UTF8.self)
    #expect(!encoded.contains(initial.identity.selector.operationID))
    for operationID in [initial.identity.selector.operationID, "unknown"] {
        await #expect(throws: ServiceProblem(.unavailable)) {
            try await f.call(.getOperation(.operation(OperationSelector(account: f.account, operationID: operationID))), context: context)
        }
    }
    let before = f.effects.counts
    for _ in 0..<4 { _ = try await f.call(.getOperation(.operation(initial.identity.selector))) }
    #expect(f.effects.counts == before)
    _ = try await f.call(.cancelOperation(initial.identity.selector))
}

@Test func capabilityObservedExpiryCannotReviveAfterClockRollback() async throws {
    let f = try CapabilityFixture.make(); defer { f.close() }
    try f.continuity.transaction { $0.authorization.grants[0].expiresAt = 1_001 }
    f.clock.set(1_001)
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.getSyncStatus(f.account)) }
    #expect(try f.continuity.inspect { $0.authorization.grants[0].expiredObserved })
    f.clock.set(1_000)
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.getSyncStatus(f.account)) }
    #expect(f.effects.counts == [0, 0, 0, 0, 0, 0])
}

@Test func capabilityAutonomousRelayProjectsLiabilityWithoutPollingEffects() async throws {
    let f = try CapabilityFixture.make(approvalRequired: false); defer { f.close() }
    guard case .preparePayment(let initial) = try await f.call(.preparePayment(f.payment())) else { throw CapabilityFailure.invalidResponse }
    try await f.waitPayment(initial.identity.selector.operationID)
    _ = try await f.call(.submitPayment(initial.identity.selector))
    try await f.waitPayment(initial.identity.selector.operationID, .uncertain)
    guard case .getOperation(.payment(let uncertain)) = try await f.call(.getOperation(.operation(initial.identity.selector))) else { throw CapabilityFailure.invalidResponse }
    #expect(uncertain.state == .uncertain && uncertain.liabilityUnresolved && uncertain.accountRestriction == .held)
    #expect(uncertain.ordinaryAdmissions == 1 && uncertain.latestAttempt?.number == 1 && uncertain.latestAttempt?.route == .ordinary)
    #expect(uncertain.transactionID == String(repeating: "b", count: 64))
    #expect(f.effects.counts[1] == 1 && f.effects.counts[2] == 1)
    let before = f.effects.counts
    for _ in 0..<5 { _ = try await f.call(.getOperation(.operation(initial.identity.selector))) }
    #expect(f.effects.counts == before)
    await #expect(throws: ServiceProblem(.invalidTransition)) { try await f.call(.cancelOperation(initial.identity.selector)) }
    #expect(try f.continuity.inspect { !$0.gates.isEmpty })
}

@Test func capabilityTrustedConnectionAndExplicitScopeCannotBeClaimedByRequests() async throws {
    let f = try CapabilityFixture.make(); defer { f.close() }
    let wrongPeer = PeerEvidence(identity: .init(teamIdentifier: "foreign", signingIdentifier: "bridge"), signatureValidated: true)
    let unsignedPeer = PeerEvidence(identity: f.context.peer.identity, signatureValidated: false)
    for context in [CapabilityConnectionContext(session: f.context.session, connectionID: "other", peer: f.context.peer),
        .init(session: f.context.session, connectionID: "connection", peer: wrongPeer),
        .init(session: f.context.session, connectionID: "connection", peer: unsignedPeer)] {
        await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.getSyncStatus(f.account), context: context) }
    }
    for account in [try AccountScope(wallet: WalletScope(walletID: "other", network: .mainnet), accountID: "account"),
        try AccountScope(wallet: WalletScope(walletID: "wallet", network: .testnet), accountID: "account"),
        try AccountScope(wallet: f.account.wallet, accountID: "other")] {
        await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.getSyncStatus(account)) }
    }
    #expect(f.effects.counts == [0, 0, 0, 0, 0, 0])
}

@Test func capabilityFirstPendingSyncKeepsMissingObservationExplicit() async throws {
    let f = try CapabilityFixture.make(); defer { f.close() }
    await f.effects.refreshGate.close()
    guard case .synchronizeAccount(let operation) = try await f.call(.synchronizeAccount(KeyedAccountRequest(account: f.account, requestKey: f.key()))) else {
        throw CapabilityFailure.invalidResponse
    }
    try await capabilityEventually { f.effects.counts[4] == 1 }
    let before = f.effects.counts
    guard case .getSyncStatus(let status) = try await f.call(.getSyncStatus(f.account)) else { throw CapabilityFailure.invalidResponse }
    #expect(status.observation == nil && status.readiness.state == .blocked)
    guard case .getOperation(.synchronization(let pending)) = try await f.call(.getOperation(.operation(operation.identity.selector))) else { throw CapabilityFailure.invalidResponse }
    #expect(pending.state == .pending && pending.observation == nil)
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.getBalance(f.account)) }
    #expect(f.effects.counts == before)
    await f.effects.refreshGate.open()
    try await f.waitAccount(operation.identity.selector.operationID, .completed)
}

@Test func capabilityPaginationCursorFitsWithLongValidPrincipalAndFortyItemBoundary() async throws {
    let f = try CapabilityFixture.make(snapshot: true, integrationID: String(repeating: "i", count: 2_048)); defer { f.close() }
    var record = try capabilityRecord()
    var snapshot = try JSONDecoder().decode(OpalBase.Account.Snapshot.self, from: record.snapshot)
    let original = try #require(snapshot.addressBook.transactions.first)
    var transactions: [OpalBase.Account.Snapshot.AddressBook.Transaction] = []
    for index in 1...41 {
        let suffix = String(index, radix: 16)
        let hash = String(repeating: "0", count: 64 - suffix.count) + suffix
        transactions.append(.init(transactionHash: hash, height: original.height, fee: original.fee,
            scriptHashes: [], firstSeenAt: original.firstSeenAt, lastUpdatedAt: original.lastUpdatedAt,
            status: original.status, confirmationHeight: original.confirmationHeight, confirmedAt: original.confirmedAt,
            verificationStatus: original.verificationStatus, merkleProof: nil, lastVerifiedHeight: nil, lastCheckedAt: nil))
    }
    snapshot = OpalBase.Account.Snapshot(purpose: snapshot.purpose, coinType: snapshot.coinType,
        accountUnhardenedIndex: 0, addressBook: .init(receivingEntries: [], changeEntries: [], utxos: [], transactions: transactions))
    record.snapshot = try paymentEncoding(snapshot)
    try f.continuity.transaction { $0.publicSnapshots = [record] }
    guard case .listTransactions(let first) = try await f.call(.listTransactions(AccountPageRequest(account: f.account, page: PageRequest()))) else { throw CapabilityFailure.invalidResponse }
    #expect(first.page.items.count == 40)
    let cursor = try #require(first.page.nextCursor)
    #expect(cursor.utf8.count <= 2_048)
    guard case .listTransactions(let second) = try await f.call(.listTransactions(AccountPageRequest(account: f.account, page: PageRequest(cursor: cursor)))) else { throw CapabilityFailure.invalidResponse }
    #expect(second.page.items.count == 1 && second.page.nextCursor == nil)
    #expect(Set(first.page.items.map(\.transactionID) + second.page.items.map(\.transactionID)).count == 41)
    #expect(f.effects.counts == [0, 0, 0, 0, 0, 0])
}

@Test func capabilityStartupInvalidationProjectsAnExplicitCloseReason() async throws {
    let f = try CapabilityFixture.make(); defer { f.close() }
    guard case .preparePayment(let initial) = try await f.call(.preparePayment(f.payment())) else { throw CapabilityFailure.invalidResponse }
    try await f.waitPayment(initial.identity.selector.operationID)
    _ = try f.continuity.startup()
    guard case .getOperation(.payment(let invalidated)) = try await f.call(.getOperation(.operation(initial.identity.selector))) else { throw CapabilityFailure.invalidResponse }
    #expect(invalidated.state == .closed && invalidated.terminalReason == .invalidated)
    #expect(f.effects.counts[1] == 0 && f.effects.counts[2] == 0)
}

@Test func capabilityRestrictedReadsDoNotRewriteAuthorizationWhenExpiryPasses() async throws {
    let f = try CapabilityFixture.make(); defer { f.close() }
    try f.continuity.transaction { $0.authorization.grants[0].expiresAt = 1_001 }
    _ = try f.continuity.recover(ownerAuthorized: true)
    let before = try f.continuity.inspect { try $0.reference() }
    f.clock.set(1_002)
    await #expect(throws: ServiceProblem(.recoveryRequired)) { try await f.call(.getSyncStatus(f.account)) }
    #expect(try f.continuity.inspect { try $0.reference() } == before)
    #expect(f.effects.counts == [0, 0, 0, 0, 0, 0])
}

// Host authentication below invokes the actual authority for every open/validation. Only the
// known-unlocked observation and local request persistence are synthetic host collaborators.
private struct AppleCapabilityHost: AgentAutomationAccess {
    let fixture: CapabilityFixture
    let credential: Data
    let binding: AgentAutomationBinding
    init(_ fixture: CapabilityFixture, credential: Data? = nil, grantID: String = "grant-distinct") throws {
        self.fixture = fixture; self.credential = credential ?? fixture.credential
        let state = try fixture.continuity.inspect { $0 }
        guard let grant = state.authorization.grants.first(where: { $0.id == grantID }) else { throw AgentAutomationFailure.unavailable }
        // Enrollment facts captured by the test host, never inferred from an entity selector.
        binding = try AgentAutomationBinding(wallet: fixture.account.wallet, integrationID: grant.integrationID,
            grantID: grant.id, walletGeneration: state.authorization.generation, credentialGeneration: grant.credentialGeneration,
            accountIDs: grant.accountIDs, scopes: grant.capabilities.compactMap(IntegrationScope.init(rawValue:)))
    }
    func isKnownUnlocked() async -> Bool { true }
    func openSession() async throws -> AgentAutomationSession {
        let context = try currentContext()
        return AgentAutomationSession(binding: binding,
            client: CapabilityClient(transport: CapabilityEndpointTransport(service: fixture.service, context: context)))
    }
    func validate(binding: AgentAutomationBinding) async throws {
        _ = try currentContext()
        guard binding == self.binding else { throw AgentAutomationFailure.staleContext }
    }
    private func currentContext() throws -> CapabilityConnectionContext {
        let connectionID = UUID().uuidString
        let session = try fixture.authority.authenticate(connectionID: connectionID, peer: fixture.context.peer,
            credential: credential, now: fixture.clock.read().wall)
        guard session.peerProfile == .appleAutomation,
              session.principal.grantID == binding.grantID, session.principal.integrationID == binding.integrationID,
              session.walletGeneration == binding.walletGeneration, session.credentialGeneration == binding.credentialGeneration else {
            throw AgentAutomationFailure.staleContext
        }
        return CapabilityConnectionContext(session: session, connectionID: connectionID, peer: fixture.context.peer)
    }
}
private actor AppleCapabilityRequests: AgentAutomationRequestStore {
    private var rows: [String: RetainedAgentAutomationRequest] = [:]
    var count: Int { rows.count }
    func create(binding: AgentAutomationBinding, payload: AgentAutomationRequestPayload) async throws -> RetainedAgentAutomationRequest {
        let handle = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let key = try RequestKey(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let value = try RetainedAgentAutomationRequest(handleID: handle, owner: .init(binding: binding), payload: payload, requestKey: key)
        rows[handle] = value; return value
    }
    func load(handleID: String, binding: AgentAutomationBinding) async throws -> RetainedAgentAutomationRequest {
        try checked(handleID, binding: binding)
    }
    func recordOperation(handleID: String, binding: AgentAutomationBinding, identity: OperationIdentity) async throws -> RetainedAgentAutomationRequest {
        let value = try checked(handleID, binding: binding)
        guard value.operation == nil || value.operation == identity else { throw AgentAutomationFailure.invalidResponse }
        let enriched = try RetainedAgentAutomationRequest(handleID: value.handleID, owner: value.owner, payload: value.payload,
            requestKey: value.requestKey, operation: identity)
        rows[handleID] = enriched; return enriched
    }
    func recent(binding: AgentAutomationBinding, limit: Int) async throws -> [RetainedAgentAutomationRequest] {
        guard (1...40).contains(limit) else { throw AgentAutomationFailure.invalidReference }
        return rows.values.filter { $0.owner == AgentAutomationRequestOwner(binding: binding) && binding.accountIDs.contains($0.payload.account.accountID) }
            .sorted { $0.handleID < $1.handleID }.prefix(limit).map { $0 }
    }
    private func checked(_ handleID: String, binding: AgentAutomationBinding) throws -> RetainedAgentAutomationRequest {
        guard let value = rows[handleID], value.owner == AgentAutomationRequestOwner(binding: binding),
              binding.accountIDs.contains(value.payload.account.accountID) else { throw AgentAutomationFailure.requestUnavailable }
        return value
    }
}

@Test func appleAdapterCommandOnlyReceiveReplaysWithoutReadScope() async throws {
    let f = try CapabilityFixture.make(scopes: [.receive], peerProfile: .appleAutomation); defer { f.close() }
    let store = AppleCapabilityRequests(), host = try AppleCapabilityHost(f)
    let adapter = AgentAutomationAdapter(access: host, requests: store)
    let retained = try await adapter.newRequest(.createReceiveRequest(f.account))
    guard case .receive(let initial) = try await adapter.execute(handleID: retained.handleID, effect: .createReceiveRequest) else {
        throw CapabilityFailure.invalidResponse
    }
    try await f.waitAccount(initial.identity.selector.operationID, .allocated)
    let beforeReplay = f.effects.counts
    guard case .receive(let replay) = try await adapter.execute(handleID: retained.handleID, effect: .createReceiveRequest) else {
        throw CapabilityFailure.invalidResponse
    }
    #expect(replay.identity == initial.identity && replay.identity.requestKey == retained.requestKey)
    #expect(replay.state == .allocated && replay.allocation?.index == 0)
    #expect(f.effects.counts == beforeReplay && beforeReplay[4] == 1 && beforeReplay[5] == 1)
    await #expect(throws: AgentAutomationFailure.scopeDenied) { try await adapter.resume(handleID: retained.handleID) }
    await #expect(throws: AgentAutomationFailure.scopeDenied) { try await adapter.retainedRequests() }
    let count = await store.count
    let state = try f.continuity.inspect { $0 }
    #expect(count == 1 && state.requests.count == 1)
    #expect(state.allocations.first?.issuedIndices == [0] && state.allocations.first?.issuedHighWater == 0)
    #expect(f.effects.counts == beforeReplay)
}

@Test func appleAdapterCurrentAuthenticationTracksRotationRevocationAndOrigin() async throws {
    let f = try CapabilityFixture.make(scopes: [.read, .receive], peerProfile: .appleAutomation); defer { f.close() }
    let store = AppleCapabilityRequests(), initialHost = try AppleCapabilityHost(f)
    let adapter = AgentAutomationAdapter(access: initialHost, requests: store)
    let retained = try await adapter.newRequest(.createReceiveRequest(f.account))
    guard case .receive(let initial) = try await adapter.execute(handleID: retained.handleID, effect: .createReceiveRequest) else {
        throw CapabilityFailure.invalidResponse
    }
    try await f.waitAccount(initial.identity.selector.operationID, .allocated)
    let beforeRotation = f.effects.counts
    let rotated = try f.authority.rotate(id: initialHost.binding.grantID, owner: f.owner, now: 1_000)
    await #expect(throws: AuthorizationFailure.invalidCredential) { try await adapter.retainedRequests() }
    await #expect(throws: AuthorizationFailure.invalidCredential) { try await adapter.execute(handleID: retained.handleID, effect: .createReceiveRequest) }
    let currentHost = try AppleCapabilityHost(f, credential: rotated.rawValue)
    let current = AgentAutomationAdapter(access: currentHost, requests: store)
    let references = try await current.retainedRequests()
    #expect(references.count == 1 && references[0].requestKey == retained.requestKey)
    guard case .receive(let observed) = try await current.resume(handleID: retained.handleID) else { throw CapabilityFailure.invalidResponse }
    #expect(observed.identity == initial.identity && observed.allocation?.index == 0)
    #expect(currentHost.binding.credentialGeneration == 2 && currentHost.binding.grantID == initialHost.binding.grantID)
    #expect(f.effects.counts == beforeRotation)
    try f.authority.revoke(id: currentHost.binding.grantID, owner: f.owner, now: 1_000)
    await #expect(throws: AuthorizationFailure.revoked) { try await current.retainedRequests() }
    await #expect(throws: AuthorizationFailure.revoked) { try await current.execute(handleID: retained.handleID, effect: .createReceiveRequest) }
    let replacement = try f.authority.enroll(id: "replacement-apple-grant", integrationID: "replacement-apple-integration", accounts: ["account"],
        capabilities: ["read", "receive"], expiry: nil, owner: f.owner, now: 1_000, peerProfile: .appleAutomation)
    let replacementHost = try AppleCapabilityHost(f, credential: replacement.rawValue, grantID: replacement.principal.grantID)
    let replacementSession = try await replacementHost.openSession()
    await #expect(throws: ServiceProblem(.unavailable)) {
        try await replacementSession.client.call(.getOperation(.operation(initial.identity.selector)))
    }
    let replacementAdapter = AgentAutomationAdapter(access: replacementHost, requests: store)
    let foreignReferences = try await replacementAdapter.retainedRequests()
    #expect(foreignReferences.isEmpty)
    await #expect(throws: AgentAutomationFailure.requestUnavailable) { try await replacementAdapter.execute(handleID: retained.handleID, effect: .createReceiveRequest) }
    let count = await store.count
    let state = try f.continuity.inspect { $0 }
    #expect(count == 1 && state.requests.count == 1 && state.allocations.first?.issuedIndices == [0])
    #expect(f.effects.counts == beforeRotation)
}
