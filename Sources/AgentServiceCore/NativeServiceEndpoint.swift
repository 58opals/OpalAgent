import AgentNativeIPC
import AgentValues
import Darwin
import Foundation

/// The host must retain each separately configured endpoint. This source does not install or launch a service.
/// Authority facts are produced only after Foundation delivers a message on an exact signed, same-user peer connection.
final class NativeServiceEndpoint: NSObject, NSXPCListenerDelegate, ServiceEndpointHost, @unchecked Sendable {
    private let deployment: any NativeDeploymentProvider
    private let configured: NativeDeploymentPolicy
    private let channel: NativeChannel
    private let listener: NSXPCListener
    private let handlers: ServiceEndpointHandlers
    private let lock = NSLock()
    private var active = false
    private var closed = false
    private var connections: [String: NativeServiceConnection] = [:]

    init(channel: NativeChannel, deployment: any NativeDeploymentProvider, authorityPolicy: AuthorityPolicy,
         handlers: ServiceEndpointHandlers,
         clock: any PaymentClock = SystemPaymentClock()) throws {
        try deployment.requireQualifiedPrerequisites()
        let configured = try deployment.deployment()
        guard handlers.channel == channel,
              authorityPolicy.bridge == SignedPeerIdentity(teamIdentifier: configured.bridge.teamIdentifier, signingIdentifier: configured.bridge.signingIdentifier),
              authorityPolicy.owner == SignedPeerIdentity(teamIdentifier: configured.wallet.teamIdentifier, signingIdentifier: configured.wallet.signingIdentifier) else {
            throw NativeIPCFailure.untrustedPeer
        }
        if channel == .appleAutomation {
            guard configured.appleIntegrationMachService != nil,
                  authorityPolicy.appleIntegration == SignedPeerIdentity(teamIdentifier: configured.wallet.teamIdentifier,
                      signingIdentifier: configured.wallet.signingIdentifier) else { throw NativeIPCFailure.untrustedPeer }
        }
        self.deployment = deployment; self.configured = configured; self.channel = channel
        self.handlers = handlers
        listener = NSXPCListener(machServiceName: configured.machService(for: channel))
        super.init()
        listener.setConnectionCodeSigningRequirement(configured.peer(for: channel).requirement)
        listener.delegate = self
    }
    func activate() throws {
        try deployment.requireQualifiedPrerequisites()
        try lock.withLock {
            guard !closed, !active else { throw NativeIPCFailure.unavailable }
            active = true
        }
        listener.activate()
    }
    func invalidate() {
        let retained = lock.withLock {
            closed = true; active = false
            let values = Array(connections.values); connections.removeAll(); return values
        }
        listener.invalidate()
        for connection in retained { connection.invalidate() }
    }
    deinit { invalidate() }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard listener === self.listener, connection.effectiveUserIdentifier == geteuid(), connection.processIdentifier > 0,
              (try? deployment.requireQualifiedPrerequisites()) != nil else { return false }
        let state = NativeServiceConnection(connection: connection, channel: channel,
            identity: configured.peer(for: channel), handlers: handlers)
        connection.setCodeSigningRequirement(configured.peer(for: channel).requirement)
        if channel != .owner {
            connection.exportedInterface = NSXPCInterface(with: NativeIntegrationXPC.self)
            connection.exportedObject = NativeIntegrationEndpoint(state: state, handlers: handlers)
        } else {
            connection.exportedInterface = NSXPCInterface(with: NativeOwnerXPC.self)
            connection.remoteObjectInterface = NSXPCInterface(with: NativeWalletConsentXPC.self)
            connection.exportedObject = NativeOwnerEndpoint(state: state, handlers: handlers)
        }
        let remove: @Sendable () -> Void = { [weak self, weak state] in
            state?.invalidate()
            if let state { _ = self?.lock.withLock { self?.connections.removeValue(forKey: state.id) } }
        }
        connection.interruptionHandler = remove
        connection.invalidationHandler = remove
        let accepted = lock.withLock {
            guard active, !closed else { return false }
            connections[state.id] = state
            return true
        }
        guard accepted else { state.invalidate(); return false }
        connection.activate()
        return true
    }
}

/// All mutable session/liveness facts are locked. No request can create this context or replace its physical connection.
private final class NativeServiceConnection: @unchecked Sendable {
    let id = UUID().uuidString
    let channel: NativeChannel
    private let connection: NSXPCConnection
    private let identity: NativeSignedIdentity
    private let handlers: ServiceEndpointHandlers
    private let lock = NSLock()
    private var active = true
    let calls = NativeCallRegistry()
    private var serviceConnection: ServiceConnection?
    private var authenticated = false
    private var pending: [UUID: @Sendable (Result<Data, any Error>) -> Void] = [:]
    init(connection: NSXPCConnection, channel: NativeChannel, identity: NativeSignedIdentity,
         handlers: ServiceEndpointHandlers) {
        self.connection = connection; self.channel = channel; self.identity = identity; self.handlers = handlers
    }
    var isActive: Bool { lock.withLock { active } }
    /// Must be evaluated synchronously inside the exported Objective-C invocation.
    func capture() throws -> PeerEvidence {
        guard NSXPCConnection.current() === connection,
              connection.effectiveUserIdentifier == geteuid(), connection.processIdentifier > 0 else { throw NativeIPCFailure.untrustedPeer }
        return try lock.withLock {
            guard active else { throw NativeIPCFailure.unavailable }
            // setCodeSigningRequirement has already filtered this actual incoming message.
            return PeerEvidence(identity: SignedPeerIdentity(teamIdentifier: identity.teamIdentifier, signingIdentifier: identity.signingIdentifier), signatureValidated: true)
        }
    }
    func open(peer: PeerEvidence) async throws -> ServiceConnection {
        if let retained = try lock.withLock({
            guard active else { throw NativeIPCFailure.unavailable }
            return serviceConnection
        }) { return retained }
        let candidate = try await handlers.connect(connectionID: id, peer: peer)
        let accepted = lock.withLock {
            guard active else { return false }
            if let serviceConnection { return serviceConnection === candidate }
            serviceConnection = candidate
            return true
        }
        guard accepted else {
            candidate.invalidate()
            await handlers.disconnect(candidate)
            throw NativeIPCFailure.unavailable
        }
        return candidate
    }
    func bindAuthenticated(_ handle: ServiceConnection) throws {
        try lock.withLock {
            guard active, channel != .owner, !authenticated,
                  serviceConnection === handle else { throw NativeIPCFailure.unavailable }
            authenticated = true
        }
    }
    func integrationConnection() throws -> ServiceConnection {
        try lock.withLock {
            guard active, channel != .owner, authenticated, let serviceConnection else { throw NativeIPCFailure.unavailable }
            return serviceConnection
        }
    }
    func invalidate() {
        let result = lock.withLock { () -> (Bool, ServiceConnection?, [@Sendable (Result<Data, any Error>) -> Void]) in
            guard active else { return (false, nil, []) }
            let retained = serviceConnection
            // Revoke the same proof token synchronously; actor-queued disconnect is bookkeeping.
            retained?.invalidate()
            active = false; authenticated = false; serviceConnection = nil
            let callbacks = Array(pending.values); pending.removeAll(); return (true, retained, callbacks)
        }
        guard result.0 else { return }
        calls.close(); connection.exportedObject = nil; connection.invalidate()
        if let handle = result.1 {
            let handlers = handlers
            Task { await handlers.disconnect(handle) }
        }
        for callback in result.2 { callback(.failure(NativeIPCFailure.unavailable)) }
    }
    private func complete(_ token: UUID, _ result: Result<Data, any Error>) {
        let callback = lock.withLock { pending.removeValue(forKey: token) }; callback?(result)
    }
    func consent(_ frame: Data) async throws -> Data {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let accepted = lock.withLock {
                    guard active, pending.count < 32, !Task.isCancelled else { return false }
                    pending[token] = { continuation.resume(with: $0) }; return true
                }
                guard accepted else { continuation.resume(throwing: NativeIPCFailure.unavailable); return }
                guard let remote = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in self?.invalidate() }) as? any NativeWalletConsentXPC else {
                    invalidate(); return
                }
                remote.authenticateOwner(frame as NSData) { [weak self] reply in
                    guard let self else { return }
                    guard reply.length > 0, reply.length <= NativeWire.maximumFrameBytes else {
                        self.complete(token, .failure(NativeIPCFailure.malformedFrame)); return
                    }
                    self.complete(token, .success(reply as Data))
                }
            }
        } onCancel: { self.invalidate() }
    }
}

private final class NativeIntegrationEndpoint: NSObject, NativeIntegrationXPC, @unchecked Sendable {
    let state: NativeServiceConnection
    let handlers: ServiceEndpointHandlers
    init(state: NativeServiceConnection, handlers: ServiceEndpointHandlers) {
        self.state = state; self.handlers = handlers
    }
    func hello(_ frame: NSData, reply: @escaping @Sendable (NSData) -> Void) {
        nativeHello(frame, state: state, reply: reply)
    }
    func authenticate(_ frame: NSData, credential: NSData, reply: @escaping @Sendable (NSData) -> Void) {
        var id = UUID()
        do {
            let peer = try state.capture()
            guard frame.length > 0, frame.length <= NativeWire.maximumFrameBytes, credential.length == 32 else { throw NativeIPCFailure.malformedFrame }
            let envelope = try NativeWire.unpack(frame as Data, kind: .authenticate); id = envelope.requestID
            let binding = try NativeWire.decode(NativeHello.self, from: envelope.payload)
            guard state.channel != .owner, binding == NativeHello(channel: state.channel, connectionID: state.id) else { throw NativeIPCFailure.untrustedPeer }
            let requestID = id, credentialBytes = credential as Data
            try state.calls.start { [self] in
                do {
                    guard state.isActive, !Task.isCancelled else { throw NativeIPCFailure.unavailable }
                    let handle = try await state.open(peer: peer)
                    guard state.isActive, !Task.isCancelled else { throw NativeIPCFailure.unavailable }
                    try await handlers.authenticate(credentialBytes, connection: handle)
                    try state.bindAuthenticated(handle)
                    let output = try NativeWire.frame(binding, kind: .authenticated, requestID: requestID)
                    guard state.isActive else { throw NativeIPCFailure.unavailable }
                    reply(output as NSData)
                } catch { reply(NativeWire.problem(.unavailable, requestID: requestID) as NSData) }
            }
        } catch { reply(NativeWire.problem(.unavailable, requestID: id) as NSData) }
    }
    func call(_ frame: NSData, reply: @escaping @Sendable (NSData) -> Void) {
        do {
            _ = try state.capture()
            guard frame.length > 0, frame.length <= NativeWire.maximumFrameBytes else { throw NativeIPCFailure.malformedFrame }
            let handle = try state.integrationConnection(), bytes = frame as Data
            try state.calls.start { [self] in
                guard state.isActive, !Task.isCancelled else { reply(NativeWire.problem(.unavailable, requestID: nativeRequestID(bytes)) as NSData); return }
                let output = await nativeCapabilityFrame(bytes, handlers: handlers, connection: handle)
                guard state.isActive else { reply(NativeWire.problem(.unavailable, requestID: nativeRequestID(bytes)) as NSData); return }
                reply(output as NSData)
            }
        } catch { reply(NativeWire.problem(.unavailable, requestID: nativeRequestID(frame)) as NSData) }
    }
}
private final class NativeOwnerEndpoint: NSObject, NativeOwnerXPC, @unchecked Sendable {
    let state: NativeServiceConnection
    let handlers: ServiceEndpointHandlers
    init(state: NativeServiceConnection, handlers: ServiceEndpointHandlers) { self.state = state; self.handlers = handlers }
    func hello(_ frame: NSData, reply: @escaping @Sendable (NSData) -> Void) { nativeHello(frame, state: state, reply: reply) }
    func call(_ frame: NSData, sensitive: NSData?, reply: @escaping @Sendable (NSData, NSData?) -> Void) {
        do {
            let peer = try state.capture()
            guard frame.length > 0, frame.length <= NativeWire.maximumFrameBytes,
                  sensitive.map({ $0.length <= NativeWire.maximumSensitiveBytes }) ?? true else { throw NativeIPCFailure.malformedFrame }
            let packet = NativeOwnerPacket(frame: frame as Data, sensitive: sensitive.map { $0 as Data })
            try state.calls.start { [self] in
                guard state.isActive, !Task.isCancelled else { reply(NativeWire.problem(.unavailable, requestID: nativeRequestID(packet.frame)) as NSData, nil); return }
                do {
                    let handle = try await state.open(peer: peer)
                    guard state.isActive, !Task.isCancelled else { throw NativeIPCFailure.unavailable }
                    let output = await nativeOwnerFrame(packet, handlers: handlers, connection: handle,
                        consent: NativeConnectionConsentProvider(state: state))
                    guard state.isActive else { throw NativeIPCFailure.unavailable }
                    reply(output.frame as NSData, output.sensitive.map { $0 as NSData })
                } catch { reply(NativeWire.problem(.unavailable, requestID: nativeRequestID(packet.frame)) as NSData, nil) }
            }
        } catch { reply(NativeWire.problem(.unavailable, requestID: nativeRequestID(frame)) as NSData, nil) }
    }
}
private func nativeHello(_ bytes: NSData, state: NativeServiceConnection, reply: @escaping @Sendable (NSData) -> Void) {
    var id = UUID()
    do {
        _ = try state.capture()
        guard bytes.length > 0, bytes.length <= NativeWire.maximumFrameBytes else { throw NativeIPCFailure.malformedFrame }
        let frame = try NativeWire.unpack(bytes as Data, kind: .hello); id = frame.requestID
        let request = try NativeWire.decode(NativeHello.self, from: frame.payload)
        guard request.channel == state.channel, request.connectionID.isEmpty else { throw NativeIPCFailure.untrustedPeer }
        reply(try NativeWire.frame(NativeHello(channel: state.channel, connectionID: state.id), kind: .helloResponse, requestID: id) as NSData)
    } catch { reply(NativeWire.problem(.unavailable, requestID: id) as NSData) }
}
private struct NativeConnectionConsentProvider: OwnerConsentProvider {
    let state: NativeServiceConnection
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        guard state.isActive, challenge.connectionID == state.id else { throw NativeIPCFailure.unavailable }
        let id = UUID()
        let expected = NativeConsentChallenge(connectionID: challenge.connectionID, nonce: challenge.nonce,
            purpose: challenge.purpose.rawValue, reviewCommitment: challenge.reviewCommitment)
        let request = try NativeWire.frame(expected, kind: .consentChallenge, requestID: id)
        let response = try await state.consent(request)
        let frame = try NativeWire.unpack(response, kind: .consentProof, requestID: id)
        let proof = try NativeWire.decode(NativeConsentProof.self, from: frame.payload)
        guard state.isActive, proof.challenge == expected else { throw NativeIPCFailure.untrustedPeer }
        return OwnerConsentProof(challenge: challenge, authenticatedAt: proof.authenticatedAt)
    }
}

extension ServiceAssembly {
    /// Explicit opt-in factory. It grants no prerequisite qualification or service activation.
    static func nativeEndpoints(deployment: any NativeDeploymentProvider, policy: AuthorityPolicy,
                                clock: any PaymentClock = SystemPaymentClock()) -> EndpointFactory {
        { channel, handlers in
            try NativeServiceEndpoint(channel: channel, deployment: deployment,
                authorityPolicy: policy, handlers: handlers, clock: clock)
        }
    }
}

private func nativeCapabilityFrame(_ bytes: Data, handlers: ServiceEndpointHandlers,
                                   connection: ServiceConnection) async -> Data {
    let id = nativeRequestID(bytes)
    do {
        let (_, request) = try NativeWire.decodeCapabilityRequest(bytes)
        let response = try await handlers.capability(request, connection: connection)
        return try NativeWire.capabilityResponse(response, requestID: id)
    } catch { return NativeWire.problem(nativeProblem(error), requestID: id) }
}

private func nativeOwnerFrame(_ packet: NativeOwnerPacket, handlers: ServiceEndpointHandlers,
                              connection: ServiceConnection, consent: any OwnerConsentProvider) async -> NativeOwnerPacket {
    let id = nativeRequestID(packet.frame)
    do {
        let (_, request) = try NativeWire.decodeOwnerRequest(packet)
        let response = try await handlers.owner(request, connection: connection, consent: consent)
        return try NativeWire.ownerResponse(response, requestID: id)
    } catch { return NativeOwnerPacket(frame: NativeWire.problem(nativeProblem(error), requestID: id)) }
}

/// Direct codec/service seam for development fixtures and tests; native adapters use assembly handlers.
/// This proves service behavior and typed framing, not a qualified signed NSXPC connection.
enum NativeServiceFrames {
    static func integration(_ bytes: Data, service: CapabilityService, context: CapabilityConnectionContext) async -> Data {
        let id = nativeRequestID(bytes)
        do {
            let (_, request) = try NativeWire.decodeCapabilityRequest(bytes)
            return try NativeWire.capabilityResponse(await service.handle(request, context: context), requestID: id)
        } catch { return NativeWire.problem(nativeProblem(error), requestID: id) }
    }
    static func owner(_ packet: NativeOwnerPacket, service: OwnerControlService, context: OwnerConnectionContext) async -> NativeOwnerPacket {
        let id = nativeRequestID(packet.frame)
        do {
            let (_, request) = try NativeWire.decodeOwnerRequest(packet)
            return try NativeWire.ownerResponse(await service.send(request, connection: context), requestID: id)
        } catch { return NativeOwnerPacket(frame: NativeWire.problem(nativeProblem(error), requestID: id)) }
    }
}
private func nativeProblem(_ error: any Error) -> ServiceProblemCode {
    if let problem = error as? ServiceProblem { return problem.code }
    if let error = error as? NativeIPCFailure, error == .malformedFrame || error == .incompatibleProtocol { return .invalidRequest }
    return .unavailable
}
private func nativeRequestID(_ bytes: Data) -> UUID { (try? NativeWire.decode(NativeFrame.self, from: bytes).requestID) ?? UUID() }
private func nativeRequestID(_ bytes: NSData) -> UUID {
    guard bytes.length > 0, bytes.length <= NativeWire.maximumFrameBytes else { return UUID() }
    return nativeRequestID(bytes as Data)
}
