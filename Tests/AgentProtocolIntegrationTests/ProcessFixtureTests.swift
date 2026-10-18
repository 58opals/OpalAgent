import AgentClient
import AgentMCP
import AgentNativeIPC
import AgentValues
import CryptoKit
import Darwin
import Foundation
import MCP
import Testing
@testable import AgentProtocolFixture

private final class OwnedFixtureChild: @unchecked Sendable {
    let pid: pid_t
    let control: FixtureControlSocket
    let input: Int32
    let output: Int32
    private let lock = NSLock()
    private var joined = false
    private var pipesClosed = false
    private var events: [FixtureControlMessage] = []
    private var consentNonces = Set<UUID>()
    private init(pid: pid_t, control: FixtureControlSocket, input: Int32, output: Int32) {
        self.pid = pid; self.control = control; self.input = input; self.output = output
    }
    static func launch(executable: URL) throws -> OwnedFixtureChild {
        var sockets: [Int32] = [0, 0], input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0, pipe(&input) == 0, pipe(&output) == 0 else {
            throw WireFixtureFailure.invalidReply
        }
        // Sources >=10 keep file-action dup2 order independent of inherited descriptor numbering.
        let sourceFDs = try [input[0], output[1], sockets[1]].map { fd -> Int32 in
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw WireFixtureFailure.invalidReply }; return copy
        }
        Darwin.close(input[0]); Darwin.close(output[1]); Darwin.close(sockets[1])
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes); sourceFDs.forEach { Darwin.close($0) } }
        for (source, target) in zip(sourceFDs, [STDIN_FILENO, STDOUT_FILENO, 3]) {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw WireFixtureFailure.invalidReply }
        }
        _ = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let arguments = [executable.path, "--test-control-fd", "3"].map { strdup($0) }
        let environment = ["PATH=/usr/bin:/bin", "TMPDIR=" + FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path].map { strdup($0) }
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        var argv = arguments + [nil], env = environment + [nil], pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &env)
        guard result == 0 else {
            for fd in [input[1], output[0], sockets[0]] { Darwin.close(fd) }
            throw WireFixtureFailure.invalidReply
        }
        return try OwnedFixtureChild(pid: pid, control: FixtureControlSocket(descriptor: sockets[0]), input: input[1], output: output[0])
    }
    func bootstrap(_ ownership: FixtureProcessOwnership, resume: Bool, credential: Data? = nil, wallTime: Int64? = nil) async throws -> FixtureControlMessage {
        var request = FixtureControlMessage(kind: "bootstrap")
        request.namespace = ownership.namespace.path; request.runID = ownership.runID
        request.capability = ownership.capability; request.resume = resume; request.epoch = UUID()
        request.wallTime = wallTime
        try control.send(request)
        if let credential { try control.send(kind: 2, payload: credential) }
        let ready = try FixtureControlSocket.message(await control.receiveAsync())
        #expect(ready.kind == "ready" && ready.id == request.id && ready.epoch == request.epoch)
        return ready
    }
    func snapshot() async throws -> (FixtureProcessSnapshot, Data) {
        let request = FixtureControlMessage(kind: "snapshot"); try control.send(request)
        let reply = try await response(id: request.id)
        #expect(reply.id == request.id && reply.kind == "snapshot")
        let bytes = try await control.receiveAsync()
        #expect(bytes.0 == 3)
        return (try #require(reply.snapshot), bytes.1)
    }
    func response(id: UUID) async throws -> FixtureControlMessage {
        while true {
            let message = try FixtureControlSocket.message(await control.receiveAsync())
            if message.kind == "relayEntered" || message.kind == "phaseReached" {
                lock.withLock { events.append(message) }; continue
            }
            try #require(message.id == id)
            return message
        }
    }
    func event(_ kind: String, phase: String? = nil) async throws -> FixtureControlMessage {
        if let saved = lock.withLock({ () -> FixtureControlMessage? in
            guard let index = events.firstIndex(where: { $0.kind == kind && (phase == nil || $0.phase == phase) }) else { return nil }
            return events.remove(at: index)
        }) { return saved }
        while true {
            let message = try FixtureControlSocket.message(await control.receiveAsync())
            if message.kind == kind && (phase == nil || message.phase == phase) { return message }
            guard message.kind == "relayEntered" || message.kind == "phaseReached" else { throw WireFixtureFailure.invalidReply }
            lock.withLock { events.append(message) }
        }
    }
    func command(_ kind: String, configure: (inout FixtureControlMessage) -> Void = { _ in }) async throws -> FixtureControlMessage {
        var message = FixtureControlMessage(kind: kind); configure(&message)
        try control.send(message)
        let reply = try await response(id: message.id)
        try #require(reply.kind != "problem")
        return reply
    }
    func facts() async throws -> FixtureDurableFacts { try #require(try await command("facts").facts) }
    func ownerBegin(_ message: FixtureControlMessage, call: OwnerControlCall) async throws {
        try control.send(message)
        let challengeMessage = try await response(id: message.id)
        try #require(challengeMessage.kind == "consent")
        let challenge = try #require(challengeMessage.challenge)
        try #require(UUID(uuidString: challenge.connectionID) != nil && challenge.purpose == call.method.rawValue)
        let commitment = try NativeWire.reviewCommitment(call)
        try #require(challenge.reviewCommitment == commitment)
        try #require(lock.withLock { consentNonces.insert(challenge.nonce).inserted })
        var decision = FixtureControlMessage(id: message.id, kind: "consentDecision")
        decision.challenge = challenge; decision.allow = true; try control.send(decision)
    }
    func owner(_ message: FixtureControlMessage, call: OwnerControlCall) async throws -> FixtureControlMessage {
        try await ownerBegin(message, call: call)
        let reply = try await response(id: message.id); try #require(reply.kind != "problem"); return reply
    }
    func join(signal: Int32? = nil) async throws -> Int32 {
        if let signal { guard kill(pid, signal) == 0 else { throw WireFixtureFailure.invalidReply } }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                lock.withLock { joined = true }
                control.close()
                return status
            }
            guard result == 0 || (result < 0 && errno == EINTR) else { throw WireFixtureFailure.invalidReply }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WireFixtureFailure.deadline
    }
    func close() async throws -> Int32 { try control.send(FixtureControlMessage(kind: "close")); return try await join() }
    func closePipes() {
        lock.withLock { guard !pipesClosed else { return }; pipesClosed = true; Darwin.close(input); Darwin.close(output) }
    }
    func terminateIfRunning() async {
        if !lock.withLock({ joined }) { _ = try? await join(signal: SIGKILL) }
    }
    deinit {
        if !lock.withLock({ joined }) {
            var value: Int32 = 0
            // Signal only a still-owned child, never an already-reaped/reused PID.
            if waitpid(pid, &value, WNOHANG) == 0 {
                _ = kill(pid, SIGKILL)
                let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    let result = waitpid(pid, &value, WNOHANG)
                    if result == pid || (result < 0 && errno != EINTR) { break }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }
        closePipes()
    }
}

private final class FixtureTestBundle: NSObject {}

/// SwiftPM builds this executable as a dependency of the test target. Without an explicit
/// binding, use only its exact peer in the currently loaded package test-products directory.
private func fixtureExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
    let path = environment["OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE"]
    let expected = environment["OPAL_AGENT_PROTOCOL_FIXTURE_SHA256"]
    guard (path == nil) == (expected == nil) else { throw FixtureFailure.invalidArguments }
    let url: URL
    if let path {
        guard path.hasPrefix("/"), let expected, expected.count == 64,
              expected.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else { throw FixtureFailure.invalidArguments }
        url = URL(fileURLWithPath: path)
    } else {
        let bundle = Bundle(for: FixtureTestBundle.self).bundleURL.resolvingSymlinksInPath()
        guard ["OpalAgentPackageTests.xctest", "AgentProtocolIntegrationTests.xctest"].contains(bundle.lastPathComponent) else { throw FixtureFailure.fixtureUnavailable }
        url = bundle.deletingLastPathComponent().appendingPathComponent("AgentProtocolFixture")
    }
    guard url.lastPathComponent == "AgentProtocolFixture" else { throw FixtureFailure.invalidArguments }
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw FixtureFailure.fixtureUnavailable }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var facts = stat()
    guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
          facts.st_uid == getuid(), facts.st_mode & 0o111 != 0,
          facts.st_size > 0, facts.st_size <= 512 * 1024 * 1024 else { throw FixtureFailure.fixtureUnavailable }
    let bytes = try file.read(upToCount: Int(facts.st_size) + 1) ?? Data()
    guard bytes.count == facts.st_size,
          expected.map({ FixtureRelayOracle.digest(bytes) == $0 }) ?? true else { throw FixtureFailure.invalidArguments }
    return url
}
private func ownedNamespace() throws -> FixtureProcessOwnership {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    return try FixtureProcessOwnership.create(namespace: parent.appendingPathComponent("opal-process-" + UUID().uuidString, isDirectory: true))
}
private func processCall(_ client: MCP.Client, name: String, arguments: [String: MCP.Value]) async throws -> WireReply {
    let context = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
    let reply = try await context.value
    guard reply.content.count == 1, case let .text(text, _, _) = reply.content[0] else { throw WireFixtureFailure.invalidReply }
    let fields = try JSONDecoder().decode([String: MCP.Value].self, from: Data(text.utf8))
    #expect(reply.structuredContent == .object(fields))
    return WireReply(fields: fields, isError: reply.isError)
}
private func processAccount(_ account: AccountScope) throws -> MCP.Value {
    try JSONDecoder().decode(MCP.Value.self, from: JSONEncoder().encode(account))
}
private func withProcessSDK(_ child: OwnedFixtureChild, name: String,
                            transport suppliedTransport: (any MCP.Transport)? = nil,
                            body: (MCP.Client) async throws -> Void) async throws {
    let client = MCP.Client(name: name, version: "1")
    do {
        let transport: any MCP.Transport = suppliedTransport ?? BoundedStdioTransport(inputDescriptor: child.output, outputDescriptor: child.input)
        let initialized = try await client.connect(transport: transport)
        #expect(initialized.protocolVersion == "2025-11-25")
        try await body(client)
        await client.disconnect() // Transport borrows FDs: join its reader/writer before closing them.
        child.closePipes()
    } catch {
        await client.disconnect()
        await child.terminateIfRunning(); child.closePipes()
        throw error
    }
}

private actor DropCompletedReceiveReply: MCP.Transport {
    nonisolated let logger = MCP.InMemoryTransport().logger
    let base: BoundedStdioTransport
    private var armed = false
    private var target: MCP.Value?
    private(set) var dropped = false
    init(_ child: OwnedFixtureChild) { base = BoundedStdioTransport(inputDescriptor: child.output, outputDescriptor: child.input) }
    func arm() { armed = true }
    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ bytes: Data) async throws {
        if armed, let message = try? JSONDecoder().decode([String: MCP.Value].self, from: bytes),
           message["method"]?.stringValue == "tools/call",
           message["params"]?.objectValue?["name"]?.stringValue == "create_receive_request" {
            target = message["id"]; armed = false
        }
        try await base.send(bytes)
    }
    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await bytes in await base.receive() {
                        if let target, !dropped,
                           let message = try? JSONDecoder().decode([String: MCP.Value].self, from: bytes),
                           message["id"] == target, message["result"] != nil { dropped = true; continue }
                        continuation.yield(bytes)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
private func paymentArguments(_ scope: AccountScope, key requestKey: String) throws -> [String: MCP.Value] {
    ["account": try processAccount(scope), "requestKey": .string(requestKey),
     "destinationAddress": .string(FixtureRuntime.destination), "amountSatoshis": .string("10000")]
}
private func retainedLookup(_ scope: AccountScope, key requestKey: String, effect: String = "preparePayment") throws -> [String: MCP.Value] {
    ["account": try processAccount(scope), "effect": .string(effect), "requestKey": .string(requestKey)]
}
private func prepareProcessPayment(_ child: OwnedFixtureChild, _ client: MCP.Client, scope: AccountScope, key requestKey: String) async throws -> String {
    let prepared = try await processCall(client, name: "prepare_payment", arguments: paymentArguments(scope, key: requestKey))
    let id = try #require(prepared.operationID)
    try await wireEventually("Actual Base preview must complete") {
        try await processCall(client, name: "get_operation", arguments: retainedLookup(scope, key: requestKey)).operation["state"]?.stringValue == "prepared"
    }
    return id
}
private func settleUnknown(_ child: OwnedFixtureChild, _ client: MCP.Client, scope: AccountScope, key requestKey: String, id: String) async throws {
    _ = try await processCall(client, name: "submit_payment", arguments: ["account": try processAccount(scope), "operationID": .string(id)])
    _ = try await child.event("relayEntered")
    _ = try await child.command("releaseRelay")
    try await wireEventually("Entered transport must finish as unknown before the next command") {
        try await processCall(client, name: "get_operation", arguments: retainedLookup(scope, key: requestKey)).operation["state"]?.stringValue == "uncertain"
    }
}

private enum FixturePaymentCrashPrefix: String, CaseIterable {
    case cleanAdmission, heldRelay, acceptedResult, promotedAcceptance
    var relays: Int { self == .cleanAdmission ? 0 : 1 }
}
private func appendProcessProof(scenario: String, children: [(pid_t, UUID)], snapshot: FixtureProcessSnapshot,
                                generation: UInt64, bytesEqual: Bool?, lookupDelta: Int,
                                exits: [Int32] = [], receipt: FixtureRelayReceipt? = nil,
                                facts: FixtureDurableFacts? = nil, operationID: String? = nil,
                                requestKey: String? = nil) throws {
    guard let path = ProcessInfo.processInfo.environment["OPAL_AGENT_PROCESS_RECEIPTS"] else { return }
    var value: [String: Any] = ["scenario": scenario, "children": children.map { ["pid": $0.0, "epoch": $0.1.uuidString] as [String: Any] },
        "joinedExits": exits, "state": snapshot.state as Any? ?? NSNull(),
        "admissions": snapshot.totalAdmissions, "ordinaryAdmissions": snapshot.ordinaryAdmissions,
        "ownerAdmissions": snapshot.totalAdmissions - Int(snapshot.ordinaryAdmissions), "relayEntries": snapshot.relayEntries,
        "gateHeld": snapshot.gateHeld, "generation": generation, "lookupAddedEffects": lookupDelta]
    if let bytesEqual { value["fullBytesEqual"] = bytesEqual }
    if let digest = snapshot.byteDigest { value["byteDigest"] = digest }
    if let id = operationID ?? snapshot.paymentID { value["operationID"] = id }
    if let key = requestKey ?? snapshot.requestKey { value["requestKeyDigest"] = FixtureRelayOracle.digest(Data(key.utf8)) }
    if let receipt {
        value["ownerRequestKeyDigest"] = FixtureRelayOracle.digest(Data(receipt.requestKey.value.utf8))
        value["ownerAttemptID"] = receipt.attempt?.attemptID
        value["ownerContextGeneration"] = receipt.context.walletGeneration
    }
    if let facts {
        value["receiveRequests"] = facts.receiveRequests; value["issuedIndices"] = facts.issuedIndices
        value["grantsAllRevoked"] = facts.allGrantsRevoked; value["approvalsAllInactive"] = facts.allApprovalsInactive
    }
    var line = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); line.append(10)
    let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw WireFixtureFailure.invalidReply }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); try file.write(contentsOf: line); try file.synchronize()
}

@Suite(.serialized) struct FixtureProcessTests {
    @Test func completedReceiveReplyLossAndChildRestartRetainOneAllocation() async throws {
        let ownership = try ownedNamespace()
        let first = try OwnedFixtureChild.launch(executable: fixtureExecutable())
        let ready = try await first.bootstrap(ownership, resume: false)
        let secret = try await first.control.receiveAsync(); try #require(secret.0 == 2 && secret.1.count == 32)
        let scope = try #require(ready.snapshot?.account), requestKey = key(92)
        let args: [String: MCP.Value] = ["account": try processAccount(scope), "requestKey": .string(requestKey)]
        let drop = DropCompletedReceiveReply(first)
        try await withProcessSDK(first, name: "Receive response loss", transport: drop) { client in
            let pending = try await processCall(client, name: "create_receive_request", arguments: args)
            let id = try #require(pending.operationID)
            let lookup = try retainedLookup(scope, key: requestKey, effect: "createReceiveRequest")
            try await wireEventually("Receive allocation must commit before dropping its completed replay") {
                try await processCall(client, name: "get_operation", arguments: lookup).operation["state"]?.stringValue == "allocated"
            }
            let original = try await processCall(client, name: "get_operation", arguments: lookup)
            let before = try await first.facts()
            #expect(before.receiveRequests == 1 && before.issuedIndices == [0])
            await drop.arm()
            let lost = Task { try await processCall(client, name: "create_receive_request", arguments: args) }
            try await wireEventually("Drop only the already-produced allocated reply") { await drop.dropped }
            await client.disconnect()
            await #expect(throws: (any Error).self) { try await lost.value }
            let killed = try await first.join(signal: SIGKILL); #expect(killed & 0x7f == SIGKILL)
            let second = try OwnedFixtureChild.launch(executable: fixtureExecutable())
            let restarted = try await second.bootstrap(ownership, resume: true, credential: secret.1)
            let baseline = try await second.snapshot().0
            let beforeRead = try await second.facts()
            try await withProcessSDK(second, name: "Retained receive new process") { next in
                let restored = try await processCall(next, name: "get_operation", arguments: lookup)
                let replay = try await processCall(next, name: "create_receive_request", arguments: args)
                #expect(restored.operationID == id && restored.operation["state"]?.stringValue == "allocated")
                #expect(restored.operation["allocation"] == original.operation["allocation"] && replay.operation == restored.operation)
                let after = try await second.snapshot().0, facts = try await second.facts()
                #expect(facts.receiveRequests == 1 && facts.issuedIndices == [0] && facts.keyReads == beforeRead.keyReads && facts.chainQueries == beforeRead.chainQueries)
                #expect(after.stateDigest == baseline.stateDigest && after.totalAdmissions == 0 && after.relayEntries == 0)
                let closed = try await second.close(); #expect(closed == 0)
                try appendProcessProof(scenario: "completed-receive-reply-loss", children: [(first.pid, ready.epoch!), (second.pid, restarted.epoch!)], snapshot: after,
                    generation: facts.generation, bytesEqual: nil, lookupDelta: after.totalAdmissions - baseline.totalAdmissions + after.relayEntries - baseline.relayEntries,
                    exits: [killed, closed], facts: facts, operationID: id, requestKey: requestKey)
            }
        }
        try FileManager.default.removeItem(at: ownership.namespace)
    }

    @Test(arguments: [false, true])
    func unsubmittedPaymentDiesWithoutRecreatingLeaseOrIdentity(_ pendingApproval: Bool) async throws {
        let ownership = try ownedNamespace()
        let first = try OwnedFixtureChild.launch(executable: fixtureExecutable())
        let ready = try await first.bootstrap(ownership, resume: false)
        let credential = try await first.control.receiveAsync(); try #require(credential.0 == 2 && credential.1.count == 32)
        let scope = try #require(ready.snapshot?.account), requestKey = key(93)
        if pendingApproval {
            var request = FixtureControlMessage(kind: "setApprovalPolicy"); request.wallet = scope.wallet
            request.expectedRevision = 1; request.approvalRequired = true
            _ = try await first.owner(request, call: .setApprovalPolicy(.init(wallet: scope.wallet, expectedRevision: 1, approvalRequired: true)))
        }
        try await withProcessSDK(first, name: "Unsubmitted preview") { client in
            let id = try await prepareProcessPayment(first, client, scope: scope, key: requestKey)
            let lookup = try retainedLookup(scope, key: requestKey)
            if pendingApproval {
                _ = try await processCall(client, name: "submit_payment", arguments: ["account": try processAccount(scope), "operationID": .string(id)])
                try await wireEventually("Approval state must be trusted before terminating") {
                    try await processCall(client, name: "get_operation", arguments: lookup).operation["state"]?.stringValue == "pendingApproval"
                }
            }
            let before = try await first.snapshot().0
            #expect(before.state == (pendingApproval ? "pendingApproval" : "prepared") && before.totalAdmissions == 0 && before.relayEntries == 0)
            let killed = try await first.join(signal: SIGKILL); #expect(killed & 0x7f == SIGKILL)
            await client.disconnect()
            let second = try OwnedFixtureChild.launch(executable: fixtureExecutable())
            let restarted = try await second.bootstrap(ownership, resume: true, credential: credential.1)
            let baseline = try await second.snapshot().0, beforeRead = try await second.facts()
            #expect(baseline.state == "invalidated" && !baseline.gateHeld && baseline.totalAdmissions == 0 && baseline.relayEntries == 0)
            try await withProcessSDK(second, name: "Invalidated retained preview") { next in
                let retained = try await processCall(next, name: "get_operation", arguments: lookup)
                #expect(retained.operationID == id && retained.operation["state"]?.stringValue == "closed" && retained.operation["terminalReason"]?.stringValue == "invalidated")
                let replay = try await processCall(next, name: "prepare_payment", arguments: paymentArguments(scope, key: requestKey))
                #expect(replay.operation == retained.operation)
                _ = try await processCall(next, name: "submit_payment", arguments: ["account": try processAccount(scope), "operationID": .string(id)])
                let after = try await second.snapshot().0, facts = try await second.facts()
                #expect(after.stateDigest == baseline.stateDigest && after.totalAdmissions == 0 && after.relayEntries == 0 && !after.gateHeld)
                #expect(facts.keyReads == beforeRead.keyReads && facts.chainQueries == beforeRead.chainQueries && facts.allApprovalsInactive)
                let closed = try await second.close(); #expect(closed == 0)
                try appendProcessProof(scenario: pendingApproval ? "pending-approval-restart" : "prepared-restart", children: [(first.pid, ready.epoch!), (second.pid, restarted.epoch!)],
                    snapshot: after, generation: facts.generation, bytesEqual: nil, lookupDelta: after.totalAdmissions + after.relayEntries, exits: [killed, closed], facts: facts)
            }
        }
        try FileManager.default.removeItem(at: ownership.namespace)
    }
    @Test(arguments: FixturePaymentCrashPrefix.allCases)
    private func actualBaseRelayAndOriginalKeySurviveOwnedChildDeath(_ prefix: FixturePaymentCrashPrefix) async throws {
        let executable = try fixtureExecutable()
        let ownership = try ownedNamespace()
        let first = try OwnedFixtureChild.launch(executable: executable)
        let ready = try await first.bootstrap(ownership, resume: false)
        let credentialFrame = try await first.control.receiveAsync()
        #expect(credentialFrame.0 == 2 && credentialFrame.1.count == 32)
        let credential = credentialFrame.1 // Dedicated memory only: never serialized into receipts/config/arguments.
        let scope = try #require(ready.snapshot?.account)
        let account = try processAccount(scope)
        if prefix == .cleanAdmission {
            _ = try await first.command("armPhase") { $0.phase = "beforeHandoff" }
        }
        if prefix == .acceptedResult {
            _ = try await first.command("armPhase") { $0.phase = "acceptedResult" }
        }
        if prefix == .acceptedResult || prefix == .promotedAcceptance {
            _ = try await first.command("relayOutcome") { $0.allow = true }
            _ = try await first.command("releaseRelay")
        }
        try await withProcessSDK(first, name: "Process restart proof") { client in
        let requestKey = key(91)
        let prepared = try await processCall(client, name: "prepare_payment", arguments: ["account": account,
            "requestKey": .string(requestKey), "destinationAddress": .string(FixtureRuntime.destination), "amountSatoshis": .string("10000")])
        let id = try #require(prepared.operationID)
        let lookup: [String: MCP.Value] = ["account": account, "effect": .string("preparePayment"), "requestKey": .string(requestKey)]
        try await wireEventually("Actual Base preparation must complete before submit") {
            try await processCall(client, name: "get_operation", arguments: lookup).operation["state"]?.stringValue == "prepared"
        }
        _ = try await processCall(client, name: "submit_payment", arguments: ["account": account, "operationID": .string(id)])
        if prefix == .cleanAdmission { _ = try await first.event("phaseReached", phase: "beforeHandoff") }
        else if prefix == .acceptedResult { _ = try await first.event("phaseReached", phase: "acceptedResult") }
        else if prefix == .heldRelay { _ = try await first.event("relayEntered") }
        else {
            try await wireEventually("Accepted receipt must finish promotion before the clean kill") {
                try await processCall(client, name: "get_operation", arguments: lookup).operation["state"]?.stringValue == "accepted"
            }
        }
        let (before, beforeBytes) = try await first.snapshot()
        #expect(before.paymentID == id && before.requestKey == requestKey && before.state == (prefix == .promotedAcceptance ? "accepted" : "submitting"))
        #expect(before.ordinaryAdmissions == 1 && before.totalAdmissions == 1 && before.relayEntries == prefix.relays && before.gateHeld)
        #expect(!beforeBytes.isEmpty && before.byteDigest == FixtureRelayOracle.digest(beforeBytes))
        let exit = try await first.join(signal: SIGKILL)
        #expect(exit & 0x7f == SIGKILL)
        await client.disconnect()
        let oraclePath = ownership.namespace.appendingPathComponent("relay-oracle.jsonl")
        let durableOracle = try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384)
        let entries = durableOracle.split(separator: 10)
        #expect(entries.count == prefix.relays)
        if prefix.relays == 1 {
            let firstOracleLine = try #require(entries.first)
            let entry = try #require(try JSONSerialization.jsonObject(with: Data(firstOracleLine)) as? [String: Any])
            #expect(entry["ordinal"] as? Int == 1 && entry["operationID"] as? String == id && entry["digest"] as? String == before.byteDigest)
            #expect(entry["version"] as? Int == 1 && entry["attempt"] as? Int == 1 && entry["epoch"] as? String == ready.epoch?.uuidString)
        }

        let second = try OwnedFixtureChild.launch(executable: executable)
        let restarted = try await second.bootstrap(ownership, resume: true, credential: credential)
        #expect(restarted.epoch != ready.epoch)
        let (after, afterBytes) = try await second.snapshot()
        let retainedState = prefix == .promotedAcceptance ? "accepted" : "uncertain"
        #expect(after.paymentID == id && after.requestKey == requestKey && after.state == retainedState)
        #expect(after.ordinaryAdmissions == 1 && after.totalAdmissions == 1 && after.relayEntries == prefix.relays && after.gateHeld)
        let fullBytesEqualAfterRestart = afterBytes == beforeBytes
        #expect(fullBytesEqualAfterRestart && after.byteDigest == before.byteDigest)
        try await withProcessSDK(second, name: "New connection original grant") { next in
        let result = try await processCall(next, name: "get_operation", arguments: lookup)
        #expect(result.isError != true && result.operationID == id && result.operation["state"]?.stringValue == retainedState)
        #expect(result.operation["ordinaryAdmissions"]?.stringValue == "1")
        let (lookupAfter, lookupBytes) = try await second.snapshot()
        #expect(lookupAfter.stateDigest == after.stateDigest && lookupAfter.totalAdmissions == 1 && lookupAfter.relayEntries == prefix.relays)
        let fullBytesEqualAfterLookup = lookupBytes == beforeBytes
        #expect(fullBytesEqualAfterLookup && lookupAfter.gateHeld)
        #expect(try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384) == durableOracle)
        let cleanExit = try await second.close()
        #expect(cleanExit == 0)
        await next.disconnect()
        try appendProcessProof(scenario: "payment-" + prefix.rawValue, children: [(first.pid, ready.epoch!), (second.pid, restarted.epoch!)],
            snapshot: lookupAfter, generation: 1, bytesEqual: fullBytesEqualAfterRestart && fullBytesEqualAfterLookup,
            lookupDelta: lookupAfter.totalAdmissions - after.totalAdmissions + lookupAfter.relayEntries - after.relayEntries,
            exits: [exit, cleanExit])
        if prefix == .heldRelay, let receipt = ProcessInfo.processInfo.environment["OPAL_AGENT_PROCESS_RECEIPT"] {
            let value: [String: Any] = ["scenario": "held-relay-child-restart", "firstPID": first.pid, "secondPID": second.pid,
                "firstEpoch": ready.epoch!.uuidString, "secondEpoch": restarted.epoch!.uuidString,
                "killSignal": SIGKILL, "joined": true, "admissions": 1, "relayEntries": 1,
                "fullBytesEqual": afterBytes == beforeBytes && lookupBytes == beforeBytes,
                "byteDigest": before.byteDigest!, "lookupAddedEffects": 0, "state": "uncertain", "gateHeld": true]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: receipt), options: .atomic)
        }
        }
        }
        try FileManager.default.removeItem(at: ownership.namespace)
    }

    @Test func actualOwnerFramesHoldReleaseAndCancelPurposeBoundConsent() async throws {
        let ownership = try ownedNamespace()
        let child = try OwnedFixtureChild.launch(executable: fixtureExecutable())
        let ready = try await child.bootstrap(ownership, resume: false)
        let credential = try await child.control.receiveAsync(); #expect(credential.0 == 2)
        let wallet = try #require(ready.snapshot?.account.wallet)
        func status() async throws -> FixtureControlMessage {
            let request = FixtureControlMessage(kind: "status"); try child.control.send(request)
            let reply = try FixtureControlSocket.message(await child.control.receiveAsync())
            #expect(reply.id == request.id && reply.kind == "status"); return reply
        }
        let initial = try await status()
        #expect(initial.status?.approvalPolicy?.approvalRequired == false && initial.snapshot?.policyRevision == 1)
        var mutation = FixtureControlMessage(kind: "setApprovalPolicy"); mutation.wallet = wallet
        mutation.expectedRevision = 1; mutation.approvalRequired = true; try child.control.send(mutation)
        let challenge = try FixtureControlSocket.message(await child.control.receiveAsync())
        #expect(challenge.kind == "consent" && challenge.id == mutation.id && challenge.challenge?.purpose == "setApprovalPolicy")
        let held = try await child.snapshot().0
        #expect(held.stateDigest == initial.snapshot?.stateDigest && held.totalAdmissions == 0 && held.relayEntries == 0)
        var decision = FixtureControlMessage(id: mutation.id, kind: "consentDecision")
        decision.challenge = challenge.challenge; decision.allow = true; try child.control.send(decision)
        let changed = try FixtureControlSocket.message(await child.control.receiveAsync())
        #expect(changed.id == mutation.id && changed.kind == "policy" && changed.policy?.revision == 2 && changed.policy?.approvalRequired == true)
        let actual = try await status()
        #expect(actual.status?.approvalPolicy == changed.policy && actual.snapshot?.totalAdmissions == 0 && actual.snapshot?.relayEntries == 0)
        var cancellation = FixtureControlMessage(kind: "setApprovalPolicy"); cancellation.wallet = wallet
        cancellation.expectedRevision = 2; cancellation.approvalRequired = false; try child.control.send(cancellation)
        let deniedChallenge = try FixtureControlSocket.message(await child.control.receiveAsync())
        var denial = FixtureControlMessage(id: cancellation.id, kind: "consentDecision")
        denial.challenge = deniedChallenge.challenge; denial.allow = false; try child.control.send(denial)
        let denied = try FixtureControlSocket.message(await child.control.receiveAsync())
        #expect(denied.kind == "problem" && denied.id == cancellation.id && denied.problem == "unavailable")
        let after = try await status()
        #expect(after.status?.approvalPolicy == changed.policy && after.snapshot?.stateDigest == actual.snapshot?.stateDigest)
        #expect(after.snapshot?.totalAdmissions == 0 && after.snapshot?.relayEntries == 0)
        // Close an additional pending challenge: cancellation joins without applying the mutation.
        var closing = cancellation; closing = FixtureControlMessage(kind: "setApprovalPolicy")
        closing.wallet = wallet; closing.expectedRevision = 2; closing.approvalRequired = false
        try child.control.send(closing)
        let closingChallenge = try FixtureControlSocket.message(await child.control.receiveAsync())
        #expect(closingChallenge.kind == "consent")
        #expect(try await child.close() == 0)
        child.closePipes()
        try FileManager.default.removeItem(at: ownership.namespace)
    }

    @Test(arguments: [false, true])
    func consumedOwnerReceiptSurvivesLostReplyAndRecoveryGeneration(_ recover: Bool) async throws {
        let ownership = try ownedNamespace()
        let first = try OwnedFixtureChild.launch(executable: fixtureExecutable())
        let ready = try await first.bootstrap(ownership, resume: false)
        let secret = try await first.control.receiveAsync(); try #require(secret.0 == 2 && secret.1.count == 32)
        let scope = try #require(ready.snapshot?.account), paymentKey = key(94), ownerKey = try RequestKey(key(95))
        var killed: Int32 = 0, originalBytes = Data(), originalContext: ExactRelayReviewContext?
        try await withProcessSDK(first, name: "Ordinary then independent owner relay") { client in
            let id = try await prepareProcessPayment(first, client, scope: scope, key: paymentKey)
            try await settleUnknown(first, client, scope: scope, key: paymentKey, id: id)
            let before = try await first.snapshot(); #expect(before.0.ordinaryAdmissions == 1 && before.0.totalAdmissions == 1 && before.0.relayEntries == 1)
            originalBytes = before.1
            let selector = try OperationSelector(account: scope, operationID: id)
            let reviewed = try await first.command("reviewRelay") { $0.operation = selector }
            let context = try #require(reviewed.relayContext); originalContext = context
            _ = try await first.command("armPhase") { $0.phase = "ownerReplyProduced" }
            var request = FixtureControlMessage(kind: "authorizeExactRelay"); request.requestKey = ownerKey; request.relayContext = context
            // The original key/context is retained here before dispatch. Hold the actual
            // produced response, then kill; neither a replacement result nor key is supplied.
            try await first.ownerBegin(request, call: .authorizeExactRelay(.init(requestKey: ownerKey, context: context)))
            _ = try await first.event("phaseReached", phase: "ownerReplyProduced")
            _ = try await first.event("relayEntered")
            let consumed = try await first.snapshot()
            let exact = consumed.1 == originalBytes
            #expect(exact && consumed.0.totalAdmissions == 2 && consumed.0.ordinaryAdmissions == 1 && consumed.0.relayEntries == 2 && consumed.0.gateHeld)
            killed = try await first.join(signal: SIGKILL); #expect(killed & 0x7f == SIGKILL)
            await client.disconnect()
        }
        let context = try #require(originalContext)
        let second = try OwnedFixtureChild.launch(executable: fixtureExecutable())
        let restarted = try await second.bootstrap(ownership, resume: true, credential: secret.1)
        var active = second
        var children = [(first.pid, ready.epoch!), (second.pid, restarted.epoch!)]
        var exits = [killed]
        let historical = try await second.command("relayReceipt") { $0.wallet = scope.wallet; $0.requestKey = ownerKey }
        let original = try #require(historical.relayReceipt)
        #expect(original.requestKey == ownerKey && original.context == context && original.outcome == .admitted && original.attempt?.number == 2)
        if recover {
            let beforeRecovery = try await second.facts()
            var request = FixtureControlMessage(kind: "recoverJournal"); request.wallet = scope.wallet
            let reset = try await second.owner(request, call: .recoverJournal(.init(wallet: scope.wallet, source: nil)))
            #expect(reset.status?.availability == .restricted && reset.status?.walletGeneration == 2)
            let facts = try await second.facts(), held = try await second.snapshot()
            let exact = held.1 == originalBytes
            #expect(exact && facts.mode == "restricted" && facts.generation == 2 && facts.allGrantsRevoked && facts.allApprovalsInactive)
            #expect(facts.keyReads == beforeRecovery.keyReads && facts.receiveRequests == 0 && held.0.totalAdmissions == 2 && held.0.relayEntries == 2 && held.0.ordinaryAdmissions == 1 && held.0.gateHeld)
            let terminated = try await second.join(signal: SIGKILL); #expect(terminated & 0x7f == SIGKILL)
            second.closePipes(); exits.append(terminated)
            let third = try OwnedFixtureChild.launch(executable: fixtureExecutable())
            let afterRecovery = try await third.bootstrap(ownership, resume: true, credential: secret.1)
            #expect(afterRecovery.problem == "integrationUnavailable")
            active = third; children.append((third.pid, afterRecovery.epoch!))
            let ownerStatus = try await third.command("status")
            #expect(ownerStatus.status?.availability == .restricted && ownerStatus.status?.walletGeneration == 2)
            let noKeys = try await third.facts(); #expect(noKeys.keyReads == 0)
        }
        let baseline = try await active.snapshot(), factsBefore = try await active.facts()
        let looked = try await active.command("relayReceipt") { $0.wallet = scope.wallet; $0.requestKey = ownerKey }
        let receipt = try #require(looked.relayReceipt)
        #expect(receipt.context == original.context && receipt.requestKey == original.requestKey && receipt.attempt == original.attempt && receipt.outcome == original.outcome)
        var replay = FixtureControlMessage(kind: "authorizeExactRelay"); replay.requestKey = ownerKey; replay.relayContext = context
        let result = try await active.owner(replay, call: .authorizeExactRelay(.init(requestKey: ownerKey, context: context)))
        let replayed = try #require(result.relayReceipt)
        #expect(replayed.context == context && replayed.requestKey == ownerKey && replayed.attempt == receipt.attempt && replayed.outcome == .admitted)
        #expect(replayed.payment.identity.selector == context.operation && replayed.payment.ordinaryAdmissions == 1 && replayed.payment.liabilityUnresolved)
        let after = try await active.snapshot(), factsAfter = try await active.facts()
        let exact = after.1 == originalBytes && baseline.1 == originalBytes
        #expect(exact && after.0.stateDigest == baseline.0.stateDigest && after.0.totalAdmissions == 2 && after.0.ordinaryAdmissions == 1 && after.0.relayEntries == 2 && after.0.gateHeld)
        #expect(factsAfter.ownerReceipts == 1 && factsAfter.keyReads == factsBefore.keyReads && factsAfter.generation == (recover ? 2 : 1))
        let closed = try await active.close(); #expect(closed == 0); active.closePipes(); exits.append(closed)
        try appendProcessProof(scenario: recover ? "consumed-owner-receipt-restricted-generation" : "consumed-owner-receipt-restart", children: children,
            snapshot: after.0, generation: factsAfter.generation, bytesEqual: exact,
            lookupDelta: after.0.totalAdmissions - baseline.0.totalAdmissions + after.0.relayEntries - baseline.0.relayEntries,
            exits: exits, receipt: replayed, facts: factsAfter)
        try FileManager.default.removeItem(at: ownership.namespace)
    }

    @Test(arguments: [false, true])
    func newProcessDelayAndRotatedOriginNeverRefillOrdinaryAuthority(_ rotated: Bool) async throws {
        let ownership = try ownedNamespace()
        let first = try OwnedFixtureChild.launch(executable: fixtureExecutable())
        let ready = try await first.bootstrap(ownership, resume: false)
        let originalCredential = try await first.control.receiveAsync(); try #require(originalCredential.0 == 2 && originalCredential.1.count == 32)
        let scope = try #require(ready.snapshot?.account), requestKey = key(96)
        var currentCredential = originalCredential.1, originalBytes = Data(), wall: Int64 = 1_000, id = "", firstExit: Int32 = 0
        try await withProcessSDK(first, name: "Known original authority") { client in
            id = try await prepareProcessPayment(first, client, scope: scope, key: requestKey)
            try await settleUnknown(first, client, scope: scope, key: requestKey, id: id)
            originalBytes = try await first.snapshot().1
            if rotated {
                var rotation = FixtureControlMessage(kind: "rotateGrant"); rotation.wallet = scope.wallet
                let result = try await first.owner(rotation, call: .rotateGrant(try GrantSelector(wallet: scope.wallet, grantID: "protocol-fixture-grant")))
                #expect(result.grant?.credentialGeneration == 2)
                let credential = try await first.control.receiveAsync(); try #require(credential.0 == 2 && credential.1.count == 32)
                currentCredential = credential.1
                let old = try await processCall(client, name: "get_operation", arguments: retainedLookup(scope, key: requestKey))
                #expect(old.isError == true && old.errorCode == "unavailable")
            }
            let advanced = try await first.command("advanceClock") { $0.seconds = 1_000 }
            wall = try #require(advanced.facts?.clockWall)
            #expect(wall > 1_030)
            firstExit = try await first.join(signal: SIGKILL); #expect(firstExit & 0x7f == SIGKILL)
            await client.disconnect()
        }
        let second = try OwnedFixtureChild.launch(executable: fixtureExecutable())
        let restarted = try await second.bootstrap(ownership, resume: true, credential: currentCredential, wallTime: wall)
        try #require(restarted.problem == nil)
        let clock = try await second.facts()
        #expect(clock.clockWall == wall && clock.clockMonotonic == 100 && clock.credentialGeneration == (rotated ? 2 : 1))
        try await withProcessSDK(second, name: "New current connection original operation") { next in
            let (beforeSnapshot, beforeBytes): (FixtureProcessSnapshot, Data) = try await second.snapshot()
            let lookup = try retainedLookup(scope, key: requestKey)
            let current = try await processCall(next, name: "get_operation", arguments: lookup)
            #expect(current.isError != true && current.operationID == id && current.operation["ordinaryAdmissions"]?.stringValue == "1")
            let afterLookup = try await second.snapshot().0
            #expect(afterLookup.stateDigest == beforeSnapshot.stateDigest && afterLookup.totalAdmissions == 1 && afterLookup.relayEntries == 1)
            _ = try await second.command("advanceClock") { $0.seconds = rotated ? 1_000 : 29 }
            if rotated {
                _ = try await processCall(next, name: "submit_payment", arguments: ["account": try processAccount(scope), "operationID": .string(id)])
                _ = try await second.command("continuePending")
                try await wireEventually("Rotated origin must deny despite two unused ordinary slots") { try await second.facts().blocker == "staleContext" }
            } else {
                _ = try await second.command("continuePending")
                try await wireEventually("New runtime must wait its own full delay") { try await second.facts().blocker == "relayNotEligible" }
                let early = try await second.snapshot().0
                #expect(early.totalAdmissions == 1)
                #expect(early.relayEntries == 1)
                #expect(early.ordinaryAdmissions == 1)
                _ = try await second.command("advanceClock") { $0.seconds = 1 }
                _ = try await second.command("releaseRelay")
                _ = try await second.command("continuePending")
                _ = try await second.event("relayEntered")
                try await wireEventually("Exactly one identical-byte retry may finish after the new delay") {
                    let snapshot = try await second.snapshot().0
                    return snapshot.state == "uncertain" && snapshot.ordinaryAdmissions == 2
                }
            }
            let (afterSnapshot, afterBytes): (FixtureProcessSnapshot, Data) = try await second.snapshot()
            let facts = try await second.facts()
            let expected = rotated ? 1 : 2
            let originalBytesRetained = beforeBytes == originalBytes
            let restartedBytesRetained = afterBytes == originalBytes
            let exact = [originalBytesRetained, restartedBytesRetained].allSatisfy { $0 }
            #expect(originalBytesRetained)
            #expect(restartedBytesRetained)
            #expect(afterSnapshot.totalAdmissions == expected)
            #expect(afterSnapshot.ordinaryAdmissions == UInt64(expected))
            #expect(afterSnapshot.relayEntries == expected)
            #expect(afterSnapshot.gateHeld)
            #expect(facts.ownerReceipts == 0 && facts.receiveRequests == 0)
            let closed = try await second.close(); #expect(closed == 0)
            try appendProcessProof(scenario: rotated ? "rotated-origin-two-unused-slots" : "fresh-runtime-full-retry-delay", children: [(first.pid, ready.epoch!), (second.pid, restarted.epoch!)],
                snapshot: afterSnapshot, generation: facts.generation, bytesEqual: exact,
                lookupDelta: afterLookup.totalAdmissions - beforeSnapshot.totalAdmissions + afterLookup.relayEntries - beforeSnapshot.relayEntries,
                exits: [firstExit, closed], facts: facts)
        }
        try FileManager.default.removeItem(at: ownership.namespace)
    }
}

private enum FixtureOwnershipNegative: String, CaseIterable { case capability, adopted, symlink, profile, format }
@Test(arguments: FixtureOwnershipNegative.allCases)
private func ownedFixtureRejectsForeignCapabilityAndStateWithoutOpeningStorage(_ failure: FixtureOwnershipNegative) throws {
    let ownership = try ownedNamespace()
    defer { try? FileManager.default.removeItem(at: ownership.namespace) }
    var bootstrap = FixtureControlMessage(kind: "bootstrap")
    bootstrap.namespace = ownership.namespace.path; bootstrap.runID = ownership.runID
    bootstrap.capability = ownership.capability; bootstrap.resume = true; bootstrap.epoch = UUID()
    if failure == .capability {
        var wrong = ownership.capability; wrong[0] ^= 1; bootstrap.capability = wrong
        #expect(throws: FixtureFailure.invalidArguments) { try FixtureProcessOwnership.attach(bootstrap) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: ownership.namespace.path) == ["owner.json"])
        return
    }
    if failure == .adopted {
        try FileManager.default.removeItem(at: ownership.namespace.appendingPathComponent("owner.json"))
        #expect(throws: (any Error).self) { try FixtureProcessOwnership.attach(bootstrap) }
        return
    }
    try ownership.prepare(resume: false)
    let marker = Data("not a SQLite database; must remain unopened".utf8)
    for name in ["journal.sqlite", "independent-anchor.json", "writer.lock"] {
        try FixtureProcessOwnership.writeNew(marker, to: ownership.directory.appendingPathComponent(name))
    }
    try FixtureProcessOwnership.writeNew(Data(), to: ownership.namespace.appendingPathComponent("relay-oracle.jsonl"))
    try ownership.seal(walletID: "protocol-fixture-wallet", installationID: "protocol-fixture-installation",
        accountID: "fixture-account", profile: failure == .profile ? "foreign-profile" : "bip39-empty/bip44-145-0/v1")
    if failure == .format {
        let path = ownership.namespace.appendingPathComponent("store.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]); object["version"] = 2
        try FileManager.default.removeItem(at: path)
        try FixtureProcessOwnership.writeNew(JSONSerialization.data(withJSONObject: object), to: path)
    }
    var relocated: URL?
    defer { if let relocated { try? FileManager.default.removeItem(at: relocated) } }
    if failure == .symlink {
        let original = ownership.namespace.deletingLastPathComponent().appendingPathComponent("opal-marker-" + UUID().uuidString)
        try FileManager.default.moveItem(at: ownership.directory, to: original)
        relocated = original
        try FileManager.default.createSymbolicLink(at: ownership.directory, withDestinationURL: original)
    }
    let bytes = try Data(contentsOf: ownership.directory.appendingPathComponent("journal.sqlite"))
    #expect(throws: (any Error).self) { try FixtureProcessOwnership.attach(bootstrap).prepare(resume: true) }
    #expect(try Data(contentsOf: ownership.directory.appendingPathComponent("journal.sqlite")) == bytes && bytes == marker)
}

private enum FixtureBindingNegative: CaseIterable { case partialPath, partialHash, wrongName, wrongHash }
@Test(arguments: FixtureBindingNegative.allCases)
private func fixtureExecutableBindingRejectsPartialOrMismatchingOverrides(_ failure: FixtureBindingNegative) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opal-executable-binding-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent(failure == .wrongName ? "OtherExecutable" : "AgentProtocolFixture")
    let bytes = Data("not launched".utf8)
    try bytes.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    var environment = ["OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE": path.path,
                       "OPAL_AGENT_PROTOCOL_FIXTURE_SHA256": FixtureRelayOracle.digest(bytes)]
    switch failure {
    case .partialPath: environment.removeValue(forKey: "OPAL_AGENT_PROTOCOL_FIXTURE_SHA256")
    case .partialHash: environment.removeValue(forKey: "OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE")
    case .wrongName: break
    case .wrongHash: environment["OPAL_AGENT_PROTOCOL_FIXTURE_SHA256"] = String(repeating: "0", count: 64)
    }
    #expect(throws: FixtureFailure.invalidArguments) { try fixtureExecutable(environment: environment) }
}
