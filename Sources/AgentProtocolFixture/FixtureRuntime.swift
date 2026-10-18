#if DEBUG
import AgentClient
import AgentValues
import CryptoKit
import Darwin
import Foundation
import OpalBaseCore
@testable import AgentServiceCore

enum FixtureFailure: Error, Equatable { case invalidArguments, fixtureUnavailable }
enum FixtureScenario: String, CaseIterable, Sendable {
    case autonomous
    case approvalRequired = "approval-required"
    case missingSnapshot = "missing-snapshot"
    case uncertain
}

/// This trace admits fixed summaries only. It never records input/output payloads or custody material.
final class FixtureTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private struct Event: Encodable {
        let event: String
        let method: String?
        let status: String?
        let relayCount: Int
    }
    init(path: URL, directory: URL) throws {
        guard path.isFileURL,
              path.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw FixtureFailure.invalidArguments
        }
        let descriptor = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw FixtureFailure.invalidArguments }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    func emit(event: String, method: CapabilityMethod? = nil, status: String? = nil, relayCount: Int) throws {
        try lock.withLock {
            guard ["fixture-ready", "capability-call", "fixture-stop"].contains(event),
                  status.map({ ["succeeded", "rejected"].contains($0) }) ?? true else { throw FixtureFailure.fixtureUnavailable }
            var data = try JSONEncoder().encode(Event(event: event, method: method?.rawValue, status: status, relayCount: relayCount))
            data.append(10)
            try file.write(contentsOf: data)
        }
    }
}

private struct FixtureCapabilityTransport: CapabilityTransport {
    let service: CapabilityService
    let context: CapabilityConnectionContext
    let chain: FixturePublicChain
    let trace: FixtureTrace?
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        do {
            let result = try await service.handle(request, context: context)
            try trace?.emit(event: "capability-call", method: request.call.method, status: "succeeded", relayCount: chain.counts.relays)
            return result
        } catch {
            try trace?.emit(event: "capability-call", method: request.call.method, status: "rejected", relayCount: chain.counts.relays)
            throw error
        }
    }
}
private struct FixtureConsent: OwnerConsentProvider {
    let clock: FixtureClock
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        .init(challenge: challenge, authenticatedAt: clock.read().wall)
    }
}
private struct FixtureOwnerTransport: OwnerControlTransport {
    let service: OwnerControlService
    let connection: OwnerConnectionContext
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        try await service.send(request, connection: connection)
    }
}

/// NONSHIPPING composition of actual service owners and public Base APIs. Every external
/// custody/peer/chain/relay fact is explicitly synthetic and owned by this development target.
final class FixtureRuntime: @unchecked Sendable {
    static let destination = "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
    let directory: URL
    let scenario: FixtureScenario
    let store: DurableWalletStore
    let policy: AuthorityPolicy
    let vault: WalletSeedVault
    let keys: FixtureKeys
    let custody: WalletCustodyRecord
    let chain: FixturePublicChain
    let clock: FixtureClock
    let payments: PaymentEngine
    let receives: ReceiveEngine
    let service: CapabilityService
    let context: CapabilityConnectionContext
    let client: CapabilityClient
    let ownerClient: OwnerControlClient
    let account: AccountScope
    let trace: FixtureTrace?
    private let ownerEvidence: OwnerAuthenticationEvidence

    private init(directory: URL, scenario: FixtureScenario, store: DurableWalletStore, policy: AuthorityPolicy,
                 vault: WalletSeedVault, keys: FixtureKeys, custody: WalletCustodyRecord, chain: FixturePublicChain,
                 clock: FixtureClock, payments: PaymentEngine, receives: ReceiveEngine, service: CapabilityService,
                 context: CapabilityConnectionContext, client: CapabilityClient, ownerClient: OwnerControlClient,
                 account: AccountScope, trace: FixtureTrace?, ownerEvidence: OwnerAuthenticationEvidence) {
        self.directory = directory; self.scenario = scenario; self.store = store; self.policy = policy
        self.vault = vault; self.keys = keys; self.custody = custody; self.chain = chain; self.clock = clock
        self.payments = payments; self.receives = receives; self.service = service; self.context = context
        self.client = client; self.ownerClient = ownerClient; self.account = account; self.trace = trace
        self.ownerEvidence = ownerEvidence
    }

    static func make(directory: URL, scenario: FixtureScenario, tracePath: URL? = nil) async throws -> FixtureRuntime {
        try createFreshTemporaryDirectory(directory)
        let trace = try tracePath.map { try FixtureTrace(path: $0, directory: directory) }
        // Published, permanently disposable test vector. Never fund or treat this as real custody.
        let mnemonic = Data("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8)
        let keys = FixtureKeys()
        let vault = WalletSeedVault(keys: InjectedWrappingKeySource(read: { keys.read() }), accounts: BaseSeedAccountProvider())
        let custody = try await vault.protect(mnemonic: mnemonic, walletID: "protocol-fixture-wallet", network: "mainnet")
        let baseAccount = try await BaseSeedAccountProvider().restoreSigningAccount(custody: custody, vault: vault)
        let clock = FixtureClock()
        let chain = FixturePublicChain(clock: clock)
        chain.setAccepted(scenario != .uncertain)
        let receiving = try await baseAccount.selectNextDerivedAddress(for: .receiving)
        let funding = try OpalBase.Transaction(version: 2,
            inputs: [.init(previousTransactionHash: .init(naturalOrder: Data(repeating: 0, count: 32)),
                previousTransactionOutputIndex: UInt32.max, unlockingScript: Data([0xA1]))],
            outputs: [.init(value: 50_000, address: receiving.address)], lockTime: 0).encode()
        if scenario != .missingSnapshot { try chain.publish(funding, height: 1) }
        let bridge = SignedPeerIdentity(teamIdentifier: "synthetic-protocol-fixture", signingIdentifier: "integration")
        let owner = SignedPeerIdentity(teamIdentifier: "synthetic-protocol-fixture", signingIdentifier: "owner")
        let policy = AuthorityPolicy(bridge: bridge, owner: owner, accountIDs: [custody.accountID],
            capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"], ownerAuthenticationAge: 30)
        let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
        let anchor = FixtureAnchor(directory.appendingPathComponent("independent-anchor.json"))
        var state = CanonicalState(installationID: "protocol-fixture-installation",
            authorization: .init(walletID: custody.walletID, network: custody.network, generation: 1, grants: []),
            mode: .enabled, history: .complete)
        state.custody = custody
        state.paymentPolicy.approvalRequired = scenario == .approvalRequired
        try journal.write(state)
        try anchor.write(.init(committed: state.reference()))
        let store = try DurableWalletStore(directory: directory, anchor: anchor, policy: policy)
        let adapter = try await BaseBCHAdapter(account: baseAccount, custody: custody, vault: vault, continuity: store.continuity,
            chain: chain.operations(), clock: clock, context: { chain.context() },
            canonicalProof: { hash, height, context in chain.proof(hash: hash, height: height, context: context) })
        let payments = try store.paymentEngine(boundary: adapter, clock: clock)
        let receives = try store.receiveEngine(boundary: adapter, clock: clock)
        let service = CapabilityService(continuity: store.continuity, policy: policy, payments: payments, receives: receives,
            clock: clock, availability: { _ in
                let context = chain.context()
                if !keys.isPresent { return AccountReadiness(state: .blocked, blockers: [.keyUnavailable]) }
                if !context.fresh || !context.complete { return AccountReadiness(state: .blocked, blockers: [.staleSnapshot]) }
                return AccountReadiness(state: .ready)
            })
        let peer = PeerEvidence(identity: bridge, signatureValidated: true)
        let ownerPeer = PeerEvidence(identity: owner, signatureValidated: true)
        let ownerEvidence = OwnerAuthenticationEvidence(peer: ownerPeer, authenticationSucceeded: true, authenticatedAt: clock.read().wall)
        let authority = try store.integrationAuthority()
        let credential = try authority.enroll(id: "protocol-fixture-grant", integrationID: "protocol-fixture-integration",
            accounts: [custody.accountID], capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"],
            expiry: nil, owner: ownerEvidence, now: clock.read().wall)
        let session = try authority.authenticate(connectionID: "protocol-fixture-connection", peer: peer,
            credential: credential.rawValue, now: clock.read().wall)
        let context = CapabilityConnectionContext(session: session, connectionID: "protocol-fixture-connection", peer: peer)
        let client = CapabilityClient(transport: FixtureCapabilityTransport(service: service, context: context, chain: chain, trace: trace))
        let ownerService = OwnerControlService(continuity: store.continuity, policy: policy,
            authority: { try store.integrationAuthority() }, vault: vault, accounts: adapter, payments: payments,
            consent: FixtureConsent(clock: clock), clock: clock)
        let ownerClient = OwnerControlClient(transport: FixtureOwnerTransport(service: ownerService,
            connection: OwnerConnectionContext(connectionID: "protocol-fixture-owner", peer: ownerPeer)))
        let scope = try AccountScope(wallet: WalletScope(walletID: custody.walletID, network: .mainnet), accountID: custody.accountID)
        try trace?.emit(event: "fixture-ready", relayCount: chain.counts.relays)
        return FixtureRuntime(directory: directory, scenario: scenario, store: store, policy: policy, vault: vault, keys: keys,
            custody: custody, chain: chain, clock: clock, payments: payments, receives: receives, service: service,
            context: context, client: client, ownerClient: ownerClient, account: scope, trace: trace, ownerEvidence: ownerEvidence)
    }

    func state() throws -> CanonicalState { try store.continuity.inspect { $0 } }
    func reference() throws -> StateReference { try store.continuity.inspect { try $0.reference() } }
    func foreignClient() throws -> CapabilityClient {
        let authority = try store.integrationAuthority()
        let credential = try authority.enroll(id: "foreign-fixture-grant", integrationID: "foreign-fixture-integration",
            accounts: [custody.accountID], capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"],
            expiry: nil, owner: ownerEvidence, now: clock.read().wall)
        let session = try authority.authenticate(connectionID: "foreign-fixture-connection", peer: context.peer,
            credential: credential.rawValue, now: clock.read().wall)
        return CapabilityClient(transport: FixtureCapabilityTransport(service: service,
            context: .init(session: session, connectionID: "foreign-fixture-connection", peer: context.peer), chain: chain, trace: trace))
    }
    func shutdown() async {
        await chain.relayLatch.open()
        await payments.cancelLocalTransport()
        try? trace?.emit(event: "fixture-stop", relayCount: chain.counts.relays)
    }

    private static func createFreshTemporaryDirectory(_ directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw FixtureFailure.invalidArguments }
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let roots = [URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path,
                     FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path]
        guard roots.contains(where: { parent == $0 || parent.hasPrefix($0 + "/") }),
              Darwin.mkdir(directory.path, 0o700) == 0 else { throw FixtureFailure.invalidArguments }
    }
}
#endif
