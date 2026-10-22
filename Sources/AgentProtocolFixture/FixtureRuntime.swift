#if DEBUG
import AgentClient
import AgentValues
import AgentNativeIPC
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
            guard ["fixture-ready", "capability-call", "fixture-stop", "stdio-output-send-failed"].contains(event),
                  status.map({ ["succeeded", "rejected"].contains($0) }) ?? true else { throw FixtureFailure.fixtureUnavailable }
            var data = try JSONEncoder().encode(Event(event: event, method: method?.rawValue, status: status, relayCount: relayCount))
            data.append(10)
            try file.write(contentsOf: data)
        }
    }
}

/// NONSHIPPING actual service assembly with synthetic custody items, peers, listeners and public chain.
final class FixtureRuntime: @unchecked Sendable {
    static let destination = "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
    let directory: URL
    let scenario: FixtureScenario
    let policy: AuthorityPolicy
    let keys: FixtureKeychainOperations
    let custody: WalletCustodyRecord
    let chain: FixturePublicChain
    let clock: FixtureClock
    let client: CapabilityClient
    let primarySession: FixtureClientSession?
    let ownerClient: OwnerControlClient
    let account: AccountScope
    let trace: FixtureTrace?
    let syntheticCredential: Data
    let grant: GrantSelector
    var grantID: String { grant.grantID }
    let integrationAvailable: Bool
    let recoveryOnly: Bool
    let inspection: FixtureInspection
    private let assembly: ServiceAssembly?
    private let endpoints: FixtureEndpointRegistry
    private let ownerSession: FixtureOwnerSession?
    private let recovery: FixtureRecoveryRuntime?
    private let phases: FixturePhaseController?
    private let stopLock = NSLock()
    private var stopTask: Task<Void, Never>?

    private init(directory: URL, scenario: FixtureScenario, policy: AuthorityPolicy, keys: FixtureKeychainOperations,
                 custody: WalletCustodyRecord, chain: FixturePublicChain, clock: FixtureClock,
                 session: FixtureClientSession?, ownerSession: FixtureOwnerSession?, recovery: FixtureRecoveryRuntime? = nil,
                 account: AccountScope, trace: FixtureTrace?, credential: Data, grant: GrantSelector,
                 assembly: ServiceAssembly?, endpoints: FixtureEndpointRegistry, inspection: FixtureInspection,
                 phases: FixturePhaseController?) {
        self.directory = directory; self.scenario = scenario; self.policy = policy; self.keys = keys
        self.custody = custody; self.chain = chain; self.clock = clock; self.account = account; self.trace = trace
        self.syntheticCredential = credential; self.grant = grant; self.assembly = assembly; self.endpoints = endpoints
        self.inspection = inspection; self.ownerSession = ownerSession; self.recovery = recovery; self.phases = phases
        self.integrationAvailable = session != nil; self.recoveryOnly = recovery != nil
        self.primarySession = session
        self.client = session?.client ?? CapabilityClient()
        if let ownerSession { self.ownerClient = OwnerControlClient(transport: ownerSession) }
        else if let recovery { self.ownerClient = OwnerControlClient(transport: recovery) }
        else { self.ownerClient = OwnerControlClient() }
    }

    static func make(directory: URL, scenario: FixtureScenario, tracePath: URL? = nil) async throws -> FixtureRuntime {
        try createFreshTemporaryDirectory(directory)
        return try await assemble(directory: directory.appendingPathComponent("state", isDirectory: true),
            itemsPath: directory.appendingPathComponent("synthetic-keychain.json"),
            group: "synthetic.protocol-fixture." + UUID().uuidString, scenario: scenario, tracePath: tracePath,
            traceDirectory: directory)
    }

    /// Resume never creates a directory, custody item, wallet or grant. Recovery is a separately selected owner-only composition.
    static func owned(_ ownership: FixtureProcessOwnership, resume: Bool, credential: Data?,
                      consent: any OwnerConsentProvider, clock: FixtureClock, phases: FixturePhaseController,
                      recoveryOnly: Bool = false,
                      beforeStart: (@Sendable (FixturePublicChain, FixtureInspection) throws -> Void)? = nil) async throws -> FixtureRuntime {
        try ownership.prepare(resume: resume)
        guard !recoveryOnly || resume else { throw FixtureFailure.invalidArguments }
        return try await assemble(directory: ownership.directory,
            itemsPath: ownership.namespace.appendingPathComponent("synthetic-keychain.json"),
            group: "synthetic.protocol-fixture." + ownership.runID.uuidString,
            scenario: .uncertain, resume: resume, credential: credential, consent: consent,
            clock: clock, phases: phases, recoveryOnly: recoveryOnly, beforeStart: beforeStart,
            manifest: resume ? ownership.storeManifest() : nil)
    }

    private static func assemble(directory: URL, itemsPath: URL, group: String, scenario: FixtureScenario,
                                 tracePath: URL? = nil, traceDirectory: URL? = nil, resume: Bool = false,
                                 credential retainedCredential: Data? = nil, consent: (any OwnerConsentProvider)? = nil,
                                 clock providedClock: FixtureClock? = nil, phases: FixturePhaseController? = nil,
                                 recoveryOnly: Bool = false,
                                 beforeStart: (@Sendable (FixturePublicChain, FixtureInspection) throws -> Void)? = nil,
                                 manifest: FixtureStoreManifest? = nil) async throws -> FixtureRuntime {
        let trace = try tracePath.map { try FixtureTrace(path: $0, directory: traceDirectory ?? directory) }
        let clock = providedClock ?? FixtureClock()
        let accounts = FixtureSeedAccountProvider()
        let accountID: String
        if resume {
            guard let manifest else { throw FixtureFailure.invalidArguments }
            accountID = manifest.accountID
        } else {
            accountID = try await accounts.deriveAccount(mnemonic: FixtureSeedAccountProvider.mnemonic, network: "mainnet").accountID
        }
        let policy = AuthorityPolicy(
            bridge: SignedPeerIdentity(teamIdentifier: "synthetic-protocol-fixture", signingIdentifier: "integration"),
            owner: SignedPeerIdentity(teamIdentifier: "synthetic-protocol-fixture", signingIdentifier: "owner"),
            accountIDs: [accountID], capabilities: ["read", "sync", "receive", "prepare", "submit", "cancel"],
            ownerAuthenticationAge: 30)
        let keys = try FixtureKeychainOperations(path: itemsPath, group: group, resume: resume)
        let chain = FixturePublicChain(clock: clock)
        chain.setAccepted(scenario != .uncertain)
        // Process fixtures install their independent oracle before reopen can schedule continuation.
        if phases != nil { await chain.relayLatch.close() }
        let inspection = FixtureInspection(directory: directory)
        try beforeStart?(chain, inspection)
        let endpoints = FixtureEndpointRegistry()
        if recoveryOnly {
            guard let retainedCredential, let manifest else { throw FixtureFailure.invalidArguments }
            let recovery = try FixtureRecoveryRuntime(directory: directory, group: group, keys: keys,
                policy: policy, manifest: manifest, consent: consent ?? FixtureConsent(clock: clock), clock: clock, inspection: inspection)
            let state = try recovery.rawState()
            guard let custody = state.custody else { throw FixtureFailure.fixtureUnavailable }
            try validate(state, custody: custody, manifest: manifest)
            let account = try AccountScope(wallet: WalletScope(walletID: custody.walletID, network: .mainnet), accountID: custody.accountID)
            return FixtureRuntime(directory: directory, scenario: scenario, policy: policy, keys: keys,
                custody: custody, chain: chain, clock: clock, session: nil, ownerSession: nil, recovery: recovery,
                account: account, trace: trace, credential: retainedCredential,
                grant: try GrantSelector(wallet: account.wallet, grantID: manifest.grantID), assembly: nil,
                endpoints: endpoints, inspection: inspection, phases: phases)
        }
        let effects: ServiceAssembly.EffectFactory = { context in
            inspection.bind(context.continuity)
            let base = BaseSeedAccountProvider()
            let account: OpalBase.Account
            if resume { account = try await base.restorePublicAccount(custody: context.custody) }
            else { account = try await base.restoreSigningAccount(custody: context.custody, vault: context.vault) }
            let receiving = try await account.selectNextDerivedAddress(for: .receiving)
            let funding = try OpalBase.Transaction(version: 2,
                inputs: [.init(previousTransactionHash: .init(naturalOrder: Data(repeating: 0, count: 32)),
                    previousTransactionOutputIndex: UInt32.max, unlockingScript: Data([0xA1]))],
                outputs: [.init(value: 50_000, address: receiving.address)], lockTime: 0).encode()
            if scenario != .missingSnapshot { try chain.publish(funding, height: 1) }
            let adapter = try await BaseBCHAdapter(account: account, custody: context.custody, vault: context.vault,
                continuity: context.continuity, chain: chain.operations(), clock: clock,
                context: { chain.context() }, canonicalProof: { hash, height, context in chain.proof(hash: hash, height: height, context: context) })
            let payments: any PaymentExecutionBoundary
            if let phases { payments = FixturePhaseBoundary(base: adapter, phases: phases) } else { payments = adapter }
            return ServiceEffectBoundaries(payments: payments, chain: adapter, availability: { _ in
                let context = chain.context()
                if !keys.isPresent { return AccountReadiness(state: .blocked, blockers: [.keyUnavailable]) }
                if !context.fresh || !context.complete { return AccountReadiness(state: .blocked, blockers: [.staleSnapshot]) }
                return AccountReadiness(state: .ready)
            })
        }
        let factory: ServiceAssembly.EndpointFactory = { channel, handlers in endpoints.host(channel, handlers: handlers) }
        let assembly: ServiceAssembly
        if resume {
            guard retainedCredential?.count == 32, manifest != nil else { throw FixtureFailure.invalidArguments }
            assembly = try ServiceAssembly.reopen(directory: directory, accessGroup: group, accounts: accounts,
                operations: keys, policy: policy, effects: effects, endpoints: factory, clock: clock)
        } else {
            guard retainedCredential == nil else { throw FixtureFailure.invalidArguments }
            assembly = try ServiceAssembly.initializeNew(directory: directory, accessGroup: group, accounts: accounts,
                operations: keys, policy: policy, effects: effects, endpoints: factory, clock: clock)
        }
        do {
            try await assembly.start()
            // Join the assembly-owned continuation/reconciliation pass. Derived relay-start and
            // result work remains retained asynchronously; scenario read baselines must observe
            // the relevant terminal policy blocker or controlled latch.
            if resume { try await assembly.continuePending() }
            let ownerHandlers = try endpoints.endpoint(.owner)
            let ownerPeer = PeerEvidence(identity: policy.owner, signatureValidated: true)
            let bootstrapOwner = FixtureOwnerSession(handlers: ownerHandlers,
                connection: try await ownerHandlers.connect(connectionID: UUID().uuidString, peer: ownerPeer),
                consent: FixtureConsent(clock: clock))
            let bootstrap = OwnerControlClient(transport: bootstrapOwner)
            var issued: OwnerIssuedCredential?
            if !resume {
                guard case .createWallet(let status) = try await bootstrap.call(.createWallet(network: .mainnet)), let wallet = status.wallet,
                      case .listAccounts(let directory) = try await bootstrap.call(.listAccounts(wallet)), let account = directory.accounts.first,
                      case .enableWallet = try await bootstrap.call(.enableWallet(wallet)) else { throw FixtureFailure.fixtureUnavailable }
                if scenario == .approvalRequired {
                    guard case .setApprovalPolicy = try await bootstrap.call(.setApprovalPolicy(.init(wallet: wallet, expectedRevision: 1, approvalRequired: true))) else { throw FixtureFailure.fixtureUnavailable }
                }
                guard case .enrollIntegration(let value) = try await bootstrap.call(.enrollIntegration(try EnrollmentRequest(wallet: wallet,
                    integrationID: "protocol-fixture-integration", accountIDs: [account.accountID], scopes: [.read, .sync, .receive, .prepare, .submit, .cancel]))) else { throw FixtureFailure.fixtureUnavailable }
                issued = value
            }
            let state = try inspection.inspect { $0 }
            guard let custody = state.custody else { throw FixtureFailure.fixtureUnavailable }
            if let manifest { try validate(state, custody: custody, manifest: manifest) }
            let account = try AccountScope(wallet: WalletScope(walletID: custody.walletID, network: .mainnet), accountID: custody.accountID)
            let credential: Data
            let grant: GrantSelector
            if let issued { credential = issued.credential.withBytes { $0 }; grant = issued.grant.selector }
            else {
                guard let retainedCredential, let manifest else { throw FixtureFailure.fixtureUnavailable }
                credential = retainedCredential
                grant = try GrantSelector(wallet: account.wallet, grantID: manifest.grantID)
            }
            await bootstrapOwner.close()
            let ownerSession = FixtureOwnerSession(handlers: ownerHandlers,
                connection: try await ownerHandlers.connect(connectionID: UUID().uuidString, peer: ownerPeer),
                consent: consent ?? FixtureConsent(clock: clock))
            let session: FixtureClientSession?
            if resume {
                // Restricted/revoked authority still exposes the actual assembly owner endpoint.
                session = try? await openSession(endpoints: endpoints, policy: policy, credential: credential, chain: chain, trace: trace)
            } else { session = try await openSession(endpoints: endpoints, policy: policy, credential: credential, chain: chain, trace: trace) }
            try trace?.emit(event: "fixture-ready", relayCount: chain.counts.relays)
            return FixtureRuntime(directory: directory, scenario: scenario, policy: policy, keys: keys, custody: custody,
                chain: chain, clock: clock, session: session, ownerSession: ownerSession, account: account,
                trace: trace, credential: credential, grant: grant, assembly: assembly, endpoints: endpoints,
                inspection: inspection, phases: phases)
        } catch {
            let drain = Task { await assembly.shutdown() }
            await chain.relayLatch.open(); await phases?.release()
            await drain.value
            throw error
        }
    }

    private static func validate(_ state: CanonicalState, custody: WalletCustodyRecord, manifest: FixtureStoreManifest) throws {
        guard state.installationID == manifest.installationID, custody.walletID == manifest.walletID,
              custody.accountID == manifest.accountID, custody.profile == manifest.profile, custody.network == "mainnet",
              state.authorization.grants.contains(where: { $0.id == manifest.grantID && $0.integrationID == "protocol-fixture-integration" }) else { throw FixtureFailure.fixtureUnavailable }
    }
    func inspect<T>(_ body: (CanonicalState) throws -> T) throws -> T { try inspection.inspect(body) }
    func state() throws -> CanonicalState { try inspect { $0 } }
    func reference() throws -> StateReference { try inspect { try $0.reference() } }
    func grantProjection() throws -> GrantProjection {
        try inspect { state in
            guard let value = state.authorization.grants.first(where: { $0.id == grantID }) else { throw FixtureFailure.fixtureUnavailable }
            return GrantProjection(selector: grant, integrationID: value.integrationID, accountIDs: value.accountIDs,
                scopes: value.capabilities.compactMap(IntegrationScope.init(rawValue:)), expiresAt: value.expiresAt,
                credentialGeneration: value.credentialGeneration, state: value.revoked ? .revoked : .active, peerProfile: value.peerProfile)
        }
    }
    private static func openSession(endpoints: FixtureEndpointRegistry, policy: AuthorityPolicy, credential: Data,
                                    chain: FixturePublicChain, trace: FixtureTrace?) async throws -> FixtureClientSession {
        guard credential.count == 32 else { throw FixtureFailure.invalidArguments }
        let handlers = try endpoints.endpoint(.integration)
        let connection = try await handlers.connect(connectionID: UUID().uuidString, peer: PeerEvidence(identity: policy.bridge, signatureValidated: true))
        do { try await handlers.authenticate(credential, connection: connection) }
        catch { connection.invalidate(); await handlers.disconnect(connection); throw error }
        return FixtureClientSession(handlers: handlers, connection: connection, chain: chain, trace: trace)
    }
    func openSession(credential: Data? = nil) async throws -> FixtureClientSession {
        try await Self.openSession(endpoints: endpoints, policy: policy, credential: credential ?? syntheticCredential, chain: chain, trace: trace)
    }
    func integrationClient(credential: Data) async throws -> CapabilityClient { try await openSession(credential: credential).client }
    func openForeignSession() async throws -> FixtureClientSession {
        guard case .enrollIntegration(let issued) = try await ownerClient.call(.enrollIntegration(try EnrollmentRequest(wallet: account.wallet,
            integrationID: "foreign-fixture-integration", accountIDs: [account.accountID], scopes: [.read, .sync, .receive, .prepare, .submit, .cancel]))) else { throw FixtureFailure.fixtureUnavailable }
        return try await openSession(credential: issued.credential.withBytes { $0 })
    }
    func foreignClient() async throws -> CapabilityClient { try await openForeignSession().client }
    func openOwnerSession(consent: any OwnerConsentProvider) async throws -> FixtureOwnerSession {
        let handlers = try endpoints.endpoint(.owner)
        return FixtureOwnerSession(handlers: handlers,
            connection: try await handlers.connect(connectionID: UUID().uuidString, peer: PeerEvidence(identity: policy.owner, signatureValidated: true)), consent: consent)
    }
    func ownerPacket(_ packet: NativeOwnerPacket, requestID: UUID, method: OwnerControlMethod) async throws -> OwnerControlResponse {
        if let ownerSession { return try await ownerSession.packet(packet, requestID: requestID, method: method) }
        guard let recovery else { throw FixtureFailure.fixtureUnavailable }
        let (_, request) = try NativeWire.decodeOwnerRequest(packet)
        return try NativeWire.decodeOwnerResponse(NativeWire.ownerResponse(try await recovery.send(request), requestID: requestID), requestID: requestID, method: method)
    }
    func continuePending() async throws {
        guard let assembly else { throw FixtureFailure.fixtureUnavailable }
        try await assembly.continuePending()
    }
    /// Starts terminal admission closure without releasing an intentionally held fixture boundary.
    func beginShutdown() async -> Task<Void, Never> {
        let task = stopLock.withLock { () -> Task<Void, Never> in
            if let stopTask { return stopTask }
            let assembly = self.assembly, recovery = self.recovery, inspection = self.inspection
            let task = Task {
                if let assembly { await assembly.shutdown() }
                await recovery?.shutdown()
                inspection.didStop()
            }
            stopTask = task
            return task
        }
        if let assembly {
            while true {
                let phase = await assembly.phase
                if phase == .stopping || phase == .stopped { break }
                await Task.yield()
            }
        } else { await task.value }
        return task
    }
    /// Explicit test-fault release is separate from factual assembly drainage.
    func releaseFixtureFaults() async { await chain.relayLatch.open(); await phases?.release() }
    func shutdown() async {
        let drain = await beginShutdown()
        await releaseFixtureFaults()
        await drain.value
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
