#if DEBUG
import AgentClient
import AgentMCP
import AgentNativeIPC
import AgentValues
import CryptoKit
import Darwin
import Foundation
@testable import AgentServiceCore

private struct FixtureRelayEntry: Codable {
    let version: Int
    let epoch: UUID
    let ordinal: Int
    let operationID: String?
    let attempt: UInt64?
    let digest: String
}

/// Only append-only synthetic transport-entry facts live here. Engine admissions are read
/// separately from trusted SQLite/anchor state. fsync is process-death proof, not power-loss proof.
final class FixtureRelayOracle: @unchecked Sendable {
    private let ownership: FixtureProcessOwnership
    private let lock = NSLock()
    init(ownership: FixtureProcessOwnership, resume: Bool) throws {
        self.ownership = ownership
        if !resume { try ownership.writeRootNew(Data(), name: "relay-oracle.jsonl") }
        _ = try entries()
    }
    private func entries() throws -> [FixtureRelayEntry] {
        let data = try ownership.readRoot("relay-oracle.jsonl", maximum: 16_384)
        return try data.split(separator: 10).map { try JSONDecoder().decode(FixtureRelayEntry.self, from: Data($0)) }
    }
    var count: Int { get throws { try lock.withLock { try entries().count } } }
    func append(epoch: UUID, payment: PaymentRecord?, bytes: Data) throws {
        try lock.withLock {
            let previous = try entries()
            guard previous.count < 4 else { throw FixtureFailure.fixtureUnavailable }
            let attempt = payment?.attempts.max(by: { $0.number < $1.number })
            let entry = FixtureRelayEntry(version: 1, epoch: epoch, ordinal: previous.count + 1,
                operationID: payment?.id, attempt: attempt?.number, digest: Self.digest(bytes))
            var data = try JSONEncoder().encode(entry); data.append(10)
            let fd = try ownership.openRoot("relay-oracle.jsonl", flags: O_WRONLY | O_APPEND)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data); try handle.synchronize()
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Installed before actual assembly startup can resume retained work.
private final class FixtureProcessStartup: @unchecked Sendable {
    let ownership: FixtureProcessOwnership
    let resume: Bool
    let socket: FixtureControlSocket
    let epoch: UUID
    private let lock = NSLock()
    private var retainedOracle: FixtureRelayOracle?
    init(ownership: FixtureProcessOwnership, resume: Bool, socket: FixtureControlSocket, epoch: UUID) {
        self.ownership = ownership; self.resume = resume; self.socket = socket; self.epoch = epoch
    }
    var oracle: FixtureRelayOracle { get throws { try lock.withLock {
        guard let retainedOracle else { throw FixtureFailure.fixtureUnavailable }; return retainedOracle
    } } }
    func prepare(chain: FixturePublicChain, inspection: FixtureInspection) throws {
        let oracle = try FixtureRelayOracle(ownership: ownership, resume: resume)
        lock.withLock { retainedOracle = oracle }
        chain.onRelay { bytes in
            let observed = Result { try inspection.inspect { $0 } }
            let payment = (try? observed.get())?.payments.first(where: { $0.canonicalBytes == bytes })
            try oracle.append(epoch: self.epoch, payment: payment, bytes: bytes)
            let state = try observed.get()
            guard let payment, payment.disposition == .submitting, let custody = state.custody else { throw FixtureFailure.fixtureUnavailable }
            let account = try AccountScope(wallet: WalletScope(walletID: custody.walletID, network: .mainnet), accountID: custody.accountID)
            var message = FixtureControlMessage(kind: "relayEntered"); message.epoch = self.epoch
            message.snapshot = try FixtureProcessSession.snapshot(state: state, account: account, oracle: oracle)
            try self.socket.send(message)
        }
    }
}

/// Synthetic reverse consent is held until a correlated decision arrives. It obtains no
/// human/LA proof and never invents a service result. Actual service challenge/frames are used.
actor FixtureProcessConsent: OwnerConsentProvider {
    let socket: FixtureControlSocket
    let clock: FixtureClock
    private var pending: (UUID, OwnerConsentChallenge, CheckedContinuation<OwnerConsentProof, any Error>)?
    private var requestID: UUID?
    init(socket: FixtureControlSocket, clock: FixtureClock) { self.socket = socket; self.clock = clock }
    func begin(_ id: UUID) throws {
        guard requestID == nil else { throw FixtureFailure.fixtureUnavailable }; requestID = id
    }
    func finish() { requestID = nil }
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        guard let id = requestID, pending == nil else { throw FixtureFailure.fixtureUnavailable }
        let native = NativeConsentChallenge(connectionID: challenge.connectionID, nonce: challenge.nonce,
            purpose: challenge.purpose.rawValue, reviewCommitment: challenge.reviewCommitment)
        // Exercise the same public codec on the actual service-generated challenge.
        let frame = try NativeWire.frame(native, kind: .consentChallenge, requestID: id)
        let decoded = try NativeWire.decode(NativeConsentChallenge.self,
            from: NativeWire.unpack(frame, kind: .consentChallenge, requestID: id).payload)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (id, challenge, continuation)
                var reply = FixtureControlMessage(id: id, kind: "consent"); reply.challenge = decoded
                do { try socket.send(reply) }
                catch { pending = nil; continuation.resume(throwing: error) }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func decide(_ message: FixtureControlMessage) throws {
        guard let held = pending, held.0 == message.id, let native = message.challenge,
              native.connectionID == held.1.connectionID, native.nonce == held.1.nonce,
              native.purpose == held.1.purpose.rawValue, native.reviewCommitment == held.1.reviewCommitment,
              let allow = message.allow else { throw FixtureFailure.invalidArguments }
        pending = nil
        if !allow { held.2.resume(throwing: ServiceProblem(.unavailable)); return }
        let proof = NativeConsentProof(challenge: native, authenticatedAt: clock.read().wall)
        let bytes = try NativeWire.frame(proof, kind: .consentProof, requestID: message.id)
        let parsed = try NativeWire.decode(NativeConsentProof.self,
            from: NativeWire.unpack(bytes, kind: .consentProof, requestID: message.id).payload)
        held.2.resume(returning: OwnerConsentProof(challenge: held.1, authenticatedAt: parsed.authenticatedAt))
    }
    func cancel() {
        if let held = pending { pending = nil; held.2.resume(throwing: CancellationError()) }
        requestID = nil
    }
}

final class FixtureProcessSession: @unchecked Sendable {
    let runtime: FixtureRuntime
    let ownership: FixtureProcessOwnership
    let oracle: FixtureRelayOracle
    let socket: FixtureControlSocket
    let consent: FixtureProcessConsent
    let epoch: UUID
    let phases: FixturePhaseController
    let controller: FixtureProcessController
    private init(runtime: FixtureRuntime, ownership: FixtureProcessOwnership, oracle: FixtureRelayOracle,
                 socket: FixtureControlSocket, consent: FixtureProcessConsent, epoch: UUID,
                 phases: FixturePhaseController) {
        self.runtime = runtime; self.ownership = ownership; self.oracle = oracle
        self.socket = socket; self.consent = consent; self.epoch = epoch
        self.phases = phases
        controller = FixtureProcessController(runtime: runtime)
    }
    static func make(socket: FixtureControlSocket) async throws -> FixtureProcessSession {
        let bootstrap = try FixtureControlSocket.message(await socket.receiveAsync())
        let ownership = try FixtureProcessOwnership.attach(bootstrap)
        guard let resume = bootstrap.resume, let epoch = bootstrap.epoch else { throw FixtureFailure.invalidArguments }
        let credential: Data?
        if resume {
            let frame = try await socket.receiveAsync()
            guard frame.0 == 2, frame.1.count == 32 else { throw FixtureFailure.invalidArguments }
            credential = frame.1
        } else { credential = nil }
        let wall = bootstrap.wallTime ?? 1_000
        guard (1_000...1_000_000).contains(wall) else { throw FixtureFailure.invalidArguments }
        let clock = FixtureClock(wall: wall)
        let phases = FixturePhaseController()
        let consent = FixtureProcessConsent(socket: socket, clock: clock)
        let startup = FixtureProcessStartup(ownership: ownership, resume: resume, socket: socket, epoch: epoch)
        let runtime = try await FixtureRuntime.owned(ownership, resume: resume, credential: credential,
            consent: consent, clock: clock, phases: phases, recoveryOnly: bootstrap.recoveryOnly == true,
            beforeStart: { chain, inspection in try startup.prepare(chain: chain, inspection: inspection) })
        let oracle = try startup.oracle
        if !resume {
            try ownership.seal(walletID: runtime.custody.walletID, installationID: runtime.state().installationID,
                accountID: runtime.custody.accountID, profile: runtime.custody.profile, grantID: runtime.grantID)
        }
        let session = FixtureProcessSession(runtime: runtime, ownership: ownership, oracle: oracle,
            socket: socket, consent: consent, epoch: epoch, phases: phases)
        await phases.observe { [weak session] phase in
            guard let session else { throw FixtureFailure.fixtureUnavailable }
            var message = FixtureControlMessage(kind: "phaseReached"); message.epoch = epoch; message.phase = phase.rawValue
            message.snapshot = try session.snapshot(); try socket.send(message)
        }
        var ready = FixtureControlMessage(id: bootstrap.id, kind: "ready"); ready.epoch = epoch
        ready.snapshot = try? session.snapshot()
        ready.grant = try? runtime.grantProjection()
        if !runtime.integrationAvailable { ready.problem = "integrationUnavailable" }
        try socket.send(ready)
        if !resume { try socket.send(kind: 2, payload: runtime.syntheticCredential) }
        return session
    }
    func facts() throws -> FixtureDurableFacts {
        try runtime.inspect { state in
            let reading = runtime.clock.read()
            return FixtureDurableFacts(generation: state.authorization.generation, mode: state.mode.rawValue,
                allGrantsRevoked: state.authorization.grants.allSatisfy(\.revoked),
                allApprovalsInactive: state.approvals.allSatisfy { !$0.active },
                credentialGeneration: state.authorization.grants.first { $0.id == runtime.grantID }?.credentialGeneration,
                receiveRequests: state.requests.filter { $0.method == "create_receive_request" }.count,
                issuedIndices: state.allocations.first { $0.accountID == runtime.account.accountID && $0.branch == "receiving" }?.issuedIndices ?? [],
                ownerReceipts: state.requests.filter { $0.principalID == "owner" && $0.method == "authorize_payment_relay" }.count,
                blocker: state.payments.first?.blocker, keyReads: runtime.keys.reads, chainQueries: runtime.chain.counts.queries,
                clockWall: reading.wall, clockMonotonic: reading.monotonic)
        }
    }
    func snapshot() throws -> FixtureProcessSnapshot {
        try runtime.inspect { state in try Self.snapshot(state: state, account: runtime.account, oracle: oracle) }
    }
    static func snapshot(state: CanonicalState, account: AccountScope, oracle: FixtureRelayOracle) throws -> FixtureProcessSnapshot {
        let payment = state.payments.first
        return FixtureProcessSnapshot(account: account, paymentID: payment?.id,
            requestKey: payment.flatMap { p in state.requests.first { $0.paymentID == p.id && $0.method == "prepare_payment" }?.key }, state: payment?.disposition.rawValue,
            ordinaryAdmissions: payment?.ordinaryAdmissions ?? 0,
            totalAdmissions: state.payments.reduce(0) { $0 + $1.attempts.count },
            gateHeld: payment.map { p in state.gates.contains { $0.liabilityIDs.contains(p.id) } } ?? false,
            byteDigest: payment.flatMap { $0.canonicalBytes.isEmpty ? nil : FixtureRelayOracle.digest($0.canonicalBytes) },
            stateDigest: try state.reference().commitment.map { String(format: "%02x", $0) }.joined(),
            relayEntries: try oracle.count, policyRevision: state.paymentPolicy.revision)
    }
    private func reply(_ message: FixtureControlMessage) async {
        let isController = message.controller == true
        do {
            let call: OwnerControlCall
            switch message.kind {
            case "status": call = .status
            case "listAccounts":
                guard let wallet = message.wallet else { throw FixtureFailure.invalidArguments }; call = .listAccounts(wallet)
            case "listPayments":
                guard let wallet = message.wallet, let page = message.page else { throw FixtureFailure.invalidArguments }
                call = .listPayments(WalletPageRequest(wallet: wallet, page: page))
            case "setApprovalPolicy":
                guard let wallet = message.wallet, let revision = message.expectedRevision, let required = message.approvalRequired else { throw FixtureFailure.invalidArguments }
                call = .setApprovalPolicy(.init(wallet: wallet, expectedRevision: revision, approvalRequired: required))
            case "reviewRelay":
                guard let selector = message.operation else { throw FixtureFailure.invalidArguments }; call = .reviewRelay(selector)
            case "paymentStatus":
                guard let selector = message.operation else { throw FixtureFailure.invalidArguments }; call = .paymentStatus(selector)
            case "reviewPreview":
                guard let selector = message.operation else { throw FixtureFailure.invalidArguments }; call = .reviewPreview(selector)
            case "approveExactPayment":
                guard let context = message.previewContext else { throw FixtureFailure.invalidArguments }; call = .approveExactPayment(context)
            case "authorizeExactRelay":
                guard let context = message.relayContext, let key = message.requestKey else { throw FixtureFailure.invalidArguments }
                call = .authorizeExactRelay(OwnerRelayRequest(requestKey: key, context: context))
            case "relayReceipt":
                guard let wallet = message.wallet, let key = message.requestKey else { throw FixtureFailure.invalidArguments }
                call = .relayReceipt(OwnerReceiptSelector(wallet: wallet, requestKey: key))
            case "recoverJournal":
                guard let wallet = message.wallet else { throw FixtureFailure.invalidArguments }
                call = .recoverJournal(JournalRecoveryRequest(wallet: wallet, source: nil))
            case "rotateGrant":
                if let selector = message.grantSelector { call = .rotateGrant(selector) }
                else {
                    guard let wallet = message.wallet else { throw FixtureFailure.invalidArguments }
                    call = .rotateGrant(try GrantSelector(wallet: wallet, grantID: runtime.grantID))
                }
            case "revokeGrant":
                guard let selector = message.grantSelector else { throw FixtureFailure.invalidArguments }; call = .revokeGrant(selector)
            case "enableWallet":
                guard let wallet = message.wallet else { throw FixtureFailure.invalidArguments }; call = .enableWallet(wallet)
            case "reenrollIntegration":
                guard isController else { throw FixtureFailure.invalidArguments }
                call = .enrollIntegration(try EnrollmentRequest(wallet: runtime.account.wallet,
                    integrationID: "protocol-fixture-integration", accountIDs: [runtime.account.accountID],
                    scopes: [.read, .sync, .receive, .prepare, .submit, .cancel]))
            default: throw FixtureFailure.invalidArguments
            }
            let response: OwnerControlResponse
            if isController { response = try await controller.send(OwnerControlRequest(call: call), id: message.id) }
            else {
                let request = try NativeWire.ownerRequest(OwnerControlRequest(call: call), requestID: message.id)
                response = try await runtime.ownerPacket(request, requestID: message.id, method: call.method)
            }
            var reply = FixtureControlMessage(id: message.id, kind: message.kind == "setApprovalPolicy" ? "policy" : message.kind)
            var sensitive: Data?
            switch response.result {
            case .status(let value): reply.status = value
            case .listAccounts(let value): reply.accounts = value
            case .listPayments(let value): reply.payments = value
            case .setApprovalPolicy(let value): reply.policy = value
            case .paymentStatus(let value), .approveExactPayment(let value): reply.payment = value
            case .reviewPreview(let value): reply.previewContext = value
            case .reviewRelay(let value): reply.relayContext = value
            case .authorizeExactRelay(let value):
                reply.relayReceipt = FixtureRelayReceipt(value)
                try await phases.reach(.ownerReplyProduced)
            case .relayReceipt(let value): reply.relayReceipt = FixtureRelayReceipt(value)
            case .recoverJournal(let value), .enableWallet(let value): reply.status = value
            case .rotateGrant(let value), .enrollIntegration(let value): reply.grant = value.grant; sensitive = value.credential.withBytes { $0 }
            case .revokeGrant(let value): reply.revocation = FixtureGrantRevocation(value)
            default: throw FixtureFailure.fixtureUnavailable
            }
            reply.snapshot = try? snapshot()
            if !isController { await consent.finish() }
            try socket.send(reply, sensitive: sensitive)
        } catch {
            var reply = FixtureControlMessage(id: message.id, kind: "problem")
            reply.problem = (error as? ServiceProblem)?.code.rawValue ?? "unavailable"
            reply.snapshot = try? snapshot()
            if !isController { await consent.finish() }
            try? socket.send(reply)
        }
    }
    private func integrationReply(_ message: FixtureControlMessage) async {
        do {
            var reply = FixtureControlMessage(id: message.id, kind: message.kind)
            reply.payment = try await controller.integration(message)
            reply.snapshot = try? snapshot(); reply.facts = try? facts(); try socket.send(reply)
        } catch {
            var reply = FixtureControlMessage(id: message.id, kind: "problem")
            reply.problem = (error as? ServiceProblem)?.code.rawValue ?? "unavailable"
            reply.snapshot = try? snapshot(); reply.facts = try? facts(); try? socket.send(reply)
        }
    }
    /// Stop, close and EOF share terminal admission closure. Releasing synthetic faults is
    /// a separate cleanup choice; the explicit stop proof keeps them held until parent release.
    private func startShutdown() async -> Task<Void, Never> { await runtime.beginShutdown() }
    private func finish(server: MCPToolServer) async {
        let drain = await startShutdown()
        await consent.cancel(); await runtime.releaseFixtureFaults()
        await drain.value
        await controller.close(); await server.stop()
    }
    func run() async throws {
        let server = MCPToolServer(client: runtime.client)
        try await server.start(transport: FixtureStdioLifetime(ended: {
            let drain = await self.startShutdown()
            await self.consent.cancel()
            // The owned control reader can still release a held synthetic boundary.
            // EOF closes admission but does not silently satisfy that separate test action.
            await drain.value
        }))
        var requests: [Task<Void, Never>] = []
        do {
            var usedIDs = Set<UUID>()
            var integrationIDs = Set<UUID>()
            while true {
                let message = try FixtureControlSocket.message(await socket.receiveAsync())
                switch message.kind {
                case "stop":
                    let drain = await startShutdown()
                    var closed = FixtureControlMessage(id: message.id, kind: "admissionClosed")
                    closed.snapshot = try? snapshot(); closed.facts = try? facts(); try socket.send(closed)
                    requests.append(Task {
                        await drain.value
                        await server.stop()
                        var complete = FixtureControlMessage(id: message.id, kind: "shutdownComplete")
                        complete.snapshot = try? self.snapshot(); complete.facts = try? self.facts()
                        try? self.socket.send(complete)
                    }); continue
                case "close": break
                case "consentDecision": try await consent.decide(message); continue
                case "integrationPrepare", "integrationSubmit", "integrationLookup":
                    guard integrationIDs.count < 256, !usedIDs.contains(message.id), integrationIDs.insert(message.id).inserted else { throw FixtureFailure.invalidArguments }
                    await integrationReply(message); continue
                case "integrationConnect":
                    guard integrationIDs.count < 256, !usedIDs.contains(message.id), integrationIDs.insert(message.id).inserted else { throw FixtureFailure.invalidArguments }
                    await controller.disconnectCurrent()
                    let credential = try await socket.receiveAsync()
                    guard credential.0 == 2, credential.1.count == 32 else { throw FixtureFailure.invalidArguments }
                    do {
                        try await controller.connect(credential.1)
                        var reply = FixtureControlMessage(id: message.id, kind: "connected")
                        reply.snapshot = try? snapshot(); try socket.send(reply)
                    } catch {
                        var reply = FixtureControlMessage(id: message.id, kind: "problem")
                        reply.problem = (error as? ServiceProblem)?.code.rawValue ?? "unavailable"
                        reply.snapshot = try? snapshot(); try socket.send(reply)
                    }
                    continue
                case "armPhase":
                    guard let name = message.phase, let phase = FixturePhase(rawValue: name) else { throw FixtureFailure.invalidArguments }
                    try await phases.arm(phase)
                    try socket.send(FixtureControlMessage(id: message.id, kind: "armed")); continue
                case "releasePhase":
                    await phases.release(); try socket.send(FixtureControlMessage(id: message.id, kind: "released")); continue
                case "relayOutcome":
                    guard let accepted = message.allow else { throw FixtureFailure.invalidArguments }
                    runtime.chain.setAccepted(accepted)
                    try socket.send(FixtureControlMessage(id: message.id, kind: "configured")); continue
                case "releaseRelay":
                    await runtime.chain.relayLatch.open()
                    try socket.send(FixtureControlMessage(id: message.id, kind: "released")); continue
                case "advanceClock":
                    guard let seconds = message.seconds, seconds <= 10_000 else { throw FixtureFailure.invalidArguments }
                    runtime.clock.advance(seconds)
                    var reply = FixtureControlMessage(id: message.id, kind: "facts"); reply.facts = try facts()
                    try socket.send(reply); continue
                case "facts":
                    var reply = FixtureControlMessage(id: message.id, kind: "facts"); reply.facts = try facts()
                    reply.snapshot = try snapshot(); try socket.send(reply); continue
                case "continuePending":
                    try await runtime.continuePending()
                    var reply = FixtureControlMessage(id: message.id, kind: "continued"); reply.snapshot = try snapshot()
                    try socket.send(reply); continue
                case "lookupReceive":
                    guard let key = message.requestKey else { throw FixtureFailure.invalidArguments }
                    let lookup = OperationLookup.request(account: runtime.account, effect: .createReceiveRequest, key: key)
                    guard case .getOperation(.receive(let operation)) = try await runtime.client.call(.getOperation(lookup)) else { throw FixtureFailure.fixtureUnavailable }
                    var reply = FixtureControlMessage(id: message.id, kind: "receive"); reply.receive = operation
                    reply.facts = try facts(); try socket.send(reply); continue
                case "snapshot":
                    guard usedIDs.count < 32, !integrationIDs.contains(message.id), usedIDs.insert(message.id).inserted else { throw FixtureFailure.invalidArguments }
                    var response = FixtureControlMessage(id: message.id, kind: "snapshot"); response.snapshot = try snapshot()
                    try socket.send(response)
                    let bytes = try runtime.state().payments.first?.canonicalBytes ?? Data()
                    try socket.send(kind: 3, payload: bytes)
                    continue
                case "status", "listAccounts", "listPayments", "setApprovalPolicy", "paymentStatus", "reviewPreview", "approveExactPayment", "reviewRelay", "authorizeExactRelay", "relayReceipt", "recoverJournal", "rotateGrant", "revokeGrant", "enableWallet", "reenrollIntegration":
                    guard usedIDs.count < 32, !integrationIDs.contains(message.id), usedIDs.insert(message.id).inserted else { throw FixtureFailure.invalidArguments }
                    // Only one owner request may run at a time; the reader remains available for reverse consent.
                    if message.controller == true {
                        guard ["setApprovalPolicy", "rotateGrant", "revokeGrant", "reenrollIntegration"].contains(message.kind) else { throw FixtureFailure.invalidArguments }
                    } else { try await consent.begin(message.id) }
                    requests.append(Task { await self.reply(message) }); continue
                default: throw FixtureFailure.invalidArguments
                }
                break
            }
        } catch {
            _ = await startShutdown()
            for request in requests { request.cancel() }; await consent.cancel(); await runtime.releaseFixtureFaults()
            for request in requests { await request.value }
            await finish(server: server); socket.close()
            throw error
        }
        _ = await startShutdown()
        for request in requests { request.cancel() }; await consent.cancel(); await runtime.releaseFixtureFaults()
        for request in requests { await request.value }
        await finish(server: server); socket.close()
    }
}

extension FixtureControlSocket {
    func receiveAsync() async throws -> (UInt8, Data) {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { do { continuation.resume(returning: try self.receive()) }
                catch { continuation.resume(throwing: error) } }
        }
    }
}
#endif
