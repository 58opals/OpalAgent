import AgentClient
import AgentNativeIPC
import AgentValues
import CryptoKit
import Foundation
import OpalBaseCore
import Security
import Testing
@testable import AgentServiceCore

// Request frames use the production dispatcher and genuine assembly admissions. Synthetic
// hosts/peer/consent/custody/effects do not qualify NSXPC capture, hello/auth frames or listeners.
struct NativeAssemblyFrameTests {
    @Test func framedOwnerProvisioningSeparatesSensitiveOutputsAndMetadataReads() async throws {
        let f = NativeFrameFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let connection = try await f.connect(.owner)
        let transport = try f.ownerTransport(connection)
        let client = OwnerControlClient(transport: transport)
        guard case .status(let initial) = try await client.call(.status) else { throw NativeFrameFailure.result }
        #expect(initial.wallet == nil && f.consent.challenges.isEmpty)
        let wallet = try await f.createEnabled(client)
        let issued = try await f.enroll(wallet, client: client)
        let enrollment = try #require(await transport.last())
        let credential = issued.credential.withBytes { $0 }
        #expect(enrollment.packet.sensitive == credential && credential.count == 32)
        try expectOwnerMetadata(enrollment, method: .enrollIntegration, payload: NativeWire.encode(issued.grant))
        #expect(!String(reflecting: enrollment.packet).contains(credential.base64EncodedString()))
        guard case .exportRecoveryMaterial(let material) = try await client.call(.exportRecoveryMaterial(wallet)) else {
            throw NativeFrameFailure.result
        }
        let recovery = try #require(await transport.last())
        #expect(recovery.packet.sensitive == NativeFrameSeeds.mnemonic)
        #expect(material.material.withBytes { $0 } == NativeFrameSeeds.mnemonic)
        try expectOwnerMetadata(recovery, method: .exportRecoveryMaterial, payload: NativeWire.encode(wallet))
        #expect(!String(reflecting: material).contains(String(decoding: NativeFrameSeeds.mnemonic, as: UTF8.self)))
        let baseline = try f.state().reference(), effects = f.effects.counts, reads = f.keyReads
        let consentCount = f.consent.challenges.count
        _ = try await client.call(.status)
        _ = try await client.call(.inspectRecovery)
        _ = try await client.call(.listAccounts(wallet))
        #expect(f.consent.challenges.count == consentCount)
        #expect(try f.state().reference() == baseline)
        #expect(f.effects.counts == effects && f.keyReads == reads)
        let metadata = try #require(await transport.last())
        #expect(metadata.packet.sensitive == nil)
        connection.invalidate()
        await #expect(throws: ServiceProblem(.unavailable)) { try await client.call(.exportRecoveryMaterial(wallet)) }
        try expectOwnerProblem(try #require(await transport.last()), code: .unavailable)
        #expect(f.keyReads == reads && f.consent.challenges.count == consentCount)
        await assembly.shutdown()
    }

    @Test(arguments: NativeFrameConsentFault.allCases)
    private func framedOwnerRejectsUnboundOrReplayedConsentWithoutDisclosure(_ fault: NativeFrameConsentFault) async throws {
        let f = NativeFrameFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let owner = try await f.connect(.owner)
        let transport = try f.ownerTransport(owner)
        let client = OwnerControlClient(transport: transport)
        let wallet = try await f.createEnabled(client)
        // Keep an actual prior proof for the same action/context. Replay must fail on its new nonce.
        _ = try await client.call(.exportRecoveryMaterial(wallet))
        let prior = try #require(f.consent.challenges.last)
        let baseline = try f.state().reference(), reads = f.keyReads, writes = f.securityWrites
        let effects = f.effects.counts, generated = f.seeds.generated
        f.consent.set(fault)
        await #expect(throws: ServiceProblem(.unavailable)) { try await client.call(.exportRecoveryMaterial(wallet)) }
        let exchange = try #require(await transport.last())
        try expectOwnerProblem(exchange, code: .unavailable)
        let challenge = try #require(f.consent.challenges.last)
        #expect(challenge.purpose == .exportRecoveryMaterial && challenge.connectionID == prior.connectionID)
        #expect(challenge.nonce != prior.nonce)
        let expectedReview = try NativeWire.reviewCommitment(.exportRecoveryMaterial(wallet))
        #expect(challenge.reviewCommitment == expectedReview)
        #expect(try f.state().reference() == baseline)
        #expect(f.keyReads == reads && f.securityWrites == writes)
        #expect(f.effects.counts == effects && f.seeds.generated == generated)
        await assembly.shutdown()
    }

    @Test(arguments: [IntegrationPeerProfile.mcp, .appleAutomation])
    func framedIntegrationAdmissionsKeepProfilesRolesAndRevocationSeparate(_ profile: IntegrationPeerProfile) async throws {
        let f = NativeFrameFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let owner = try await f.connect(.owner)
        let ownerTransport = try f.ownerTransport(owner)
        let client = OwnerControlClient(transport: ownerTransport)
        let wallet = try await f.createEnabled(client)
        let issued = try await f.enroll(wallet, client: client, profile: profile)
        let channel: NativeChannel = profile == .mcp ? .integration : .appleAutomation
        let other: NativeChannel = profile == .mcp ? .appleAutomation : .integration
        let handlers = try f.hosts.handlers(channel)
        let connection = try await f.connect(channel)
        try await handlers.authenticate(issued.credential.withBytes { $0 }, connection: connection)
        let capability = CapabilityClient(transport: NativeFrameCapabilityTransport(handlers: handlers, connection: connection))
        guard case .listWallets(let wallets) = try await capability.call(.listWallets(PageRequest())) else {
            throw NativeFrameFailure.result
        }
        #expect(wallets.items.map(\.scope) == [wallet])
        let baseline = try f.state().reference(), effects = f.effects.counts, reads = f.keyReads
        let wrongProfile = try await f.connect(other)
        await #expect(throws: (any Error).self) {
            try await f.hosts.handlers(other).authenticate(issued.credential.withBytes { $0 }, connection: wrongProfile)
        }
        let id = UUID()
        let request = try NativeWire.capabilityRequest(.init(call: .listWallets(PageRequest())), requestID: id)
        try expectNativeProblem(await NativeServiceFrames.integration(request, handlers: f.hosts.handlers(other), connection: wrongProfile), id: id, code: .unavailable)
        let unauthenticated = try await f.connect(channel)
        try expectNativeProblem(await NativeServiceFrames.integration(request, handlers: handlers, connection: unauthenticated), id: id, code: .unavailable)
        // Malformed representatives use a valid authenticated handle, rather than relying on retirement.
        let wrongKind = try NativeWire.frame(NativeHello(channel: channel, connectionID: ""), kind: .hello, requestID: id)
        try expectNativeProblem(await NativeServiceFrames.integration(wrongKind, handlers: handlers, connection: connection), id: id, code: .invalidRequest)
        var version = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        version["protocolVersion"] = ServiceStatus.currentProtocolVersion + 1
        let wrongVersion = try JSONSerialization.data(withJSONObject: version)
        try expectNativeProblem(await NativeServiceFrames.integration(wrongVersion, handlers: handlers, connection: connection), id: id, code: .invalidRequest)
        let ownerRequest = try NativeWire.ownerRequest(.init(call: .status), requestID: id)
        let wrongRole = await NativeServiceFrames.owner(ownerRequest, handlers: try f.hosts.handlers(.owner), connection: connection, consent: f.consent)
        #expect(wrongRole.sensitive == nil)
        try expectNativeProblem(wrongRole.frame, id: id, code: .unavailable)
        try expectNativeProblem(await NativeServiceFrames.integration(request, handlers: f.hosts.handlers(.owner), connection: owner), id: id, code: .unavailable)
        #expect(try f.state().reference() == baseline)
        #expect(f.effects.counts == effects && f.keyReads == reads)
        _ = try await client.call(.revokeGrant(issued.grant.selector))
        let revoked = try f.state().reference(), revokedReads = f.keyReads
        try expectNativeProblem(await NativeServiceFrames.integration(request, handlers: handlers, connection: connection), id: id, code: .unavailable)
        connection.invalidate()
        await handlers.disconnect(connection)
        try expectNativeProblem(await NativeServiceFrames.integration(request, handlers: handlers, connection: connection), id: id, code: .unavailable)
        #expect(try f.state().reference() == revoked)
        #expect(f.effects.counts == effects && f.keyReads == revokedReads)
        await assembly.shutdown()
    }

    @Test(arguments: NativeFrameSuspension.allCases)
    private func suspendedFramedOwnerCannotPublishAfterDisconnectOrShutdown(_ suspension: NativeFrameSuspension) async throws {
        let f = NativeFrameFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let owner = try await f.connect(.owner)
        let transport = try f.ownerTransport(owner)
        let client = OwnerControlClient(transport: transport)
        let call: OwnerControlCall
        let baseline: StateReference?
        if suspension == .consentShutdown {
            let wallet = try await f.createEnabled(client)
            call = .exportRecoveryMaterial(wallet)
            baseline = try f.state().reference()
        } else { call = .createWallet(network: .mainnet); baseline = nil }
        let generated = f.seeds.generated, keys = f.seeds.keys
        let gate = suspension == .consentShutdown ? f.consent.gate : f.seeds.derivation
        await gate.arm()
        defer { Task { await gate.release() } }
        let pending = Task { try await client.call(call) }
        try await nativeFrameEventually { await gate.hasEntered }
        // Creation may inspect key absence before derivation; only subsequent effects are fenced.
        let writes = f.securityWrites, reads = f.keyReads, items = f.operations.storedItems.count
        if suspension == .derivationDisconnect {
            // Isolate shared handle retirement: the assembly and caller stay live through completion.
            // Physical NSXPC capture/disconnect is not run here.
            owner.invalidate()
            try await f.hosts.handlers(.owner).disconnect(owner)
            await gate.release()
            await #expect(throws: ServiceProblem(.unavailable)) { try await pending.value }
            try expectOwnerProblem(try #require(await transport.last()), code: .unavailable)
            #expect(await assembly.phase == .running)
            let observer = try await f.connect(.owner)
            let observingClient = OwnerControlClient(transport: try f.ownerTransport(observer))
            guard case .status(let status) = try await observingClient.call(.status) else { throw NativeFrameFailure.result }
            #expect(status.wallet == nil && status.custody == .absent)
        } else {
            let done = NativeFrameFlag()
            let stop = Task { await assembly.shutdown(); done.set() }
            try await nativeFrameEventually { await assembly.phase == .stopping }
            #expect(!done.value)
            #expect(throws: StoreLockFailure.busy) { try StoreLock(path: f.writerPath, createIfMissing: false) }
            await gate.release()
            await #expect(throws: ServiceProblem(.unavailable)) { try await pending.value }
            try expectOwnerProblem(try #require(await transport.last()), code: .unavailable)
            await stop.value
            #expect(done.value)
        }
        #expect(f.securityWrites == writes && f.keyReads == reads)
        #expect(f.seeds.keys == keys && f.seeds.generated == generated + (suspension == .derivationDisconnect ? 1 : 0))
        #expect(f.operations.storedItems.count == items && f.effects.counts == NativeFrameEffects.Counts())
        // The disconnect branch reaches cleanup only after its framed result/state/effect assertions.
        if suspension == .derivationDisconnect { await assembly.shutdown() }
        if let baseline { #expect(try f.state().reference() == baseline) }
        else {
            #expect(try SQLiteJournal(path: f.directory.appendingPathComponent("journal.sqlite").path, createIfMissing: false).read() == nil)
        }
        let lease = try StoreLock(path: f.writerPath, createIfMissing: false)
        withExtendedLifetime(lease) {}
    }

    @Test func framedShutdownRetainsAmbiguousRelayIdentityAcrossFreshAssemblyReopen() async throws {
        let f = NativeFrameFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let owner = try await f.connect(.owner)
        let ownerClient = OwnerControlClient(transport: try f.ownerTransport(owner))
        let wallet = try await f.createEnabled(ownerClient)
        let issued = try await f.enroll(wallet, client: ownerClient)
        let handlers = try f.hosts.handlers(.integration)
        let connection = try await f.connect(.integration)
        try await handlers.authenticate(issued.credential.withBytes { $0 }, connection: connection)
        let client = CapabilityClient(transport: NativeFrameCapabilityTransport(handlers: handlers, connection: connection))
        let account = try AccountScope(wallet: wallet, accountID: NativeFrameSeeds.accountID)
        let request = try PreparePaymentRequest(account: account, requestKey: RequestKey(String(repeating: "c", count: 32)),
            destinationAddress: "1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu", amountSatoshis: 1_000)
        let (_, decoded) = try NativeWire.decodeCapabilityRequest(NativeWire.capabilityRequest(.init(call: .preparePayment(request)), requestID: UUID()))
        guard case .preparePayment(let wireRequest) = decoded.call else { throw NativeFrameFailure.result }
        #expect(wireRequest == request)
        let inputAddress = try OpalBase.Address(wireRequest.destinationAddress, network: .mainnet)
        let canonicalAddress = try OpalBase.Address(script: inputAddress.lockingScript, network: .mainnet).string
        let expectedCanonicalRequest = try PreparePaymentRequest(account: request.account, requestKey: request.requestKey,
            destinationAddress: canonicalAddress, amountSatoshis: request.amountSatoshis,
            feeRateSatoshisPerByte: request.feeRateSatoshisPerByte, expiresAt: request.expiresAt)
        guard case .preparePayment(let prepared) = try await client.call(.preparePayment(request)) else { throw NativeFrameFailure.result }
        // Wire input retains its spelling; the public service request uses the canonical script address.
        #expect(prepared.request == expectedCanonicalRequest)
        #expect(prepared.request.account == request.account && prepared.request.requestKey == request.requestKey)
        #expect(prepared.request.amountSatoshis == request.amountSatoshis && prepared.request.feeRateSatoshisPerByte == request.feeRateSatoshisPerByte)
        #expect(prepared.request.expiresAt == request.expiresAt)
        #expect(prepared.request.destinationAddress != request.destinationAddress)
        let selector = prepared.identity.selector
        try await nativeFrameEventually { try f.state().payments.first { $0.id == selector.operationID }?.disposition == .prepared }
        await f.effects.result.arm()
        defer { Task { await f.effects.result.release() } }
        _ = try await client.call(.submitPayment(selector))
        try await nativeFrameEventually { await f.effects.result.hasEntered }
        let admittedState = try f.state()
        let admitted = try #require(admittedState.payments.first { $0.id == selector.operationID })
        let retainedRequest = try #require(admittedState.requests.first { $0.paymentID == selector.operationID && $0.method == "prepare_payment" })
        #expect(admitted.attempts.count == 1 && admitted.ordinaryAdmissions == 1 && admitted.liabilityUnresolved)
        #expect(f.effects.sentBytes == [admitted.canonicalBytes] && !admitted.canonicalBytes.isEmpty)
        let done = NativeFrameFlag()
        let stop = Task { await assembly.shutdown(); done.set() }
        try await nativeFrameEventually { await assembly.phase == .stopping }
        #expect(!done.value)
        #expect(throws: StoreLockFailure.busy) { try StoreLock(path: f.writerPath, createIfMissing: false) }
        await #expect(throws: ServiceProblem(.unavailable)) { try await client.call(.getOperation(.operation(selector))) }
        #expect(!done.value && f.effects.counts.handoff == 1)
        await f.effects.result.release()
        await stop.value
        let stoppedState = try f.state()
        let stopped = try #require(stoppedState.payments.first { $0.id == selector.operationID })
        #expect(stopped.disposition == .uncertain && stopped.liabilityUnresolved && stopped.attempts == admitted.attempts)
        #expect(stopped.canonicalBytes == admitted.canonicalBytes && stopped.transactionID == admitted.transactionID)
        #expect(stopped.evidence.contains { $0.source == "synthetic-native-frame" && $0.valid })
        #expect(stoppedState.gates.contains { $0.liabilityIDs.contains(selector.operationID) })
        do { let lease = try StoreLock(path: f.writerPath, createIfMissing: false); withExtendedLifetime(lease) {} }
        let reopened = try f.reopen()
        try await reopened.start()
        try await reopened.continuePending()
        try await nativeFrameEventually { try f.state().payments.first { $0.id == selector.operationID }?.blocker == "relayNotEligible" }
        let currentHandlers = try f.hosts.handlers(.integration)
        let current = try await f.connect(.integration)
        try await currentHandlers.authenticate(issued.credential.withBytes { $0 }, connection: current)
        let next = CapabilityClient(transport: NativeFrameCapabilityTransport(handlers: currentHandlers, connection: current))
        let baseline = try f.state(), counts = f.effects.counts, reads = f.keyReads
        guard case .getOperation(.payment(let retained)) = try await next.call(.getOperation(.request(account: account, effect: .preparePayment, key: request.requestKey))) else {
            throw NativeFrameFailure.result
        }
        #expect(retained.identity == prepared.identity)
        #expect(retained.request == prepared.request)
        #expect(retained.state == .uncertain)
        #expect(retained.latestAttempt?.attemptID == admitted.attempts.first?.id && retained.ordinaryAdmissions == 1 && retained.liabilityUnresolved)
        #expect(retained.transactionID == admitted.transactionID && retained.accountRestriction == .held)
        await #expect(throws: ServiceProblem(.unavailable)) { try await client.call(.getOperation(.operation(selector))) }
        let stale = CapabilityClient(transport: NativeFrameCapabilityTransport(handlers: currentHandlers, connection: connection))
        await #expect(throws: ServiceProblem(.unavailable)) { try await stale.call(.getOperation(.operation(selector))) }
        let after = try f.state(), final = try #require(after.payments.first { $0.id == selector.operationID })
        let afterReference = try after.reference(), baselineReference = try baseline.reference()
        #expect(afterReference == baselineReference)
        #expect(final.canonicalBytes == admitted.canonicalBytes && final.transactionDigest == admitted.transactionDigest)
        #expect(final.attempts == admitted.attempts && final.request == admitted.request && final.liabilityUnresolved)
        #expect(after.requests.first { $0.id == retainedRequest.id } == retainedRequest && after.gates == stoppedState.gates)
        #expect(after.custody == stoppedState.custody && after.authorization == stoppedState.authorization)
        #expect(f.effects.counts == counts && f.keyReads == reads)
        #expect(f.effects.counts.sign == 1 && f.effects.counts.handoff == 1 && f.seeds.generated == 1 && f.seeds.keys == 1)
        await reopened.shutdown()
    }
}

private enum NativeFrameFailure: Error { case result, timeout }
private enum NativeFrameConsentFault: CaseIterable, Sendable { case purpose, connection, nonce, review, replay, stale }
private enum NativeFrameSuspension: CaseIterable, Sendable { case consentShutdown, derivationDisconnect }
private struct NativeFrameOwnerExchange: Sendable {
    let id: UUID
    let packet: NativeOwnerPacket
}
private actor NativeFrameOwnerTransport: OwnerControlTransport {
    let handlers: ServiceEndpointHandlers
    let connection: ServiceConnection
    let consent: NativeFrameConsent
    private var latest: NativeFrameOwnerExchange?
    init(handlers: ServiceEndpointHandlers, connection: ServiceConnection, consent: NativeFrameConsent) {
        self.handlers = handlers; self.connection = connection; self.consent = consent
    }
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        let id = UUID()
        let input = try NativeWire.ownerRequest(request, requestID: id)
        let output = await NativeServiceFrames.owner(input, handlers: handlers, connection: connection, consent: consent)
        latest = .init(id: id, packet: output)
        return try NativeWire.decodeOwnerResponse(output, requestID: id, method: request.call.method)
    }
    func last() -> NativeFrameOwnerExchange? { latest }
}
private struct NativeFrameCapabilityTransport: CapabilityTransport {
    let handlers: ServiceEndpointHandlers
    let connection: ServiceConnection
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        let id = UUID()
        let input = try NativeWire.capabilityRequest(request, requestID: id)
        let output = await NativeServiceFrames.integration(input, handlers: handlers, connection: connection)
        return try NativeWire.decodeCapabilityResponse(output, requestID: id)
    }
}
private struct NativeFrameOwnerMetadata: Codable { let method: String; let payload: Data }
private func expectOwnerMetadata(_ exchange: NativeFrameOwnerExchange, method: OwnerControlMethod, payload: Data) throws {
    let frame = try NativeWire.unpack(exchange.packet.frame, kind: .ownerResponse, requestID: exchange.id)
    let metadata = try NativeWire.decode(NativeFrameOwnerMetadata.self, from: frame.payload)
    #expect(metadata.method == method.rawValue && metadata.payload == payload)
}
private func expectOwnerProblem(_ exchange: NativeFrameOwnerExchange, code: ServiceProblemCode) throws {
    #expect(exchange.packet.sensitive == nil)
    try expectNativeProblem(exchange.packet.frame, id: exchange.id, code: code)
}
private func expectNativeProblem(_ bytes: Data, id: UUID, code: ServiceProblemCode) throws {
    #expect(bytes == NativeWire.problem(code, requestID: id))
    let frame = try NativeWire.decode(NativeFrame.self, from: bytes)
    #expect(frame.kind == .problem && frame.requestID == id)
    #expect(try NativeWire.decode(ServiceProblem.self, from: frame.payload) == ServiceProblem(code))
}

private final class NativeFrameFixture: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-assembly-frames-\(UUID().uuidString)")
    let operations = KeychainTestOperations()
    let seeds = NativeFrameSeeds()
    let hosts = NativeFrameHosts()
    let stateOwner = NativeFrameState()
    let clock = NativeFrameClock()
    let consent = NativeFrameConsent()
    let effects = NativeFrameEffects()
    let policy = AuthorityPolicy(bridge: .init(teamIdentifier: "synthetic-native-frame", signingIdentifier: "bridge"),
        owner: .init(teamIdentifier: "synthetic-native-frame", signingIdentifier: "owner"), accountIDs: [],
        capabilities: Set(IntegrationScope.allCases.map(\.rawValue)), ownerAuthenticationAge: 30,
        appleIntegration: .init(teamIdentifier: "synthetic-native-frame", signingIdentifier: "apple"))
    var writerPath: String { directory.appendingPathComponent("writer.lock").path }
    var securityWrites: Int { operations.addCount + operations.updateCount }
    var keyReads: Int {
        operations.calls.reduce(into: 0) { count, call in
            if case .copyMatching(let query) = call,
               query[kSecAttrService as String] as? String == "com.58opals.OpalAgent.wrapkey" { count += 1 }
        }
    }
    func fresh() throws -> ServiceAssembly {
        try ServiceAssembly.initializeNew(directory: directory, accessGroup: "test.NativeAssemblyFrames", accounts: seeds,
            operations: operations, policy: policy, effects: { [effects, stateOwner] context in
                stateOwner.bind(context.continuity)
                return ServiceEffectBoundaries(payments: effects, chain: effects, availability: { _ in .init(state: .ready) })
            }, endpoints: { [hosts] in hosts.make($0, handlers: $1) }, clock: clock, generateKey: { [seeds] in seeds.key() })
    }
    func reopen() throws -> ServiceAssembly {
        try ServiceAssembly.reopen(directory: directory, accessGroup: "test.NativeAssemblyFrames", accounts: seeds,
            operations: operations, policy: policy, effects: { [effects, stateOwner] context in
                stateOwner.bind(context.continuity)
                return ServiceEffectBoundaries(payments: effects, chain: effects, availability: { _ in .init(state: .ready) })
            }, endpoints: { [hosts] in hosts.make($0, handlers: $1) }, clock: clock)
    }
    func connect(_ channel: NativeChannel) async throws -> ServiceConnection {
        let identity: SignedPeerIdentity
        switch channel {
        case .owner: identity = policy.owner
        case .integration: identity = policy.bridge
        case .appleAutomation: identity = try #require(policy.appleIntegration)
        }
        return try await hosts.handlers(channel).connect(connectionID: UUID().uuidString, peer: .init(identity: identity, signatureValidated: true))
    }
    func ownerTransport(_ connection: ServiceConnection) throws -> NativeFrameOwnerTransport {
        .init(handlers: try hosts.handlers(.owner), connection: connection, consent: consent)
    }
    func createEnabled(_ client: OwnerControlClient) async throws -> WalletScope {
        guard case .createWallet(let created) = try await client.call(.createWallet(network: .mainnet)), let wallet = created.wallet else {
            throw NativeFrameFailure.result
        }
        #expect(created.availability == .restricted && created.grants.isEmpty)
        guard case .enableWallet(let enabled) = try await client.call(.enableWallet(wallet)) else { throw NativeFrameFailure.result }
        #expect(enabled.availability == .enabled)
        return wallet
    }
    func enroll(_ wallet: WalletScope, client: OwnerControlClient, profile: IntegrationPeerProfile = .mcp) async throws -> OwnerIssuedCredential {
        let request = try EnrollmentRequest(wallet: wallet, integrationID: "native-frame-\(profile.rawValue)",
            accountIDs: [NativeFrameSeeds.accountID], scopes: IntegrationScope.allCases, peerProfile: profile)
        guard case .enrollIntegration(let issued) = try await client.call(.enrollIntegration(request)) else { throw NativeFrameFailure.result }
        return issued
    }
    func state() throws -> CanonicalState {
        if let continuity = stateOwner.current { return try continuity.inspect { $0 } }
        return try #require(try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path, createIfMissing: false).read())
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
private final class NativeFrameState: @unchecked Sendable {
    private let lock = NSLock()
    private weak var continuity: ContinuityCoordinator?
    var current: ContinuityCoordinator? { lock.withLock { continuity } }
    func bind(_ value: ContinuityCoordinator) { lock.withLock { continuity = value } }
}
private final class NativeFrameHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NativeFrameHost] = []
    func make(_ channel: NativeChannel, handlers: ServiceEndpointHandlers) -> any ServiceEndpointHost {
        lock.withLock {
            let host = NativeFrameHost(channel: channel, handlers: handlers)
            values.append(host)
            return host
        }
    }
    func handlers(_ channel: NativeChannel) throws -> ServiceEndpointHandlers {
        try lock.withLock {
            guard let host = values.last(where: { $0.channel == channel }) else { throw NativeFrameFailure.result }
            return host.handlers
        }
    }
}
private final class NativeFrameHost: ServiceEndpointHost, @unchecked Sendable {
    let channel: NativeChannel
    let handlers: ServiceEndpointHandlers
    init(channel: NativeChannel, handlers: ServiceEndpointHandlers) { self.channel = channel; self.handlers = handlers }
    func activate() throws {}
    func invalidate() {}
}
private actor NativeFrameGate {
    private var armed = false
    private(set) var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func arm() { armed = true; hasEntered = false }
    func wait() async {
        guard armed else { return }
        armed = false; hasEntered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private final class NativeFrameFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
private struct NativeFrameClock: PaymentClock {
    func read() -> PaymentClockReading { .init(wall: 1_000, monotonic: 100) }
}
private final class NativeFrameConsent: OwnerConsentProvider, @unchecked Sendable {
    let gate = NativeFrameGate()
    private let lock = NSLock()
    private var fault: NativeFrameConsentFault?
    private var recorded: [OwnerConsentChallenge] = []
    private var previous: OwnerConsentProof?
    var challenges: [OwnerConsentChallenge] { lock.withLock { recorded } }
    func set(_ fault: NativeFrameConsentFault) { lock.withLock { self.fault = fault } }
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        let captured = lock.withLock { () -> (NativeFrameConsentFault?, OwnerConsentProof?) in
            recorded.append(challenge)
            return (fault, previous)
        }
        await gate.wait()
        if captured.0 == .replay { return try #require(captured.1) }
        var review = challenge.reviewCommitment
        if captured.0 == .review { review[0] ^= 1 }
        let changed = OwnerConsentChallenge(connectionID: captured.0 == .connection ? "foreign-connection" : challenge.connectionID,
            nonce: captured.0 == .nonce ? UUID() : challenge.nonce,
            purpose: captured.0 == .purpose ? .enableWallet : challenge.purpose,
            reviewCommitment: review)
        let proof = OwnerConsentProof(challenge: changed, authenticatedAt: captured.0 == .stale ? 969 : 1_000)
        if captured.0 == nil { lock.withLock { previous = proof } }
        return proof
    }
}
private final class NativeFrameSeeds: SeedAccountProvider, @unchecked Sendable {
    static let mnemonic = Data("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8)
    static let accountID = "native-frame-account"
    let derivation = NativeFrameGate()
    private let lock = NSLock()
    private var generatedCount = 0, keyCount = 0
    var generated: Int { lock.withLock { generatedCount } }
    var keys: Int { lock.withLock { keyCount } }
    func key() -> SymmetricKey { lock.withLock { keyCount += 1 }; return SymmetricKey(data: Data(repeating: 0x73, count: 32)) }
    func generateMnemonic() throws -> Data { lock.withLock { generatedCount += 1 }; return Self.mnemonic }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        await derivation.wait()
        guard mnemonic == Self.mnemonic else { throw NativeFrameFailure.result }
        return .init(accountID: Self.accountID, publicDescriptor: Data("synthetic-native-frame-descriptor".utf8))
    }
}
private final class NativeFrameEffects: PaymentExecutionBoundary, AccountChainBoundary, @unchecked Sendable {
    struct Counts: Equatable, Sendable { var sign = 0; var handoff = 0; var observe = 0; var refresh = 0; var address = 0 }
    let result = NativeFrameGate()
    private let lock = NSLock()
    private var observed = Counts()
    private var sent: [Data] = []
    var counts: Counts { lock.withLock { observed } }
    var sentBytes: [Data] { lock.withLock { sent } }
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview {
        .init(operationID: request.operationID, accountID: request.accountID, network: request.network,
            destinationScript: request.destinationScript, amount: request.amount, fee: 100,
            selectedInputs: [String(repeating: "11", count: 32) + ":0"], change: Data(),
            templateDigest: paymentDigest(try paymentEncoding(request)), leaseDeadline: 2_000)
    }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment {
        lock.withLock { observed.sign += 1 }
        let bytes = try paymentEncoding(preview)
        return .init(operationID: preview.operationID, bytes: bytes, digest: paymentDigest(bytes), transactionID: String(repeating: "22", count: 32))
    }
    func preflight(_ payment: SignedPayment) async throws {}
    func validateAdmission(_ payment: SignedPayment) throws {}
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        try admission {
            lock.withLock { observed.handoff += 1; sent.append(payment.bytes) }
            return .init(id: UUID().uuidString, result: { [result] in await result.wait(); return .unknown(source: "synthetic-native-frame") }, cancel: {})
        }
    }
    func dispose(operationID: String) async throws {}
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation {
        lock.withLock { observed.observe += 1 }
        return .init(source: "synthetic-native-frame", view: "view", chainTip: "tip", observedAt: 1_000, complete: true, fresh: true)
    }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        lock.withLock { observed.refresh += 1 }
        return .init(accountID: accountID, network: network, providerID: "synthetic-native-frame", viewID: "view", chainTip: "tip",
            observedAt: 1_000, complete: true, fresh: true, balance: 0, snapshot: Data("{}".utf8), receivingHorizon: -1, changeHorizon: -1)
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        lock.withLock { observed.address += 1 }
        return "synthetic-native-frame-address-\(index)"
    }
}
private func nativeFrameEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw NativeFrameFailure.timeout
}
