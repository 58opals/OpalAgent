import AgentValues
import AgentClient
import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

private final class OwnerTestClock: PaymentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Int64 = 1_000
    func read() -> PaymentClockReading { lock.withLock { .init(wall: wall, monotonic: UInt64(wall)) } }
    func advance(_ value: Int64) { lock.withLock { wall += value } }
}
private final class OwnerTestAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuityAnchor?
    func read() throws -> ContinuityAnchor? { lock.withLock { value } }
    func write(_ value: ContinuityAnchor) throws { lock.withLock { self.value = value } }
}
private enum ConsentFault: CaseIterable { case none, purpose, connection, nonce, stale }
private final class OwnerTestConsent: OwnerConsentProvider, @unchecked Sendable {
    let clock: OwnerTestClock
    private let lock = NSLock()
    private var fault: ConsentFault = .none
    private var purposes: [OwnerControlMethod] = []
    init(_ clock: OwnerTestClock) { self.clock = clock }
    func set(_ fault: ConsentFault) { lock.withLock { self.fault = fault } }
    var observedPurposes: [OwnerControlMethod] { lock.withLock { purposes } }
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        let fault = lock.withLock { purposes.append(challenge.purpose); return self.fault }
        let changed = OwnerConsentChallenge(connectionID: fault == .connection ? "foreign" : challenge.connectionID,
            nonce: fault == .nonce ? UUID() : challenge.nonce,
            purpose: fault == .purpose ? (challenge.purpose == .status ? .enableWallet : .status) : challenge.purpose,
            reviewCommitment: challenge.reviewCommitment)
        return OwnerConsentProof(challenge: changed, authenticatedAt: clock.read().wall - (fault == .stale ? 31 : 0))
    }
}
private final class OwnerTestSeeds: SeedAccountProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    func onDerive(_ callback: @escaping @Sendable () -> Void) { lock.withLock { self.callback = callback } }
    func generateMnemonic() throws -> Data { Data("disposable owner fixture".utf8) }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        lock.withLock { callback }?()
        guard mnemonic == Data("disposable owner fixture".utf8) else { throw PaymentFailure.invalidRequest }
        return DerivedSeedAccount(accountID: "owner-account", publicDescriptor: Data("synthetic descriptor".utf8))
    }
}
private final class OwnerTestBoundary: AccountChainBoundary, PaymentExecutionBoundary, @unchecked Sendable {
    let clock: OwnerTestClock
    private let lock = NSLock()
    private var relays = 0
    private var addresses = 0
    init(_ clock: OwnerTestClock) { self.clock = clock }
    var relayCount: Int { lock.withLock { relays } }
    var addressCount: Int { lock.withLock { addresses } }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        .init(accountID: accountID, network: network, providerID: "synthetic", viewID: "view", chainTip: "tip",
            observedAt: clock.read().wall, complete: true, fresh: true, balance: 0, snapshot: Data(), receivingHorizon: -1, changeHorizon: -1)
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        lock.withLock { addresses += 1 }; throw PaymentFailure.unavailable
    }
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview {
        PaymentPreview(operationID: request.operationID, accountID: request.accountID, network: request.network,
            destinationScript: request.destinationScript, amount: request.amount, fee: 100,
            selectedInputs: [String(repeating: "11", count: 32) + ":0"], change: Data(),
            templateDigest: paymentDigest(try paymentEncoding(request)), leaseDeadline: clock.read().wall + 300)
    }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment {
        let bytes = try paymentEncoding(preview)
        return SignedPayment(operationID: preview.operationID, bytes: bytes, digest: paymentDigest(bytes), transactionID: String(repeating: "22", count: 32))
    }
    func preflight(_ payment: SignedPayment) async throws {}
    func validateAdmission(_ payment: SignedPayment) throws {}
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        try admission {
            lock.withLock { relays += 1 }
            return PaymentTransportInvocation(id: UUID().uuidString,
                result: { .unknown(source: "synthetic") }, cancel: {})
        }
    }
    func dispose(operationID: String) async throws {}
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation {
        PaymentObservation(source: "synthetic", view: "view", chainTip: "tip", observedAt: clock.read().wall, complete: true, fresh: true)
    }
}
private final class OwnerTestAuthorityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ServiceAuthority?
    func get(_ continuity: ContinuityCoordinator, _ policy: AuthorityPolicy) throws -> ServiceAuthority {
        try lock.withLock {
            if let value { return value }
            let value = try ServiceAuthority(continuity: continuity, policy: policy); self.value = value; return value
        }
    }
}
private struct OwnerEndpointTransport: OwnerControlTransport {
    let service: OwnerControlService
    let connection: OwnerConnectionContext
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        try await service.send(request, connection: connection)
    }
}
private final class OwnerEndpointFixture: @unchecked Sendable {
    let directory: URL
    let journal: SQLiteJournal
    let continuity: ContinuityCoordinator
    let anchor = OwnerTestAnchor()
    let policy: AuthorityPolicy
    let clock = OwnerTestClock()
    let consent: OwnerTestConsent
    let seeds = OwnerTestSeeds()
    let boundary: OwnerTestBoundary
    let engine: PaymentEngine
    let vault: WalletSeedVault
    let service: OwnerControlService
    let connection: OwnerConnectionContext
    let authorities = OwnerTestAuthorityBox()
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owner-endpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
        continuity = ContinuityCoordinator(database: journal, anchor: anchor)
        let owner = SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "owner")
        policy = AuthorityPolicy(bridge: .init(teamIdentifier: "synthetic", signingIdentifier: "bridge"), owner: owner,
            accountIDs: ["owner-account"], capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"], ownerAuthenticationAge: 30)
        connection = OwnerConnectionContext(connectionID: "owner-connection", peer: .init(identity: owner, signatureValidated: true))
        consent = OwnerTestConsent(clock); boundary = OwnerTestBoundary(clock)
        engine = PaymentEngine(continuity: continuity, authorityPolicy: policy, boundary: boundary, clock: clock)
        let continuity = self.continuity; let policy = self.policy; let authorities = self.authorities
        vault = WalletSeedVault(keys: InjectedWrappingKeySource(read: {
            .available(SymmetricKey(data: Data(repeating: 0x49, count: 32)))
        }), accounts: seeds)
        service = OwnerControlService(continuity: continuity, policy: policy,
            authority: { try authorities.get(continuity, policy) }, vault: vault, accounts: boundary,
            payments: engine, consent: consent, clock: clock)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func call(_ call: OwnerControlCall) async throws -> OwnerControlResult {
        try await OwnerControlClient(transport: OwnerEndpointTransport(service: service, connection: connection)).call(call)
    }
    func createEnabled() async throws -> (WalletScope, AccountScope) {
        guard case .createWallet(let status) = try await call(.createWallet(network: .mainnet)), let wallet = status.wallet else { throw PaymentFailure.unavailable }
        _ = try await call(.enableWallet(wallet))
        return (wallet, try AccountScope(wallet: wallet, accountID: "owner-account"))
    }
    func enroll(_ wallet: WalletScope) async throws -> OwnerIssuedCredential {
        let request = try EnrollmentRequest(wallet: wallet, integrationID: "owner-test-integration", accountIDs: ["owner-account"],
            scopes: [.read, .sync, .receive, .prepare, .submit, .cancel])
        guard case .enrollIntegration(let issued) = try await call(.enrollIntegration(request)) else { throw PaymentFailure.unavailable }
        return issued
    }
    func prepare(_ account: AccountScope, session: AuthorizationSession, key: String) async throws -> OperationSelector {
        let script = Data([0x76, 0xa9, 0x14]) + Data(repeating: 1, count: 20) + Data([0x88, 0xac])
        let result = try await engine.prepare(PaymentRequest(accountID: account.accountID, network: "mainnet", requestKey: key,
            destinationScript: script, amount: 1_000), session: session, connectionID: "bridge", peer: .init(identity: policy.bridge, signatureValidated: true))
        let id = result.payment.id
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try journal.read()?.payments.first(where: { $0.id == id })?.disposition == .prepared {
                return try OperationSelector(account: account, operationID: id)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw PaymentFailure.unavailable
    }
}

@Test func ownerEndpointRejectsBridgeAndBindsFreshConsentBeforeAnyWalletWrite() async throws {
    let f = try OwnerEndpointFixture(); defer { f.remove() }
    guard case .status(let empty) = try await f.call(.status) else { Issue.record("missing owner status"); return }
    #expect(empty.wallet == nil && empty.custody == .absent)
    _ = try await f.call(.inspectRecovery)
    #expect(f.consent.observedPurposes.isEmpty)
    let bridge = OwnerConnectionContext(connectionID: "bridge", peer: .init(identity: f.policy.bridge, signatureValidated: true))
    await #expect(throws: ServiceProblem(.unavailable)) {
        try await f.service.send(OwnerControlRequest(call: .createWallet(network: .mainnet)), connection: bridge)
    }
    for fault in ConsentFault.allCases where fault != .none {
        f.consent.set(fault)
        await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.createWallet(network: .mainnet)) }
        #expect(try f.journal.read() == nil)
    }
    f.consent.set(.none)
    f.seeds.onDerive { f.connection.invalidate() }
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.createWallet(network: .mainnet)) }
    #expect(try f.journal.read() == nil)
}

@Test func ownerEndpointSeparatesCreationEnablementCredentialsDiscoveryAndRecovery() async throws {
    let f = try OwnerEndpointFixture(); defer { f.remove() }
    guard case .createWallet(let created) = try await f.call(.createWallet(network: .mainnet)), let wallet = created.wallet else { throw PaymentFailure.unavailable }
    #expect(created.availability == .restricted && created.grants.isEmpty && created.custody == .presentUnverified)
    let account = try AccountScope(wallet: wallet, accountID: "owner-account")
    _ = try await f.call(.discoverPublicAccount(account))
    #expect(try f.journal.read()?.mode == .restricted)
    #expect(f.boundary.addressCount == 0)
    _ = try await f.call(.enableWallet(wallet))
    let issued = try await f.enroll(wallet)
    let authority = try f.authorities.get(f.continuity, f.policy)
    let credential = issued.credential.withBytes { $0 }
    _ = try authority.authenticate(connectionID: "old", peer: .init(identity: f.policy.bridge, signatureValidated: true), credential: credential, now: 1_000)
    guard case .rotateGrant(let rotated) = try await f.call(.rotateGrant(issued.grant.selector)) else { throw PaymentFailure.unavailable }
    #expect(rotated.grant.credentialGeneration == 2)
    #expect(throws: AuthorizationFailure.invalidCredential) {
        try authority.authenticate(connectionID: "old-reconnect", peer: .init(identity: f.policy.bridge, signatureValidated: true), credential: credential, now: 1_000)
    }
    _ = try await f.call(.revokeGrant(rotated.grant.selector))
    #expect(throws: AuthorizationFailure.revoked) {
        try authority.authenticate(connectionID: "revoked", peer: .init(identity: f.policy.bridge, signatureValidated: true),
            credential: rotated.credential.withBytes { $0 }, now: 1_000)
    }
    guard case .exportRecoveryMaterial(let material) = try await f.call(.exportRecoveryMaterial(wallet)) else { throw PaymentFailure.unavailable }
    #expect(material.material.withBytes { $0 } == Data("disposable owner fixture".utf8))
    #expect(!String(reflecting: material).contains("disposable owner fixture"))
    _ = try await f.call(.inspectRecovery)
    await #expect(throws: ServiceProblem(.unavailable)) {
        try await f.call(.recoverJournal(JournalRecoveryRequest(wallet: wallet, source: try RecoverySourceHandle("unknown-archive"))))
    }
    _ = try await f.call(.recoverJournal(JournalRecoveryRequest(wallet: wallet, source: nil)))
    guard case .restoreSeed(let restored) = try await f.call(.restoreSeed(SeedRestoreRequest(network: .mainnet, mnemonic: material.material))) else { throw PaymentFailure.unavailable }
    #expect(restored.availability == .restricted && restored.grants.allSatisfy { $0.state == .revoked })
    #expect(f.boundary.relayCount == 0 && f.boundary.addressCount == 0)
}

@Test func ownerEndpointComparesExactPreviewAndRetainsSingleRelayReceipt() async throws {
    let f = try OwnerEndpointFixture(); defer { f.remove() }
    let (wallet, account) = try await f.createEnabled()
    let issued = try await f.enroll(wallet)
    let authority = try f.authorities.get(f.continuity, f.policy)
    let peer = PeerEvidence(identity: f.policy.bridge, signatureValidated: true)
    let session = try authority.authenticate(connectionID: "bridge", peer: peer, credential: issued.credential.withBytes { $0 }, now: 1_000)
    _ = try await f.call(.setApprovalPolicy(ApprovalPolicyRequest(wallet: wallet, expectedRevision: 1, approvalRequired: true)))
    await #expect(throws: ServiceProblem(.staleContext)) {
        try await f.call(.setApprovalPolicy(ApprovalPolicyRequest(wallet: wallet, expectedRevision: 1, approvalRequired: false)))
    }
    let rejected = try await f.prepare(account, session: session, key: String(repeating: "a", count: 32))
    _ = try await f.engine.submit(operationID: rejected.operationID, session: session, connectionID: "bridge", peer: peer)
    guard case .reviewPreview(let review) = try await f.call(.reviewPreview(rejected)) else { throw PaymentFailure.unavailable }
    let forged = ExactPreviewReviewContext(operation: review.operation, preview: review.preview,
        previewContextDigest: review.previewContextDigest, walletGeneration: review.walletGeneration,
        policyRevision: review.policyRevision + 1, originGrantID: review.originGrantID, originCredentialGeneration: review.originCredentialGeneration)
    await #expect(throws: ServiceProblem(.staleContext)) { try await f.call(.approveExactPayment(forged)) }
    _ = try await f.call(.rejectExactPayment(review))
    let selector = try await f.prepare(account, session: session, key: String(repeating: "b", count: 32))
    _ = try await f.engine.submit(operationID: selector.operationID, session: session, connectionID: "bridge", peer: peer)
    guard case .reviewPreview(let exact) = try await f.call(.reviewPreview(selector)) else { throw PaymentFailure.unavailable }
    _ = try await f.call(.approveExactPayment(exact))
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try f.journal.read()?.payments.first(where: { $0.id == selector.operationID })?.disposition == .uncertain { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    guard case .reviewRelay(let context) = try await f.call(.reviewRelay(selector)) else { throw PaymentFailure.unavailable }
    let deniedContext = ExactRelayReviewContext(operation: context.operation, transactionDigest: context.transactionDigest,
        walletGeneration: context.walletGeneration, policyRevision: context.policyRevision + 1,
        evidenceRevision: context.evidenceRevision, accountLiabilityContextDigest: context.accountLiabilityContextDigest)
    let deniedKey = try RequestKey(String(repeating: "d", count: 32))
    guard case .authorizeExactRelay(let denied) = try await f.call(.authorizeExactRelay(.init(requestKey: deniedKey, context: deniedContext))) else { throw PaymentFailure.unavailable }
    #expect(denied.outcome == .noAdmission && denied.terminalReason == .staleContext && f.boundary.relayCount == 1)
    await #expect(throws: ServiceProblem(.conflictingRequest)) {
        try await f.call(.authorizeExactRelay(.init(requestKey: deniedKey, context: context)))
    }
    let request = OwnerRelayRequest(requestKey: try RequestKey(String(repeating: "c", count: 32)), context: context)
    guard case .authorizeExactRelay(let admitted) = try await f.call(.authorizeExactRelay(request)) else { throw PaymentFailure.unavailable }
    #expect(admitted.outcome == .admitted && f.boundary.relayCount == 2)
    let before = f.boundary.relayCount
    _ = try await f.call(.authorizeExactRelay(request))
    guard case .relayReceipt(let receipt) = try await f.call(.relayReceipt(.init(wallet: wallet, requestKey: request.requestKey))) else { throw PaymentFailure.unavailable }
    #expect(receipt.context == context && receipt.outcome == .admitted)
    _ = try await f.call(.paymentStatus(selector))
    #expect(f.boundary.relayCount == before)
    #expect(Set(f.consent.observedPurposes).isSuperset(of: [.approveExactPayment, .rejectExactPayment, .authorizeExactRelay]))
    #expect(Set(f.consent.observedPurposes).isDisjoint(with: [.status, .inspectRecovery, .paymentStatus, .reviewPreview, .reviewRelay, .relayReceipt]))
}

@Test func ownerSecretExportRejectsGenerationChangeDuringDerivation() async throws {
    let f = try OwnerEndpointFixture(); defer { f.remove() }
    let (wallet, _) = try await f.createEnabled()
    f.seeds.onDerive { _ = try? f.continuity.recover(ownerAuthorized: true) }
    await #expect(throws: ServiceProblem(.staleContext)) {
        try await f.call(.exportRecoveryMaterial(wallet))
    }
    #expect(try f.journal.read()?.authorization.generation == 2)
    #expect(try f.journal.read()?.mode == .restricted)
}

@Test func ownerStatusDoesNotOpenMissingCustodyAndSeedOnlyRestoreStaysRestricted() async throws {
    let f = try OwnerEndpointFixture(); defer { f.remove() }
    let mnemonic = try SensitiveOwnerMaterial(bytes: Data("disposable owner fixture".utf8))
    guard case .restoreSeed(let restored) = try await f.call(.restoreSeed(.init(network: .mainnet, mnemonic: mnemonic))),
          let wallet = restored.wallet else { throw PaymentFailure.unavailable }
    #expect(restored.availability == .restricted && restored.history == .incomplete)
    let missing = WalletSeedVault(keys: InjectedWrappingKeySource(read: { .missing }), accounts: f.seeds)
    let service = OwnerControlService(continuity: f.continuity, policy: f.policy,
        authority: { try f.authorities.get(f.continuity, f.policy) }, vault: missing, accounts: f.boundary,
        payments: f.engine, consent: f.consent, clock: f.clock)
    let before = f.consent.observedPurposes.count
    guard case .status(let status) = try await service.send(.init(call: .status), connection: f.connection).result else { throw PaymentFailure.unavailable }
    #expect(status.custody == .presentUnverified && status.history == .incomplete && f.consent.observedPurposes.count == before)
    await #expect(throws: ServiceProblem(.keyUnavailable)) {
        try await service.send(.init(call: .exportRecoveryMaterial(wallet)), connection: f.connection)
    }
    #expect(try f.journal.read()?.mode == .restricted && f.journal.read()?.authorization.grants.isEmpty == true)
}

private struct OwnerTestArchive: OwnerRecoveryArchiveProvider {
    let state: CanonicalState
    let handle = try! RecoverySourceHandle("archive")
    func availableSources() throws -> [RecoverySourceHandle] { [handle] }
    func load(_ handle: RecoverySourceHandle) throws -> CanonicalState {
        guard handle == self.handle else { throw PaymentFailure.unavailable }; return state
    }
}
@Test func ownerArchiveRecoveryChecksSelectedWalletBeforeRestoringAnAbsentDatabase() async throws {
    let source = try OwnerEndpointFixture(); defer { source.remove() }
    _ = try await source.createEnabled()
    let archive = OwnerTestArchive(state: try #require(try source.journal.read()))
    let target = try OwnerEndpointFixture(); defer { target.remove() }
    try target.anchor.write(ContinuityAnchor(committed: archive.state.reference()))
    let before = try target.anchor.read()
    let service = OwnerControlService(continuity: target.continuity, policy: target.policy,
        authority: { try target.authorities.get(target.continuity, target.policy) }, vault: target.vault,
        accounts: target.boundary, payments: target.engine, consent: target.consent, archives: archive, clock: target.clock)
    let wrong = try WalletScope(walletID: "wrong-wallet", network: .mainnet)
    await #expect(throws: ServiceProblem(.unavailable)) {
        try await service.send(.init(call: .recoverJournal(.init(wallet: wrong, source: archive.handle))), connection: target.connection)
    }
    #expect(try target.journal.read() == nil && target.anchor.read() == before)
    let correct = try WalletScope(walletID: archive.state.authorization.walletID, network: .mainnet)
    guard case .recoverJournal(let recovered) = try await service.send(.init(call: .recoverJournal(.init(wallet: correct, source: archive.handle))), connection: target.connection).result else { throw PaymentFailure.unavailable }
    #expect(recovered.wallet == correct && recovered.availability == .restricted && recovered.history == .complete)
}

@Test func ownerConsentExpiringDuringSeedDerivationCannotInitializeCustody() async throws {
    let f = try OwnerEndpointFixture(); defer { f.remove() }
    f.seeds.onDerive { f.clock.advance(31) }
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.createWallet(network: .mainnet)) }
    #expect(try f.journal.read() == nil && f.anchor.read() == nil)
}
@Test func ownerUnsignedPeerCannotReadOrActAndNeverStartsConsent() async throws {
    let f = try OwnerEndpointFixture(); defer { f.remove() }
    let connection = OwnerConnectionContext(connectionID: "unsigned-owner", peer: .init(identity: f.policy.owner, signatureValidated: false))
    for call in [OwnerControlCall.status, .createWallet(network: .mainnet)] {
        await #expect(throws: ServiceProblem(.unavailable)) {
            try await f.service.send(.init(call: call), connection: connection)
        }
    }
    #expect(f.consent.observedPurposes.isEmpty)
    #expect(try f.journal.read() == nil)
}
@Test func ownerLostCredentialDeliveryUsesMetadataThenRotationRatherThanSecretLookup() async throws {
    let f = try OwnerEndpointFixture(); defer { f.remove() }
    let (wallet, _) = try await f.createEnabled()
    _ = try await f.enroll(wallet) // Deliberately discard the only delivery, as after a lost response.
    guard case .status(let status) = try await f.call(.status), let grant = status.grants.first else { throw PaymentFailure.unavailable }
    #expect(grant.credentialGeneration == 1)
    guard case .rotateGrant(let replacement) = try await f.call(.rotateGrant(grant.selector)) else { throw PaymentFailure.unavailable }
    #expect(replacement.grant.credentialGeneration == 2)
    let authority = try f.authorities.get(f.continuity, f.policy)
    let session = try authority.authenticate(connectionID: "replacement", peer: .init(identity: f.policy.bridge, signatureValidated: true),
        credential: replacement.credential.withBytes { $0 }, now: f.clock.read().wall)
    #expect(session.principal.grantID == grant.selector.grantID)
}
