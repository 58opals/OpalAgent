import AgentNativeIPC
import AgentValues
import Darwin
import Foundation

/// A trusted deployment must supply qualified artifacts and native custody prerequisites.
/// Constructing the ordinary factory cannot connect, authenticate, or install a fallback.
public struct NativeClientFactory: Sendable {
    private let deployment: (any NativeDeploymentProvider)?
    public init(deployment: (any NativeDeploymentProvider)? = nil) { self.deployment = deployment }
    public func integrationTransport(credential: Data) throws -> NativeIntegrationTransport {
        guard let deployment, credential.count == 32 else { throw ClientFailure.unavailable }
        try deployment.requireQualifiedPrerequisites()
        return NativeIntegrationTransport(deployment: deployment, policy: try deployment.deployment(), credential: credential)
    }
    public func ownerTransport(consent: any NativeWalletConsentProvider) throws -> NativeOwnerTransport {
        guard let deployment else { throw ClientFailure.unavailable }
        try deployment.requireQualifiedPrerequisites()
        return NativeOwnerTransport(deployment: deployment, policy: try deployment.deployment(), consent: consent)
    }
}

public struct NativeIntegrationTransport: CapabilityTransport, CustomReflectable {
    public var customMirror: Mirror { Mirror(self, children: ["transport": "<native integration transport>"]) }
    private let channel: NativeClientChannel
    fileprivate init(deployment: any NativeDeploymentProvider, policy: NativeDeploymentPolicy, credential: Data) {
        channel = NativeClientChannel(deployment: deployment, policy: policy, channel: .integration, credential: credential, consent: nil)
    }
    public func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        let id = UUID(), link = try await channel.ready()
        let response = try await link.exchange(.integration, packet: NativeOwnerPacket(frame: NativeWire.capabilityRequest(request, requestID: id)))
        return try NativeWire.decodeCapabilityResponse(response.frame, requestID: id)
    }
}
public struct NativeOwnerTransport: OwnerControlTransport, CustomReflectable {
    public var customMirror: Mirror { Mirror(self, children: ["transport": "<native owner transport>"]) }
    private let channel: NativeClientChannel
    fileprivate init(deployment: any NativeDeploymentProvider, policy: NativeDeploymentPolicy, consent: any NativeWalletConsentProvider) {
        channel = NativeClientChannel(deployment: deployment, policy: policy, channel: .owner, credential: nil, consent: consent)
    }
    public func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        let id = UUID(), link = try await channel.ready()
        let packet = try NativeWire.ownerRequest(request, requestID: id)
        try link.consentReceiver?.begin(requestID: id, call: request.call)
        defer { link.consentReceiver?.end(requestID: id) }
        let response = try await link.exchange(.owner, packet: packet)
        return try NativeWire.decodeOwnerResponse(response, requestID: id, method: request.call.method)
    }
}

private actor NativeClientChannel {
    let deployment: any NativeDeploymentProvider
    let policy: NativeDeploymentPolicy
    let channel: NativeChannel
    let credential: Data?
    let consent: (any NativeWalletConsentProvider)?
    var initialization: Task<NativeClientLink, any Error>?
    var initializationID: UUID?
    init(deployment: any NativeDeploymentProvider, policy: NativeDeploymentPolicy, channel: NativeChannel,
         credential: Data?, consent: (any NativeWalletConsentProvider)?) {
        self.deployment = deployment; self.policy = policy; self.channel = channel; self.credential = credential; self.consent = consent
    }
    deinit { initialization?.cancel() }
    func ready() async throws -> NativeClientLink {
        if let initialization {
            let observed = initializationID
            do {
                let link = try await initialization.value
                if link.isActive { return link }
                guard initializationID == observed else { return try await ready() }
                self.initialization = nil; initializationID = nil
            } catch {
                if initializationID == observed { self.initialization = nil; initializationID = nil }
                throw error
            }
        }
        try deployment.requireQualifiedPrerequisites()
        let link = NativeClientLink(policy: policy, channel: channel, consent: consent)
        let task = Task { [channel, credential] in
            do {
                let id = UUID()
                let hello = try NativeWire.frame(NativeHello(channel: channel, connectionID: ""), kind: .hello, requestID: id)
                let response = try await link.exchange(.hello, packet: NativeOwnerPacket(frame: hello))
                let frame = try NativeWire.unpack(response.frame, kind: .helloResponse, requestID: id)
                let greeting = try NativeWire.decode(NativeHello.self, from: frame.payload)
                guard greeting.channel == channel, UUID(uuidString: greeting.connectionID) != nil,
                      link.sameUserPeer else { throw NativeIPCFailure.untrustedPeer }
                link.consentReceiver?.bind(connectionID: greeting.connectionID)
                if channel == .integration {
                    guard let credential, credential.count == 32 else { throw NativeIPCFailure.unavailable }
                    let authID = UUID()
                    let auth = try NativeWire.frame(greeting, kind: .authenticate, requestID: authID)
                    let authenticated = try await link.exchange(.authenticate, packet: NativeOwnerPacket(frame: auth), credential: credential)
                    let ack = try NativeWire.unpack(authenticated.frame, kind: .authenticated, requestID: authID)
                    guard try NativeWire.decode(NativeHello.self, from: ack.payload) == greeting else { throw NativeIPCFailure.untrustedPeer }
                }
                return link
            } catch { link.invalidate(); throw error }
        }
        let generation = UUID()
        initialization = task; initializationID = generation
        do { return try await task.value }
        catch {
            if initializationID == generation { initialization = nil; initializationID = nil }
            throw error
        }
    }
}

private enum NativeExchange: Sendable { case hello, authenticate, integration, owner }
/// Foundation invokes reply, error, and invalidation handlers on queues with no ordering guarantee.
/// This lock owns connection liveness and every continuation; each is removed before resumption.
private final class NativeClientLink: @unchecked Sendable {
    let connection: NSXPCConnection
    let channel: NativeChannel
    let consentReceiver: NativeConsentReceiver?
    private let lock = NSLock()
    private var active = true
    private var pending: [UUID: @Sendable (Result<NativeOwnerPacket, any Error>) -> Void] = [:]
    init(policy: NativeDeploymentPolicy, channel: NativeChannel, consent: (any NativeWalletConsentProvider)?) {
        self.channel = channel
        connection = NSXPCConnection(machServiceName: policy.machService(for: channel), options: [])
        connection.setCodeSigningRequirement(policy.service.requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: channel == .integration ? NativeIntegrationXPC.self : NativeOwnerXPC.self)
        if let consent, channel == .owner {
            consentReceiver = NativeConsentReceiver(connection: connection, provider: consent)
            connection.exportedInterface = NSXPCInterface(with: NativeWalletConsentXPC.self)
            connection.exportedObject = consentReceiver
        } else { consentReceiver = nil }
        connection.interruptionHandler = { [weak self] in self?.invalidate() }
        connection.invalidationHandler = { [weak self] in self?.invalidate() }
        connection.activate()
    }
    deinit { connection.invalidate() }
    var isActive: Bool { lock.withLock { active } }
    var sameUserPeer: Bool { isActive && connection.effectiveUserIdentifier == geteuid() && connection.processIdentifier > 0 }
    func invalidate() {
        let result = lock.withLock { () -> (Bool, [@Sendable (Result<NativeOwnerPacket, any Error>) -> Void]) in
            guard active else { return (false, []) }; active = false
            let callbacks = Array(pending.values); pending.removeAll(); return (true, callbacks)
        }
        guard result.0 else { return }
        consentReceiver?.invalidate()
        connection.invalidate()
        for callback in result.1 { callback(.failure(ClientFailure.unavailable)) }
    }
    private func complete(_ id: UUID, _ result: Result<NativeOwnerPacket, any Error>) {
        let callback = lock.withLock { pending.removeValue(forKey: id) }
        callback?(result)
    }
    func exchange(_ mode: NativeExchange, packet: NativeOwnerPacket, credential: Data? = nil) async throws -> NativeOwnerPacket {
        guard !packet.frame.isEmpty, packet.frame.count <= NativeWire.maximumFrameBytes,
              packet.sensitive.map({ $0.count <= NativeWire.maximumSensitiveBytes }) ?? true else { throw NativeIPCFailure.malformedFrame }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let accepted = lock.withLock {
                    guard active, pending.count < 32, !Task.isCancelled else { return false }
                    pending[token] = { continuation.resume(with: $0) }; return true
                }
                guard accepted else { continuation.resume(throwing: ClientFailure.unavailable); return }
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.invalidate() }
                let reply: @Sendable (NSData, NSData?) -> Void = { [weak self] frame, sensitive in
                    guard let self else { return }
                    guard frame.length > 0, frame.length <= NativeWire.maximumFrameBytes,
                          sensitive.map({ $0.length <= NativeWire.maximumSensitiveBytes }) ?? true else {
                        self.complete(token, .failure(NativeIPCFailure.malformedFrame)); return
                    }
                    self.complete(token, .success(NativeOwnerPacket(frame: frame as Data, sensitive: sensitive.map { $0 as Data })))
                }
                switch mode {
                case .hello:
                    if channel == .integration, let remote = proxy as? any NativeIntegrationXPC { remote.hello(packet.frame as NSData) { reply($0, nil) } }
                    else if let remote = proxy as? any NativeOwnerXPC { remote.hello(packet.frame as NSData) { reply($0, nil) } }
                    else { invalidate() }
                case .authenticate:
                    guard let remote = proxy as? any NativeIntegrationXPC, let credential, credential.count == 32 else { invalidate(); return }
                    remote.authenticate(packet.frame as NSData, credential: credential as NSData) { reply($0, nil) }
                case .integration:
                    guard let remote = proxy as? any NativeIntegrationXPC else { invalidate(); return }
                    remote.call(packet.frame as NSData) { reply($0, nil) }
                case .owner:
                    guard let remote = proxy as? any NativeOwnerXPC else { invalidate(); return }
                    remote.call(packet.frame as NSData, sensitive: packet.sensitive.map { $0 as NSData }, reply: reply)
                }
            }
        } onCancel: { self.invalidate() }
    }
}

/// The callback is exported only on the owner connection. The lock owns its binding and pending reviews.
private final class NativeConsentReceiver: NSObject, NativeWalletConsentXPC, @unchecked Sendable {
    private struct Intent { let purpose: String; let commitment: Data; var nonce: UUID? }
    private weak var connection: NSXPCConnection?
    private let provider: any NativeWalletConsentProvider
    private let lock = NSLock()
    private var active = true
    private var connectionID: String?
    private var intents: [UUID: Intent] = [:]
    private let callbacks = NativeCallRegistry()
    init(connection: NSXPCConnection, provider: any NativeWalletConsentProvider) { self.connection = connection; self.provider = provider }
    func bind(connectionID: String) { lock.withLock { self.connectionID = connectionID } }
    func invalidate() { lock.withLock { active = false; intents.removeAll() }; callbacks.close() }
    func begin(requestID: UUID, call: OwnerControlCall) throws {
        switch call {
        case .status, .inspectRecovery, .listAccounts, .listPayments, .paymentStatus, .reviewPreview, .reviewRelay, .relayReceipt: return
        default: break
        }
        let intent = Intent(purpose: call.method.rawValue, commitment: try NativeWire.reviewCommitment(call), nonce: nil)
        try lock.withLock {
            guard active, connectionID != nil, intents.count < 32 else { throw ClientFailure.unavailable }
            intents[requestID] = intent
        }
    }
    func end(requestID: UUID) { _ = lock.withLock { intents.removeValue(forKey: requestID) } }
    private func accepts(_ challenge: NativeConsentChallenge) -> Bool {
        active && connectionID == challenge.connectionID && intents.values.contains {
            $0.purpose == challenge.purpose && $0.commitment == challenge.reviewCommitment && $0.nonce == challenge.nonce
        }
    }
    func authenticateOwner(_ frame: NSData, reply: @escaping @Sendable (NSData) -> Void) {
        // current() is captured on the exported invocation, before entering async work.
        guard let connection, NSXPCConnection.current() === connection, connection.effectiveUserIdentifier == geteuid(),
              frame.length > 0, frame.length <= NativeWire.maximumFrameBytes else {
            reply(NativeWire.problem(.unavailable, requestID: UUID()) as NSData); return
        }
        let bytes = frame as Data
        do { try callbacks.start { [self] in
            var requestID = UUID()
            do {
                let request = try NativeWire.unpack(bytes, kind: .consentChallenge); requestID = request.requestID
                let challenge = try NativeWire.decode(NativeConsentChallenge.self, from: request.payload)
                try lock.withLock {
                    guard active, connectionID == challenge.connectionID,
                          !intents.values.contains(where: { $0.nonce == challenge.nonce }),
                          let key = intents.first(where: { $0.value.nonce == nil && $0.value.purpose == challenge.purpose && $0.value.commitment == challenge.reviewCommitment })?.key else {
                        throw ClientFailure.unavailable
                    }
                    intents[key]?.nonce = challenge.nonce
                }
                let proof = try await provider.authenticate(challenge)
                guard proof.challenge == challenge, lock.withLock({ accepts(challenge) }) else { throw ClientFailure.unavailable }
                reply(try NativeWire.frame(proof, kind: .consentProof, requestID: requestID) as NSData)
            } catch { reply(NativeWire.problem(.unavailable, requestID: requestID) as NSData) }
        } } catch { reply(NativeWire.problem(.unavailable, requestID: UUID()) as NSData) }
    }
}
