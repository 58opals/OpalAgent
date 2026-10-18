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
    let context: CapabilityConnectionContext?
    let client: CapabilityClient
    let ownerClient: OwnerControlClient
    let account: AccountScope
    let trace: FixtureTrace?
    let syntheticCredential: Data
    let ownerService: OwnerControlService
    let ownerConnection: OwnerConnectionContext
    private let ownerEvidence: OwnerAuthenticationEvidence

    private init(directory: URL, scenario: FixtureScenario, store: DurableWalletStore, policy: AuthorityPolicy,
                 vault: WalletSeedVault, keys: FixtureKeys, custody: WalletCustodyRecord, chain: FixturePublicChain,
                 clock: FixtureClock, payments: PaymentEngine, receives: ReceiveEngine, service: CapabilityService,
                 context: CapabilityConnectionContext?, client: CapabilityClient, ownerClient: OwnerControlClient,
                 account: AccountScope, trace: FixtureTrace?, ownerEvidence: OwnerAuthenticationEvidence,
                 syntheticCredential: Data, ownerService: OwnerControlService, ownerConnection: OwnerConnectionContext) {
        self.directory = directory; self.scenario = scenario; self.store = store; self.policy = policy
        self.vault = vault; self.keys = keys; self.custody = custody; self.chain = chain; self.clock = clock
        self.payments = payments; self.receives = receives; self.service = service; self.context = context
        self.client = client; self.ownerClient = ownerClient; self.account = account; self.trace = trace
        self.ownerEvidence = ownerEvidence
        self.syntheticCredential = syntheticCredential; self.ownerService = ownerService; self.ownerConnection = ownerConnection
    }

    static func make(directory: URL, scenario: FixtureScenario, tracePath: URL? = nil) async throws -> FixtureRuntime {
        try createFreshTemporaryDirectory(directory)
        return try await assemble(directory: directory, scenario: scenario, tracePath: tracePath)
    }

    /// Only the capability-checked process fixture can take this path. Normal make/CLI
    /// remain fresh-only. Resume performs no initial write, enrollment or generation reset.
    static func owned(_ ownership: FixtureProcessOwnership, resume: Bool, credential: Data?,
                      consent: any OwnerConsentProvider, clock: FixtureClock,
                      phases: FixturePhaseController) async throws -> FixtureRuntime {
        try ownership.prepare(resume: resume)
        return try await assemble(directory: ownership.directory, scenario: .uncertain,
            retainedCredential: credential, ownership: resume ? ownership : nil, consent: consent, clock: clock, phases: phases)
    }

    private static func assemble(directory: URL, scenario: FixtureScenario, tracePath: URL? = nil,
                                 retainedCredential: Data? = nil, ownership: FixtureProcessOwnership? = nil,
                                 consent: (any OwnerConsentProvider)? = nil, clock providedClock: FixtureClock? = nil,
                                 phases: FixturePhaseController? = nil) async throws -> FixtureRuntime {
        let trace = try tracePath.map { try FixtureTrace(path: $0, directory: directory) }
        // Published, permanently disposable test vector. Never fund or treat this as real custody.
        let mnemonic = Data("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8)
        let keys = FixtureKeys()
        let vault = WalletSeedVault(keys: InjectedWrappingKeySource(read: { keys.read() }), accounts: BaseSeedAccountProvider())
        let clock = providedClock ?? FixtureClock()
        let bridge = SignedPeerIdentity(teamIdentifier: "synthetic-protocol-fixture", signingIdentifier: "integration")
        let owner = SignedPeerIdentity(teamIdentifier: "synthetic-protocol-fixture", signingIdentifier: "owner")
        let anchor = FixtureAnchor(directory.appendingPathComponent("independent-anchor.json"))
        let policyFor: (String) -> AuthorityPolicy = { accountID in
            AuthorityPolicy(bridge: bridge, owner: owner, accountIDs: [accountID],
                capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"], ownerAuthenticationAge: 30)
        }
        let custody: WalletCustodyRecord
        let store: DurableWalletStore
        let policy: AuthorityPolicy
        if let ownership {
            let manifest = try ownership.storeManifest()
            policy = policyFor(manifest.accountID)
            // Acquire actual writer exclusion/startup before any SQLite read/configuration.
            store = try DurableWalletStore(directory: directory, anchor: anchor, policy: policy)
            guard let retained = try store.continuity.inspectRecoveryState() else { throw FixtureFailure.fixtureUnavailable }
            guard let value = retained.custody,
                  retained.installationID == manifest.installationID,
                  value.walletID == manifest.walletID, value.accountID == manifest.accountID,
                  value.profile == manifest.profile, value.network == "mainnet" else { throw FixtureFailure.fixtureUnavailable }
            custody = value
        } else {
            custody = try await vault.protect(mnemonic: mnemonic, walletID: "protocol-fixture-wallet", network: "mainnet")
            let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
            var state = CanonicalState(installationID: "protocol-fixture-installation",
                authorization: .init(walletID: custody.walletID, network: custody.network, generation: 1, grants: []),
                mode: .enabled, history: .complete)
            state.custody = custody
            state.paymentPolicy.approvalRequired = scenario == .approvalRequired
            try journal.write(state)
            try anchor.write(.init(committed: state.reference()))
            policy = policyFor(custody.accountID)
            store = try DurableWalletStore(directory: directory, anchor: anchor, policy: policy)
        }
        var resumedContext: CapabilityConnectionContext?
        if ownership != nil {
            guard let retainedCredential, retainedCredential.count == 32, let consent else { throw FixtureFailure.invalidArguments }
            let trusted = try? store.continuity.inspect { $0 }
            let peer = PeerEvidence(identity: bridge, signatureValidated: true)
            let connectionID = "protocol-fixture-connection-" + UUID().uuidString
            let session = trusted?.mode == .enabled ? (try? store.integrationAuthority().authenticate(connectionID: connectionID, peer: peer,
                credential: retainedCredential, now: clock.read().wall)) : nil
            guard let session else {
                return try ownerOnly(directory: directory, scenario: scenario, store: store, policy: policy,
                    custody: custody, vault: vault, keys: keys, credential: retainedCredential, clock: clock, consent: consent)
            }
            resumedContext = CapabilityConnectionContext(session: session, connectionID: connectionID, peer: peer)
        }
        // Writer/startup and exact anchor validation precede reopening the disposable key.
        _ = try store.continuity.inspect { state in
            guard state.custody == custody else { throw FixtureFailure.fixtureUnavailable }
        }
        let baseAccount: OpalBase.Account
        if ownership == nil { baseAccount = try await BaseSeedAccountProvider().restoreSigningAccount(custody: custody, vault: vault) }
        else { baseAccount = try await BaseSeedAccountProvider().restorePublicAccount(custody: custody) }
        let chain = FixturePublicChain(clock: clock)
        chain.setAccepted(scenario != .uncertain)
        let receiving = try await baseAccount.selectNextDerivedAddress(for: .receiving)
        let funding = try OpalBase.Transaction(version: 2,
            inputs: [.init(previousTransactionHash: .init(naturalOrder: Data(repeating: 0, count: 32)),
                previousTransactionOutputIndex: UInt32.max, unlockingScript: Data([0xA1]))],
            outputs: [.init(value: 50_000, address: receiving.address)], lockTime: 0).encode()
        if scenario != .missingSnapshot { try chain.publish(funding, height: 1) }
        let adapter = try await BaseBCHAdapter(account: baseAccount, custody: custody, vault: vault, continuity: store.continuity,
            chain: chain.operations(), clock: clock, context: { chain.context() },
            canonicalProof: { hash, height, context in chain.proof(hash: hash, height: height, context: context) })
        let boundary: any PaymentExecutionBoundary
        if let phases { boundary = FixturePhaseBoundary(base: adapter, phases: phases) } else { boundary = adapter }
        let payments = try store.paymentEngine(boundary: boundary, clock: clock)
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
        let credential: Data
        if let retainedCredential {
            guard ownership != nil, retainedCredential.count == 32 else { throw FixtureFailure.invalidArguments }
            credential = retainedCredential
        } else {
            guard ownership == nil else { throw FixtureFailure.invalidArguments }
            credential = try authority.enroll(id: "protocol-fixture-grant", integrationID: "protocol-fixture-integration",
                accounts: [custody.accountID], capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"],
                expiry: nil, owner: ownerEvidence, now: clock.read().wall).rawValue
        }
        let context: CapabilityConnectionContext
        if let resumedContext { context = resumedContext }
        else {
            let connectionID = "protocol-fixture-connection-" + UUID().uuidString
            let session = try authority.authenticate(connectionID: connectionID, peer: peer,
                credential: credential, now: clock.read().wall)
            context = CapabilityConnectionContext(session: session, connectionID: connectionID, peer: peer)
        }
        let client = CapabilityClient(transport: FixtureCapabilityTransport(service: service, context: context, chain: chain, trace: trace))
        let ownerService = OwnerControlService(continuity: store.continuity, policy: policy,
            authority: { try store.integrationAuthority() }, vault: vault, accounts: adapter, payments: payments,
            consent: consent ?? FixtureConsent(clock: clock), clock: clock)
        let ownerConnection = OwnerConnectionContext(connectionID: UUID().uuidString, peer: ownerPeer)
        let ownerClient = OwnerControlClient(transport: FixtureOwnerTransport(service: ownerService, connection: ownerConnection))
        let scope = try AccountScope(wallet: WalletScope(walletID: custody.walletID, network: .mainnet), accountID: custody.accountID)
        try trace?.emit(event: "fixture-ready", relayCount: chain.counts.relays)
        return FixtureRuntime(directory: directory, scenario: scenario, store: store, policy: policy, vault: vault, keys: keys,
            custody: custody, chain: chain, clock: clock, payments: payments, receives: receives, service: service,
            context: context, client: client, ownerClient: ownerClient, account: scope, trace: trace, ownerEvidence: ownerEvidence,
            syntheticCredential: credential, ownerService: ownerService, ownerConnection: ownerConnection)
    }

    func state() throws -> CanonicalState { try store.continuity.inspect { $0 } }
    func reference() throws -> StateReference { try store.continuity.inspect { try $0.reference() } }
    func integrationClient(credential: Data) throws -> CapabilityClient {
        guard credential.count == 32 else { throw FixtureFailure.invalidArguments }
        let peer = PeerEvidence(identity: policy.bridge, signatureValidated: true)
        let connectionID = "protocol-fixture-connection-" + UUID().uuidString
        let session = try store.integrationAuthority().authenticate(connectionID: connectionID,
            peer: peer, credential: credential, now: clock.read().wall)
        let context = CapabilityConnectionContext(session: session, connectionID: connectionID, peer: peer)
        return CapabilityClient(transport: FixtureCapabilityTransport(service: service,
            context: context, chain: chain, trace: trace))
    }
    func foreignClient() throws -> CapabilityClient {
        guard let context else { throw FixtureFailure.fixtureUnavailable }
        let authority = try store.integrationAuthority()
        let credential = try authority.enroll(id: "foreign-fixture-grant", integrationID: "foreign-fixture-integration",
            accounts: [custody.accountID], capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"],
            expiry: nil, owner: ownerEvidence, now: clock.read().wall)
        let session = try authority.authenticate(connectionID: "foreign-fixture-connection", peer: context.peer,
            credential: credential.rawValue, now: clock.read().wall)
        return CapabilityClient(transport: FixtureCapabilityTransport(service: service,
            context: .init(session: session, connectionID: "foreign-fixture-connection", peer: context.peer), chain: chain, trace: trace))
    }
    private static func ownerOnly(directory: URL, scenario: FixtureScenario, store: DurableWalletStore,
                                  policy: AuthorityPolicy, custody: WalletCustodyRecord, vault: WalletSeedVault,
                                  keys: FixtureKeys, credential: Data, clock: FixtureClock,
                                  consent: any OwnerConsentProvider) throws -> FixtureRuntime {
        let boundary = FixtureUnavailableBoundary()
        let payments = PaymentEngine(continuity: store.continuity, authorityPolicy: policy, boundary: boundary, clock: clock)
        let receives = ReceiveEngine(continuity: store.continuity, policy: policy, boundary: boundary, clock: clock)
        let service = CapabilityService(continuity: store.continuity, policy: policy, payments: payments, receives: receives,
            clock: clock, availability: { _ in .unavailable })
        let peer = PeerEvidence(identity: policy.owner, signatureValidated: true)
        let ownerEvidence = OwnerAuthenticationEvidence(peer: peer, authenticationSucceeded: true, authenticatedAt: clock.read().wall)
        let ownerService = OwnerControlService(continuity: store.continuity, policy: policy,
            authority: { try store.integrationAuthority() }, vault: vault, accounts: boundary,
            payments: payments, consent: consent, clock: clock)
        let ownerConnection = OwnerConnectionContext(connectionID: UUID().uuidString, peer: peer)
        let scope = try AccountScope(wallet: WalletScope(walletID: custody.walletID, network: .mainnet), accountID: custody.accountID)
        return FixtureRuntime(directory: directory, scenario: scenario, store: store, policy: policy, vault: vault, keys: keys,
            custody: custody, chain: FixturePublicChain(clock: clock), clock: clock, payments: payments, receives: receives,
            service: service, context: nil, client: CapabilityClient(),
            ownerClient: OwnerControlClient(transport: FixtureOwnerTransport(service: ownerService, connection: ownerConnection)),
            account: scope, trace: nil, ownerEvidence: ownerEvidence, syntheticCredential: credential,
            ownerService: ownerService, ownerConnection: ownerConnection)
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
