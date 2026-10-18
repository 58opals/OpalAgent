import AgentValues
import AgentNativeIPC
import AgentClient
import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

private final class NativeOwnerTestClock: PaymentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Int64 = 1_000
    func read() -> PaymentClockReading { lock.withLock { .init(wall: wall, monotonic: UInt64(wall)) } }
    func advance(_ value: Int64) { lock.withLock { wall += value } }
}
private final class NativeOwnerTestAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuityAnchor?
    func read() throws -> ContinuityAnchor? { lock.withLock { value } }
    func write(_ value: ContinuityAnchor) throws { lock.withLock { self.value = value } }
}
private actor NativeConsentPause {
    var armed = false
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func arm() { armed = true }
    func waitIfArmed() async {
        guard armed else { return }; armed = false; entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func hasEntered() -> Bool { entered }
}
private final class NativeOwnerTestConsent: OwnerConsentProvider, NativeWalletConsentProvider, @unchecked Sendable {
    let clock: NativeOwnerTestClock
    let pause = NativeConsentPause()
    private let lock = NSLock()
    private var purposes: [OwnerControlMethod] = []
    private var commitments: [Data] = []
    init(_ clock: NativeOwnerTestClock) { self.clock = clock }
    var observedPurposes: [OwnerControlMethod] { lock.withLock { purposes } }
    var observedCommitments: [Data] { lock.withLock { commitments } }
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        let id = UUID()
        let expected = NativeConsentChallenge(connectionID: challenge.connectionID, nonce: challenge.nonce,
            purpose: challenge.purpose.rawValue, reviewCommitment: challenge.reviewCommitment)
        let request = try NativeWire.frame(expected, kind: .consentChallenge, requestID: id)
        let parsed = try NativeWire.unpack(request, kind: .consentChallenge, requestID: id)
        let proof = try await authenticate(NativeWire.decode(NativeConsentChallenge.self, from: parsed.payload))
        let response = try NativeWire.frame(proof, kind: .consentProof, requestID: id)
        let frame = try NativeWire.unpack(response, kind: .consentProof, requestID: id)
        let received = try NativeWire.decode(NativeConsentProof.self, from: frame.payload)
        guard received.challenge == expected else { throw NativeIPCFailure.untrustedPeer }
        return OwnerConsentProof(challenge: challenge, authenticatedAt: received.authenticatedAt)
    }
    func authenticate(_ challenge: NativeConsentChallenge) async throws -> NativeConsentProof {
        guard let purpose = OwnerControlMethod(rawValue: challenge.purpose) else { throw NativeIPCFailure.malformedFrame }
        lock.withLock { purposes.append(purpose); commitments.append(challenge.reviewCommitment) }
        if purpose == .approveExactPayment { await pause.waitIfArmed() }
        return NativeConsentProof(challenge: challenge, authenticatedAt: clock.read().wall)
    }
}
private final class NativeOwnerTestSeeds: SeedAccountProvider, @unchecked Sendable {
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
private final class NativeOwnerTestBoundary: AccountChainBoundary, PaymentExecutionBoundary, @unchecked Sendable {
    let clock: NativeOwnerTestClock
    private let lock = NSLock()
    private var relays = 0
    private var addresses = 0
    init(_ clock: NativeOwnerTestClock) { self.clock = clock }
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
private final class NativeOwnerTestAuthorityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ServiceAuthority?
    func get(_ continuity: ContinuityCoordinator, _ policy: AuthorityPolicy) throws -> ServiceAuthority {
        try lock.withLock {
            if let value { return value }
            let value = try ServiceAuthority(continuity: continuity, policy: policy); self.value = value; return value
        }
    }
}
private struct NativeOwnerEndpointTransport: OwnerControlTransport {
    let service: OwnerControlService
    let connection: OwnerConnectionContext
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        let id = UUID()
        let packet = try NativeWire.ownerRequest(request, requestID: id)
        let response = await NativeServiceFrames.owner(packet, service: service, context: connection)
        return try NativeWire.decodeOwnerResponse(response, requestID: id, method: request.call.method)
    }
}
private final class NativeOwnerEndpointFixture: @unchecked Sendable {
    let directory: URL
    let journal: SQLiteJournal
    let continuity: ContinuityCoordinator
    let anchor = NativeOwnerTestAnchor()
    let policy: AuthorityPolicy
    let clock = NativeOwnerTestClock()
    let consent: NativeOwnerTestConsent
    let seeds = NativeOwnerTestSeeds()
    let boundary: NativeOwnerTestBoundary
    let engine: PaymentEngine
    let vault: WalletSeedVault
    let service: OwnerControlService
    let connection: OwnerConnectionContext
    let authorities = NativeOwnerTestAuthorityBox()
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owner-endpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
        continuity = ContinuityCoordinator(database: journal, anchor: anchor)
        let owner = SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "owner")
        policy = AuthorityPolicy(bridge: .init(teamIdentifier: "synthetic", signingIdentifier: "bridge"), owner: owner,
            accountIDs: ["owner-account"], capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"], ownerAuthenticationAge: 30)
        connection = OwnerConnectionContext(connectionID: "owner-connection", peer: .init(identity: owner, signatureValidated: true))
        consent = NativeOwnerTestConsent(clock); boundary = NativeOwnerTestBoundary(clock)
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
        try await OwnerControlClient(transport: NativeOwnerEndpointTransport(service: service, connection: connection)).call(call)
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
            if try continuity.inspect({ $0.payments.first(where: { $0.id == id })?.disposition }) == .prepared {
                return try OperationSelector(account: account, operationID: id)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw PaymentFailure.unavailable
    }
}

// This is codec/public-client/actual service composition with synthetic peer and consent evidence.
// It does not claim signed NSXPC admission, installed-service, or trusted human UI proof.
@Test(arguments: ["policy", "origin"])
func nativeOwnerSuspendedExactConsentRejectsChangedAuthorityWithoutEffect(_ change: String) async throws {
    let f = try NativeOwnerEndpointFixture(); defer { f.remove() }
    let (wallet, account) = try await f.createEnabled()
    let issued = try await f.enroll(wallet)
    let authority = try f.authorities.get(f.continuity, f.policy)
    let peer = PeerEvidence(identity: f.policy.bridge, signatureValidated: true)
    let session = try authority.authenticate(connectionID: "bridge", peer: peer,
        credential: issued.credential.withBytes { $0 }, now: f.clock.read().wall)
    _ = try await f.call(.setApprovalPolicy(.init(wallet: wallet, expectedRevision: 1, approvalRequired: true)))
    let selector = try await f.prepare(account, session: session, key: String(repeating: "a", count: 32))
    _ = try await f.engine.submit(operationID: selector.operationID, session: session, connectionID: "bridge", peer: peer)
    guard case .reviewPreview(let reviewed) = try await f.call(.reviewPreview(selector)) else { throw NativeIPCFailure.malformedFrame }
    #expect(try NativeWire.reviewCommitment(.approveExactPayment(reviewed)).count == 32)
    await f.consent.pause.arm()
    let pending = Task { try await f.call(.approveExactPayment(reviewed)) }
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await f.consent.pause.hasEntered()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    guard await f.consent.pause.hasEntered() else {
        pending.cancel(); await f.consent.pause.release(); throw NativeIPCFailure.unavailable
    }
    if change == "policy" {
        _ = try await f.call(.setApprovalPolicy(.init(wallet: wallet, expectedRevision: 2, approvalRequired: false)))
    } else {
        _ = try await f.call(.rotateGrant(issued.grant.selector))
    }
    let before = try f.continuity.inspect { $0 }
    if change == "origin" {
        let invalidated = try #require(before.payments.first { $0.id == selector.operationID })
        #expect(invalidated.disposition == .invalidated && invalidated.terminalReason == "authorizationInvalidated")
        #expect(invalidated.attempts.isEmpty && before.approvals.allSatisfy { $0.paymentID != selector.operationID || !$0.active })
    }
    let positions = f.consent.observedPurposes.enumerated().filter { $0.element == .approveExactPayment }.map(\.offset)
    #expect(positions.count == 1)
    #expect(try positions.map { f.consent.observedCommitments[$0] } == [NativeWire.reviewCommitment(.approveExactPayment(reviewed))])
    await f.consent.pause.release()
    let expected = ServiceProblem(change == "policy" ? .staleContext : .invalidTransition)
    await #expect(throws: expected) { try await pending.value }
    let after = try f.continuity.inspect { $0 }
    #expect(try after.reference() == before.reference())
    #expect(after.payments == before.payments && after.approvals == before.approvals)
    #expect(after.payments.first { $0.id == selector.operationID }?.attempts.isEmpty == true)
    #expect(f.boundary.relayCount == 0)
    #expect(f.consent.observedPurposes.contains(.approveExactPayment))
}

@Test func nativeOwnerMetadataUsesNoConsentAndInvalidatedConnectionDisclosesNoSeed() async throws {
    let f = try NativeOwnerEndpointFixture(); defer { f.remove() }
    let (wallet, _) = try await f.createEnabled()
    let count = f.consent.observedPurposes.count
    guard case .status(let status) = try await f.call(.status) else { throw NativeIPCFailure.malformedFrame }
    #expect(status.custody == .presentUnverified && f.consent.observedPurposes.count == count)
    let before = try f.continuity.inspect { try $0.reference() }
    f.connection.invalidate()
    await #expect(throws: ServiceProblem(.unavailable)) { try await f.call(.exportRecoveryMaterial(wallet)) }
    #expect(f.consent.observedPurposes.count == count)
    #expect(try f.continuity.inspect { try $0.reference() } == before)
}
