import AgentNativeIPC
import AgentValues
import CryptoKit
import Foundation

/// The native host implements this only after its existing deployment qualification.
/// A synthetic host exercises the same handlers without creating a Mach listener.
protocol ServiceEndpointHost: Sendable {
    func activate() throws
    func invalidate()
}

/// Trusted internal assembly input, never a public client value or request selector.
struct ServiceCustodyContext: Sendable {
    let continuity: ContinuityCoordinator
    let vault: WalletSeedVault
    let custody: WalletCustodyRecord
}

struct ServiceEffectBoundaries: Sendable {
    let payments: any PaymentExecutionBoundary
    let chain: any AccountChainBoundary
    let availability: @Sendable (AccountScope) -> AccountReadiness
    init(payments: any PaymentExecutionBoundary, chain: any AccountChainBoundary,
         availability: @escaping @Sendable (AccountScope) -> AccountReadiness = { _ in .unavailable }) {
        self.payments = payments; self.chain = chain; self.availability = availability
    }
}

private struct UnavailableAssemblyChain: AccountChainBoundary {
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord { throw PaymentFailure.unavailable }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String { throw PaymentFailure.unavailable }
}

/// An opaque admission belongs to one assembly and one server-selected connection.
final class ServiceConnection: Sendable {
    fileprivate let token = UUID()
    fileprivate let connectionID: String
    fileprivate let channel: NativeChannel
    fileprivate let context: OwnerConnectionContext
    fileprivate init(connectionID: String, channel: NativeChannel, peer: PeerEvidence) {
        self.connectionID = connectionID; self.channel = channel
        self.context = OwnerConnectionContext(connectionID: connectionID, peer: peer)
    }
    /// Physical disconnection must revoke proof synchronously, before actor bookkeeping.
    func invalidate() { context.invalidate() }
    var isActive: Bool { context.isActive }
}

struct ServiceEndpointHandlers: Sendable {
    let channel: NativeChannel
    fileprivate weak var assembly: ServiceAssembly?

    func connect(connectionID: String, peer: PeerEvidence) async throws -> ServiceConnection {
        guard let assembly else { throw ServiceProblem(.unavailable) }
        return try await assembly.connect(connectionID: connectionID, channel: channel, peer: peer)
    }
    func authenticate(_ credential: Data, connection: ServiceConnection) async throws {
        guard let assembly else { throw ServiceProblem(.unavailable) }
        try await assembly.authenticate(credential, connection: connection, channel: channel)
    }
    func owner(_ request: OwnerControlRequest, connection: ServiceConnection,
               consent: any OwnerConsentProvider) async throws -> OwnerControlResponse {
        guard let assembly else { throw ServiceProblem(.unavailable) }
        return try await assembly.owner(request, connection: connection, channel: channel, consent: consent)
    }
    func capability(_ request: CapabilityRequest, connection: ServiceConnection) async throws -> CapabilityResponse {
        guard let assembly else { throw ServiceProblem(.unavailable) }
        return try await assembly.capability(request, connection: connection, channel: channel)
    }
    func disconnect(_ connection: ServiceConnection) async {
        if connection.channel == channel { connection.invalidate() }
        await assembly?.disconnect(connection, channel: channel)
    }
}

/// One terminal lifecycle owns custody, effects and role-specific endpoint admissions.
/// Shutdown drains factual work; cancellation or a lost response never proves no effect.
actor ServiceAssembly {
    enum Phase: Sendable { case idle, starting, running, stopping, stopped }
    typealias EndpointFactory = @Sendable (NativeChannel, ServiceEndpointHandlers) throws -> any ServiceEndpointHost
    typealias EffectFactory = @Sendable (ServiceCustodyContext) async throws -> ServiceEffectBoundaries
    private(set) var phase: Phase = .idle

    private struct Runtime {
        let authority: ServiceAuthority
        let payments: PaymentEngine
        let receives: ReceiveEngine
        let capabilities: CapabilityService
        let chain: any AccountChainBoundary
    }
    private struct Connection {
        let handle: ServiceConnection
        let peer: PeerEvidence
        let owner: OwnerConnectionContext?
        var session: AuthorizationSession?
    }
    private var store: DurableWalletStore?
    private let policy: AuthorityPolicy
    private let effectFactory: EffectFactory
    private let endpointFactory: EndpointFactory
    private let clock: any PaymentClock
    private var runtime: Runtime?
    private var binding: (custody: WalletCustodyRecord, task: Task<ServiceEffectBoundaries, any Error>)?
    private var continuation: (id: UUID, task: Task<Void, Never>)?
    private var endpoints: [any ServiceEndpointHost] = []
    private var connections: [UUID: Connection] = [:]
    private var activeCalls = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    static func initializeNew(directory: URL, accessGroup: String, accounts: any SeedAccountProvider,
                              operations: any KeychainItemOperations, policy: AuthorityPolicy,
                              payments: any PaymentExecutionBoundary, chain: any AccountChainBoundary,
                              endpoints: @escaping EndpointFactory,
                              clock: any PaymentClock = SystemPaymentClock(),
                              availability: @escaping @Sendable (AccountScope) -> AccountReadiness = { _ in .unavailable },
                              generateKey: @escaping @Sendable () throws -> SymmetricKey = {
                                  SymmetricKey(size: .bits256)
                              }) throws -> ServiceAssembly {
        try initializeNew(directory: directory, accessGroup: accessGroup, accounts: accounts,
            operations: operations, policy: policy,
            effects: { _ in ServiceEffectBoundaries(payments: payments, chain: chain, availability: availability) },
            endpoints: endpoints, clock: clock, generateKey: generateKey)
    }

    static func initializeNew(directory: URL, accessGroup: String, accounts: any SeedAccountProvider,
                              operations: any KeychainItemOperations, policy: AuthorityPolicy,
                              effects: @escaping EffectFactory, endpoints: @escaping EndpointFactory,
                              clock: any PaymentClock = SystemPaymentClock(),
                              generateKey: @escaping @Sendable () throws -> SymmetricKey = {
                                  SymmetricKey(size: .bits256)
                              }) throws -> ServiceAssembly {
        try Task.checkCancellation()
        let store = try DurableWalletStore.initializeNew(directory: directory, accessGroup: accessGroup,
            accounts: accounts, operations: operations, policy: policy, generateKey: generateKey)
        try Task.checkCancellation()
        return ServiceAssembly(store: store, policy: policy, effects: effects,
                               endpoints: endpoints, clock: clock)
    }

    static func reopen(directory: URL, accessGroup: String, accounts: any SeedAccountProvider,
                       operations: any KeychainItemOperations, policy: AuthorityPolicy,
                       payments: any PaymentExecutionBoundary, chain: any AccountChainBoundary,
                       endpoints: @escaping EndpointFactory,
                       clock: any PaymentClock = SystemPaymentClock(),
                       availability: @escaping @Sendable (AccountScope) -> AccountReadiness = { _ in .unavailable }) throws -> ServiceAssembly {
        try reopen(directory: directory, accessGroup: accessGroup, accounts: accounts,
            operations: operations, policy: policy,
            effects: { _ in ServiceEffectBoundaries(payments: payments, chain: chain, availability: availability) },
            endpoints: endpoints, clock: clock)
    }

    static func reopen(directory: URL, accessGroup: String, accounts: any SeedAccountProvider,
                       operations: any KeychainItemOperations, policy: AuthorityPolicy,
                       effects: @escaping EffectFactory, endpoints: @escaping EndpointFactory,
                       clock: any PaymentClock = SystemPaymentClock()) throws -> ServiceAssembly {
        try Task.checkCancellation()
        let store = try DurableWalletStore.reopen(directory: directory, accessGroup: accessGroup,
            accounts: accounts, operations: operations, policy: policy)
        try Task.checkCancellation()
        return ServiceAssembly(store: store, policy: policy, effects: effects,
                               endpoints: endpoints, clock: clock)
    }

    private init(store: DurableWalletStore, policy: AuthorityPolicy,
                 effects: @escaping EffectFactory,
                 endpoints: @escaping EndpointFactory, clock: any PaymentClock) {
        self.store = store; self.policy = policy; self.effectFactory = effects
        self.endpointFactory = endpoints; self.clock = clock
    }

    deinit {
        for connection in connections.values { connection.handle.invalidate() }
        for endpoint in endpoints { endpoint.invalidate() }
    }

    func start() async throws {
        guard phase == .idle else { throw ServiceProblem(.unavailable) }
        phase = .starting
        activeCalls += 1
        do {
            try Task.checkCancellation()
            guard let store else { throw ServiceProblem(.unavailable) }
            if !store.permitsNewWallet { _ = try await requireRuntime() }
            guard phase == .starting else { throw ServiceProblem(.unavailable) }
            var channels: [NativeChannel] = [.owner, .integration]
            if policy.appleIntegration != nil { channels.append(.appleAutomation) }
            for channel in channels {
                try Task.checkCancellation()
                let endpoint = try endpointFactory(channel, ServiceEndpointHandlers(channel: channel, assembly: self))
                endpoints.append(endpoint) // Include an activation failure in rollback.
                try endpoint.activate()
            }
            try Task.checkCancellation()
            phase = .running // No request is admitted before the entire set is ready.
            if runtime != nil { _ = try scheduleContinuation() }
            finishCall()
        } catch {
            finishCall()
            await shutdown()
            throw error
        }
    }

    /// Terminal and idempotent. A cancelled caller still waits for actual drainage.
    /// An uncooperative admitted boundary can keep this pending and the writer retained.
    func shutdown() async {
        if phase == .stopped { return }
        if phase == .stopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        phase = .stopping
        for connection in connections.values { connection.handle.invalidate() }
        connections.removeAll()
        let retained = endpoints
        endpoints.removeAll()
        for endpoint in retained { endpoint.invalidate() }
        if activeCalls > 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        // An asynchronous adapter factory owns the same custody/lease while it runs.
        // Its completion cannot publish effects after admission has closed.
        _ = await binding?.task.result
        if let runtime {
            async let payments: Void = runtime.payments.shutdown()
            async let receives: Void = runtime.receives.shutdown()
            _ = await (payments, receives)
        }
        await continuation?.task.value
        continuation = nil
        binding = nil
        runtime = nil
        store = nil
        phase = .stopped
        let waiters = stopWaiters; stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Startup and an explicit trusted host wake share one retained continuation job.
    /// Polling and ordinary integration reads never enter this path.
    func continuePending() async throws {
        try requireRunning()
        activeCalls += 1
        defer { finishCall() }
        let task = try scheduleContinuation()
        await task.value
        try requireRunning()
    }

    private func scheduleContinuation() throws -> Task<Void, Never> {
        if let continuation { return continuation.task }
        guard let payments = runtime?.payments else { throw ServiceProblem(.unavailable) }
        let id = UUID()
        let task = Task { [weak self] in
            await payments.continuePending()
            await self?.finishedContinuation(id)
        }
        continuation = (id, task)
        return task
    }

    private func finishedContinuation(_ id: UUID) {
        if continuation?.id == id { continuation = nil }
    }

    private func requireRuntime() async throws -> Runtime {
        guard phase == .starting || phase == .running else { throw ServiceProblem(.unavailable) }
        if let runtime { return runtime }
        guard let store, let vault = store.vault else { throw ServiceProblem(.unavailable) }
        let authority = try store.integrationAuthority()
        let custody = try store.continuity.inspect { state in
            guard let custody = state.custody else { throw ServiceProblem(.unavailable) }
            try vault.requireAvailable(custody)
            return custody
        }
        let task: Task<ServiceEffectBoundaries, any Error>
        if let binding {
            guard binding.custody == custody else { throw ServiceProblem(.staleContext) }
            task = binding.task
        }
        else {
            let factory = effectFactory
            task = Task { try await factory(ServiceCustodyContext(continuity: store.continuity, vault: vault, custody: custody)) }
            binding = (custody, task)
        }
        let boundaries = try await task.value
        guard phase == .starting || phase == .running else { throw ServiceProblem(.unavailable) }
        if let runtime { return runtime }
        try Task.checkCancellation()
        try store.continuity.inspect { state in
            guard state.custody == custody else { throw ServiceProblem(.staleContext) }
            try vault.requireAvailable(custody)
        }
        let payments = try store.paymentEngine(boundary: boundaries.payments, clock: clock)
        let receives = try store.receiveEngine(boundary: boundaries.chain, clock: clock)
        let value = Runtime(authority: authority, payments: payments, receives: receives,
            capabilities: CapabilityService(continuity: store.continuity, policy: policy,
                payments: payments, receives: receives, clock: clock, availability: boundaries.availability),
            chain: boundaries.chain)
        runtime = value
        return value
    }

    fileprivate func connect(connectionID: String, channel: NativeChannel,
                             peer: PeerEvidence) throws -> ServiceConnection {
        try requireRunning()
        let identity: SignedPeerIdentity?
        switch channel {
        case .owner: identity = policy.owner
        case .integration: identity = policy.bridge
        case .appleAutomation: identity = policy.appleIntegration
        }
        guard !connectionID.isEmpty, peer.signatureValidated, let identity,
              peer.identity == identity else { throw ServiceProblem(.unavailable) }
        if let existing = connections.values.first(where: { $0.handle.connectionID == connectionID }) {
            if existing.handle.isActive {
                guard existing.handle.channel == channel, existing.peer == peer else { throw ServiceProblem(.unavailable) }
                return existing.handle
            }
            connections.removeValue(forKey: existing.handle.token)
        }
        let handle = ServiceConnection(connectionID: connectionID, channel: channel, peer: peer)
        connections[handle.token] = Connection(handle: handle, peer: peer,
            owner: channel == .owner ? handle.context : nil)
        return handle
    }

    fileprivate func authenticate(_ credential: Data, connection: ServiceConnection,
                                  channel: NativeChannel) async throws {
        let admitted = try requireConnection(connection, channel: channel)
        guard channel != .owner, admitted.session == nil else { throw ServiceProblem(.unavailable) }
        activeCalls += 1
        defer { finishCall() }
        let runtime = try await requireRuntime()
        var current = try requireConnection(connection, channel: channel)
        guard channel != .owner, current.session == nil else { throw ServiceProblem(.unavailable) }
        let session = try runtime.authority.authenticate(connectionID: connection.connectionID,
            peer: current.peer, credential: credential, now: clock.read().wall)
        guard session.peerProfile == (channel == .integration ? .mcp : .appleAutomation) else {
            throw ServiceProblem(.unavailable)
        }
        current.session = session; connections[connection.token] = current
    }

    fileprivate func owner(_ request: OwnerControlRequest, connection: ServiceConnection,
                           channel: NativeChannel, consent: any OwnerConsentProvider) async throws -> OwnerControlResponse {
        let current = try requireConnection(connection, channel: channel)
        guard channel == .owner, let context = current.owner, let store else { throw ServiceProblem(.unavailable) }
        let service = try OwnerControlService(store: store, accounts: runtime?.chain ?? UnavailableAssemblyChain(), consent: consent, clock: clock)
        activeCalls += 1
        defer { finishCall() }
        let result = try await service.send(request, connection: context)
        _ = try requireConnection(connection, channel: channel)
        if case .createWallet = request.call { _ = try await requireRuntime() }
        _ = try requireConnection(connection, channel: channel)
        return result
    }

    fileprivate func capability(_ request: CapabilityRequest, connection: ServiceConnection,
                                channel: NativeChannel) async throws -> CapabilityResponse {
        let current = try requireConnection(connection, channel: channel)
        guard channel != .owner, let session = current.session else { throw ServiceProblem(.unavailable) }
        activeCalls += 1
        defer { finishCall() }
        let service = try await requireRuntime().capabilities
        _ = try requireConnection(connection, channel: channel)
        let result = try await service.handle(request, context: CapabilityConnectionContext(session: session,
            connectionID: connection.connectionID, peer: current.peer))
        _ = try requireConnection(connection, channel: channel)
        return result
    }

    fileprivate func disconnect(_ connection: ServiceConnection, channel: NativeChannel) {
        guard connection.channel == channel, let current = connections[connection.token],
              current.handle === connection else { return }
        current.handle.invalidate()
        connections.removeValue(forKey: connection.token)
    }

    private func requireRunning() throws {
        guard phase == .running, !Task.isCancelled else { throw ServiceProblem(.unavailable) }
    }
    private func requireConnection(_ connection: ServiceConnection, channel: NativeChannel) throws -> Connection {
        try requireRunning()
        guard connection.channel == channel, connection.isActive, let current = connections[connection.token],
              current.handle === connection else { throw ServiceProblem(.unavailable) }
        return current
    }
    private func finishCall() {
        activeCalls -= 1
        if activeCalls == 0 {
            let waiters = drainWaiters; drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
}
