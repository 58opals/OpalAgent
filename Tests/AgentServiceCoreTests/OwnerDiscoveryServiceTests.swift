import AgentClient
import AgentNativeIPC
import AgentValues
import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

private enum DiscoveryFixtureFailure: Error { case unexpectedResult, deadline, unexpectedEffect }
private struct DiscoveryClock: PaymentClock {
    func read() -> PaymentClockReading { .init(wall: 1_000, monotonic: 100) }
}
private final class DiscoveryAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuityAnchor?
    func read() throws -> ContinuityAnchor? { lock.withLock { value } }
    func write(_ value: ContinuityAnchor) throws { lock.withLock { self.value = value } }
}
private final class DiscoveryEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var effects: [String: Int] = [:]
    func record(_ name: String) { lock.withLock { effects[name, default: 0] += 1 } }
    var counts: [String: Int] { lock.withLock { effects } }
}
private struct DiscoverySeeds: SeedAccountProvider {
    static let mnemonic = Data("permanently disposable discovery fixture".utf8)
    let effects: DiscoveryEffects
    func generateMnemonic() throws -> Data { effects.record("generate"); return Self.mnemonic }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        effects.record("derive")
        guard mnemonic == Self.mnemonic else { throw PaymentFailure.invalidRequest }
        return DerivedSeedAccount(accountID: "discovery-account", publicDescriptor: Data("synthetic descriptor".utf8))
    }
}
private final class DiscoveryConsent: OwnerConsentProvider, @unchecked Sendable {
    let effects: DiscoveryEffects
    private let lock = NSLock()
    private var reject = false
    init(_ effects: DiscoveryEffects) { self.effects = effects }
    func rejectFurtherConsent() { lock.withLock { reject = true } }
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        effects.record("consent")
        guard !lock.withLock({ reject }) else { throw DiscoveryFixtureFailure.unexpectedEffect }
        return OwnerConsentProof(challenge: challenge, authenticatedAt: 1_000)
    }
}
private struct DiscoveryBoundary: AccountChainBoundary, PaymentExecutionBoundary {
    let effects: DiscoveryEffects
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        effects.record("refresh")
        throw DiscoveryFixtureFailure.unexpectedEffect
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        effects.record("address")
        throw DiscoveryFixtureFailure.unexpectedEffect
    }
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview {
        effects.record("prepare")
        return PaymentPreview(operationID: request.operationID, accountID: request.accountID, network: request.network,
            destinationScript: request.destinationScript, amount: request.amount, fee: 100,
            selectedInputs: [String(repeating: "11", count: 32) + ":0"], change: Data(),
            templateDigest: paymentDigest(try paymentEncoding(request)), leaseDeadline: 1_300)
    }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment {
        effects.record("sign"); throw DiscoveryFixtureFailure.unexpectedEffect
    }
    func preflight(_ payment: SignedPayment) async throws { effects.record("preflight"); throw DiscoveryFixtureFailure.unexpectedEffect }
    func validateAdmission(_ payment: SignedPayment) throws { effects.record("admission"); throw DiscoveryFixtureFailure.unexpectedEffect }
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        effects.record("handoff"); throw DiscoveryFixtureFailure.unexpectedEffect
    }
    func dispose(operationID: String) async throws { effects.record("dispose") }
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation {
        effects.record("observe"); throw DiscoveryFixtureFailure.unexpectedEffect
    }
}
private final class DiscoveryAuthorities: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ServiceAuthority?
    func get(_ continuity: ContinuityCoordinator, _ policy: AuthorityPolicy) throws -> ServiceAuthority {
        try lock.withLock {
            if let value { return value }
            let result = try ServiceAuthority(continuity: continuity, policy: policy)
            value = result
            return result
        }
    }
}
private struct DiscoveryNativeTransport: OwnerControlTransport {
    let service: OwnerControlService
    let connection: OwnerConnectionContext
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        let id = UUID()
        let packet = try NativeWire.ownerRequest(request, requestID: id)
        let result = await NativeServiceFrames.owner(packet, service: service, context: connection)
        return try NativeWire.decodeOwnerResponse(result, requestID: id, method: request.call.method)
    }
}
private final class DiscoveryFixture: @unchecked Sendable {
    let directory: URL
    let journal: SQLiteJournal
    let anchor = DiscoveryAnchor()
    let continuity: ContinuityCoordinator
    let policy: AuthorityPolicy
    let effects = DiscoveryEffects()
    let consent: DiscoveryConsent
    let authorities = DiscoveryAuthorities()
    let payments: PaymentEngine
    let service: OwnerControlService
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owner-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
        continuity = ContinuityCoordinator(database: journal, anchor: anchor)
        let owner = SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "owner")
        policy = AuthorityPolicy(bridge: .init(teamIdentifier: "synthetic", signingIdentifier: "bridge"), owner: owner,
            accountIDs: ["discovery-account"], capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"], ownerAuthenticationAge: 30)
        let effects = self.effects
        let vault = WalletSeedVault(keys: InjectedWrappingKeySource(read: {
            effects.record("wrappingKey")
            return .available(SymmetricKey(data: Data(repeating: 0x59, count: 32)))
        }), accounts: DiscoverySeeds(effects: effects))
        let boundary = DiscoveryBoundary(effects: effects)
        consent = DiscoveryConsent(effects)
        payments = PaymentEngine(continuity: continuity, authorityPolicy: policy, boundary: boundary, clock: DiscoveryClock())
        let continuity = self.continuity; let policy = self.policy; let authorities = self.authorities
        service = OwnerControlService(continuity: continuity, policy: policy,
            authority: { try authorities.get(continuity, policy) }, vault: vault, accounts: boundary,
            payments: payments, consent: consent, clock: DiscoveryClock())
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func connection(peer: PeerEvidence? = nil) -> OwnerConnectionContext {
        OwnerConnectionContext(connectionID: UUID().uuidString,
            peer: peer ?? PeerEvidence(identity: policy.owner, signatureValidated: true))
    }
    func client(connection: OwnerConnectionContext? = nil) -> OwnerControlClient {
        OwnerControlClient(transport: DiscoveryNativeTransport(service: service, connection: connection ?? self.connection()))
    }
    func create(restoring: Bool = false) async throws -> WalletScope {
        let result: OwnerControlResult
        if restoring {
            result = try await client().call(.restoreSeed(.init(network: .mainnet,
                mnemonic: SensitiveOwnerMaterial(bytes: DiscoverySeeds.mnemonic))))
        } else { result = try await client().call(.createWallet(network: .mainnet)) }
        switch result {
        case .createWallet(let status), .restoreSeed(let status):
            return try #require(status.wallet)
        default: throw DiscoveryFixtureFailure.unexpectedResult
        }
    }
    func session(wallet: WalletScope) async throws -> AuthorizationSession {
        _ = try await client().call(.enableWallet(wallet))
        let request = try EnrollmentRequest(wallet: wallet, integrationID: "discovery-integration", accountIDs: ["discovery-account"],
            scopes: [.read, .prepare, .submit, .cancel])
        guard case .enrollIntegration(let issued) = try await client().call(.enrollIntegration(request)) else {
            throw DiscoveryFixtureFailure.unexpectedResult
        }
        return try authorities.get(continuity, policy).authenticate(connectionID: "discovery-bridge",
            peer: PeerEvidence(identity: policy.bridge, signatureValidated: true),
            credential: issued.credential.withBytes { $0 }, now: 1_000)
    }
    func prepared(_ session: AuthorizationSession, key: Int) async throws -> String {
        let requestKey = String(repeating: "0", count: 31) + String(key, radix: 16)
        let result = try await payments.prepare(.init(accountID: "discovery-account", network: "mainnet", requestKey: requestKey,
            destinationScript: Data([0x76, 0xa9, 0x14]) + Data(repeating: 1, count: 20) + Data([0x88, 0xac]), amount: 1_000),
            session: session, connectionID: "discovery-bridge", peer: PeerEvidence(identity: policy.bridge, signatureValidated: true))
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try continuity.inspect({ $0.payments.first { $0.id == result.payment.id }?.disposition }) == .prepared { return result.payment.id }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw DiscoveryFixtureFailure.deadline
    }
    func cancelled(_ session: AuthorizationSession, key: Int) async throws -> String {
        let id = try await prepared(session, key: key)
        _ = try await payments.cancel(operationID: id, session: session, connectionID: "discovery-bridge",
            peer: PeerEvidence(identity: policy.bridge, signatureValidated: true))
        return id
    }
    func page(_ client: OwnerControlClient, wallet: WalletScope, limit: Int = 40, cursor: String? = nil) async throws -> OwnerPaymentPage {
        guard case .listPayments(let value) = try await client.call(.listPayments(.init(wallet: wallet, page: PageRequest(limit: limit, cursor: cursor)))) else {
            throw DiscoveryFixtureFailure.unexpectedResult
        }
        return value
    }
}

// Actual public owner client + native frame dispatcher + SQLite/Core. Synthetic peer, consent,
// seed and engine-boundary inputs do not qualify signed NSXPC, live custody or human authentication.
@Test(arguments: [false, true])
func ownerDiscoveryFindsCreatedOrRestoredAccountWithoutGrantOrReadEffects(_ restoring: Bool) async throws {
    let f = try DiscoveryFixture(); defer { f.remove() }
    let wallet = try await f.create(restoring: restoring)
    let before = try f.continuity.inspect { $0 }
    #expect(before.mode == .restricted && before.authorization.grants.isEmpty)
    f.consent.rejectFurtherConsent()
    let counts = f.effects.counts
    let client = f.client()
    guard case .listAccounts(let directory) = try await client.call(.listAccounts(wallet)) else { throw DiscoveryFixtureFailure.unexpectedResult }
    #expect(directory.walletGeneration == before.authorization.generation)
    #expect(directory.accounts == [try AccountScope(wallet: wallet, accountID: "discovery-account")])
    let page = try await f.page(client, wallet: wallet)
    #expect(page.page.items.isEmpty && page.page.nextCursor == nil && page.walletGeneration == directory.walletGeneration)
    #expect(page.snapshotID.count == 64)
    #expect(try f.continuity.inspect { try $0.reference() } == before.reference())
    #expect(f.effects.counts == counts)
}

@Test func ownerDiscoveryFindsPendingApprovalAndTerminalPaymentWithoutKnownSelector() async throws {
    let f = try DiscoveryFixture(); defer { f.remove() }
    let wallet = try await f.create()
    let session = try await f.session(wallet: wallet)
    let closed = try await f.cancelled(session, key: 1)
    _ = try await f.client().call(.setApprovalPolicy(.init(wallet: wallet, expectedRevision: 1, approvalRequired: true)))
    let pending = try await f.prepared(session, key: 2)
    _ = try await f.payments.submit(operationID: pending, session: session, connectionID: "discovery-bridge",
        peer: PeerEvidence(identity: f.policy.bridge, signatureValidated: true))
    let before = try f.continuity.inspect { try $0.reference() }
    let effects = f.effects.counts
    f.consent.rejectFurtherConsent()
    let freshClient = f.client()
    let page = try await f.page(freshClient, wallet: wallet)
    #expect(page.page.items.map { $0.identity.selector.operationID } == [closed, pending].sorted())
    let discovered = try #require(page.page.items.first { $0.state == .pendingApproval })
    #expect(page.page.items.first { $0.identity.selector.operationID == closed }?.terminalReason == .cancelled)
    guard case .reviewPreview(let review) = try await freshClient.call(.reviewPreview(discovered.identity.selector)) else {
        throw DiscoveryFixtureFailure.unexpectedResult
    }
    #expect(review.operation == discovered.identity.selector && review.preview == discovered.preview)
    #expect(discovered.ordinaryAdmissions == 0 && !discovered.liabilityUnresolved)
    let encoded = try JSONEncoder().encode(page)
    let text = String(decoding: encoded, as: UTF8.self)
    for field in ["canonicalBytes", "encryptedMnemonic", "publicDescriptor", "credentialDigest", "unsignedTemplate", "inputPayloads"] {
        #expect(!text.contains("\"\(field)\""))
    }
    #expect(try f.continuity.inspect { try $0.reference() } == before)
    #expect(f.effects.counts == effects && effects["handoff"] == nil && effects["sign"] == nil)
}

@Test func ownerPaymentPaginationBindsExactSnapshotAndRejectsStaleOrForeignContext() async throws {
    let f = try DiscoveryFixture(); defer { f.remove() }
    let wallet = try await f.create()
    let session = try await f.session(wallet: wallet)
    var ids: [String] = []
    for key in 1...3 { ids.append(try await f.cancelled(session, key: key)) }
    let before = try f.continuity.inspect { try $0.reference() }
    let effects = f.effects.counts
    let client = f.client()
    let first = try await f.page(client, wallet: wallet, limit: 1)
    let repeated = try await f.page(f.client(), wallet: wallet, limit: 1)
    #expect(first == repeated)
    let cursor = try #require(first.page.nextCursor)
    #expect(cursor.utf8.count <= 2048)
    let second = try await f.page(client, wallet: wallet, limit: 1, cursor: cursor)
    let secondCursor = try #require(second.page.nextCursor)
    let third = try await f.page(client, wallet: wallet, limit: 1, cursor: secondCursor)
    #expect((first.page.items + second.page.items + third.page.items).map { $0.identity.selector.operationID } == ids.sorted())
    #expect(first.snapshotID == second.snapshotID && second.snapshotID == third.snapshotID && third.page.nextCursor == nil)
    #expect(try f.continuity.inspect { try $0.reference() } == before && f.effects.counts == effects)
    await #expect(throws: ServiceProblem(.invalidRequest)) { try await f.page(client, wallet: wallet, limit: 1, cursor: "bogus") }
    for foreign in [try WalletScope(walletID: "another-wallet", network: wallet.network),
                    try WalletScope(walletID: wallet.walletID, network: .chipnet)] {
        await #expect(throws: ServiceProblem(.unavailable)) { try await client.call(.listAccounts(foreign)) }
        await #expect(throws: ServiceProblem(.unavailable)) { try await f.page(client, wallet: foreign, limit: 1, cursor: cursor) }
    }
    _ = try await client.call(.setApprovalPolicy(.init(wallet: wallet, expectedRevision: 1, approvalRequired: true)))
    await #expect(throws: ServiceProblem(.staleContext)) { try await f.page(client, wallet: wallet, limit: 1, cursor: cursor) }
    let changed = try await f.page(client, wallet: wallet, limit: 1)
    #expect(changed.snapshotID != first.snapshotID && changed.walletGeneration == first.walletGeneration)
    _ = try await client.call(.recoverJournal(.init(wallet: wallet, source: nil)))
    let recovered = try await f.page(f.client(), wallet: wallet)
    #expect(recovered.walletGeneration > first.walletGeneration)
    #expect(recovered.page.items.map { $0.identity.selector.operationID } == ids.sorted())
    await #expect(throws: ServiceProblem(.staleContext)) { try await f.page(client, wallet: wallet, limit: 1, cursor: cursor) }
}

@Test func ownerDiscoveryRequiresVerifiedLivePeerAndTrustedContinuity() async throws {
    let f = try DiscoveryFixture(); defer { f.remove() }
    let wallet = try await f.create()
    let wrong = f.client(connection: f.connection(peer: PeerEvidence(identity: f.policy.bridge, signatureValidated: true)))
    let connection = f.connection()
    connection.invalidate()
    let invalidated = f.client(connection: connection)
    let before = try f.continuity.inspect { try $0.reference() }
    let effects = f.effects.counts
    f.consent.rejectFurtherConsent()
    for client in [wrong, invalidated] {
        await #expect(throws: ServiceProblem(.unavailable)) { try await client.call(.listAccounts(wallet)) }
        await #expect(throws: ServiceProblem(.unavailable)) { try await f.page(client, wallet: wallet) }
    }
    var corrupted = before
    corrupted.commitment = Data(repeating: 0x99, count: 32)
    try f.anchor.write(ContinuityAnchor(committed: corrupted))
    await #expect(throws: ServiceProblem(.recoveryRequired)) { try await f.client().call(.listAccounts(wallet)) }
    await #expect(throws: ServiceProblem(.recoveryRequired)) { try await f.page(f.client(), wallet: wallet) }
    // This intentional raw read checks that denied/quarantined reads wrote no SQL state.
    #expect(try f.journal.read()?.reference() == before)
    #expect(f.effects.counts == effects)
}
