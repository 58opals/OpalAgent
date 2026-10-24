import AgentClient
import AgentMCP
import AgentNativeIPC
import AgentValues
import CryptoKit
import Darwin
import Foundation
import AgentMCPTestSupport
import Security
import Testing
@testable import AgentProtocolFixture
@testable import AgentServiceCore

private enum FixtureLaunchMode {
    case controlled
    case ordinary(directory: URL, trace: URL)
}
private enum FixtureStdioClosure: String, CaseIterable {
    case stdinEOF, unterminatedStdinEOF, stdoutLoss
}

private final class OwnedFixtureChild: @unchecked Sendable {
    let pid: pid_t
    private let controlSocket: FixtureControlSocket?
    var control: FixtureControlSocket {
        get throws {
            guard let controlSocket else { throw WireFixtureFailure.invalidReply }
            return controlSocket
        }
    }
    let input: Int32
    let output: Int32
    private let lock = NSLock()
    private var joined = false
    private var inputClosed = false
    private var outputClosed = false
    private var events: [FixtureControlMessage] = []
    private var consentNonces = Set<UUID>()
    private static let eventKinds: Set<String> = ["relayEntered", "phaseReached", "admissionClosed", "shutdownComplete", "assemblyDrained", "outputSendFailed"]
    private init(pid: pid_t, control: FixtureControlSocket?, input: Int32, output: Int32) {
        self.pid = pid; self.controlSocket = control; self.input = input; self.output = output
    }
    static func launch(executable: URL, mode: FixtureLaunchMode = .controlled) throws -> OwnedFixtureChild {
        var sockets: [Int32] = [-1, -1], input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        var sourceFDs: [Int32] = [], transferred = Set<Int32>()
        defer {
            for fd in sockets + input + output + sourceFDs where fd >= 0 && !transferred.contains(fd) { Darwin.close(fd) }
        }
        let arguments: [String]
        var targets: [Int32] = [STDIN_FILENO, STDOUT_FILENO]
        switch mode {
        case .controlled:
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw WireFixtureFailure.invalidReply }
            arguments = [executable.path, "--test-control-fd", "3"]
            targets.append(3)
        case .ordinary(let directory, let trace):
            arguments = [executable.path, "--state-directory", directory.path, "--scenario", "uncertain", "--trace-file", trace.path]
        }
        guard pipe(&input) == 0, pipe(&output) == 0 else { throw WireFixtureFailure.invalidReply }
        // Sources >=10 keep file-action dup2 order independent of inherited descriptor numbering.
        let sources = [input[0], output[1]] + (sockets[1] >= 0 ? [sockets[1]] : [])
        for fd in sources {
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw WireFixtureFailure.invalidReply }
            sourceFDs.append(copy)
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for (source, target) in zip(sourceFDs, targets) {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw WireFixtureFailure.invalidReply }
        }
        _ = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argvStrings = arguments.map { strdup($0) }
        let environment = ["PATH=/usr/bin:/bin", "TMPDIR=" + FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path].map { strdup($0) }
        defer { argvStrings.forEach { free($0) }; environment.forEach { free($0) } }
        var argv = argvStrings + [nil], env = environment + [nil], pid: pid_t = 0
        let control = sockets[0] >= 0 ? try FixtureControlSocket(descriptor: sockets[0]) : nil
        if control != nil { transferred.insert(sockets[0]) } // The socket object now owns this descriptor, including spawn failure.
        guard posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &env) == 0 else { throw WireFixtureFailure.invalidReply }
        transferred.formUnion([input[1], output[0]])
        return OwnedFixtureChild(pid: pid, control: control, input: input[1], output: output[0])
    }
    func bootstrap(_ ownership: FixtureProcessOwnership, resume: Bool, credential: Data? = nil, wallTime: Int64? = nil,
                   recoveryOnly: Bool = false) async throws -> FixtureControlMessage {
        var request = FixtureControlMessage(kind: "bootstrap")
        request.namespace = ownership.namespace.path; request.runID = ownership.runID
        request.capability = ownership.capability; request.resume = resume; request.epoch = UUID()
        request.wallTime = wallTime; request.recoveryOnly = recoveryOnly ? true : nil
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
            if Self.eventKinds.contains(message.kind) {
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
            guard Self.eventKinds.contains(message.kind) else { throw WireFixtureFailure.invalidReply }
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
    func observe() async throws -> FixtureProcessSnapshot { try #require(try await command("facts").snapshot) }
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
                controlSocket?.close()
                return status
            }
            guard result == 0 || (result < 0 && errno == EINTR) else { throw WireFixtureFailure.invalidReply }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WireFixtureFailure.deadline
    }
    func close() async throws -> Int32 { try control.send(FixtureControlMessage(kind: "close")); return try await join() }
    /// Only the parent write end changes here; stdout and the independent control route stay open.
    func closeInput() {
        lock.withLock { guard !inputClosed else { return }; inputClosed = true; Darwin.close(input) }
    }
    /// The borrowed protocol reader must be joined before retiring only this parent read end.
    func closeOutput() {
        lock.withLock { guard !outputClosed else { return }; outputClosed = true; Darwin.close(output) }
    }
    func closePipes() { closeInput(); closeOutput() }
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

/// Gates and joins client writes before an OS stdio half-close or a final raw stimulus.
/// Disconnect joins borrowed-FD activity without closing either parent pipe descriptor.
private actor HalfClosingProcessTransport: MCPTransport {
    private let child: OwnedFixtureChild
    private let base: BoundedStdioTransport
    private var clientSendsRetired = false
    private var activeSends = 0
    private var sendsDrained: CheckedContinuation<Void, Never>?
    private var reader: Task<Void, Never>?
    init(_ child: OwnedFixtureChild) {
        self.child = child
        base = BoundedStdioTransport(inputDescriptor: child.output, outputDescriptor: child.input)
    }
    func connect() async throws { try await base.connect() }
    func send(_ data: Data) async throws {
        guard !clientSendsRetired else { throw MCPTransportError.connectionClosed }
        activeSends += 1
        defer {
            activeSends -= 1
            if activeSends == 0 { sendsDrained?.resume(); sendsDrained = nil }
        }
        try await base.send(data)
    }
    func receive() -> AsyncThrowingStream<Data, any Error> {
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await bytes in await base.receive() {
                        try Task.checkCancellation()
                        continuation.yield(bytes)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            reader = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func retireClientSends() async {
        clientSendsRetired = true
        if activeSends > 0 { await withCheckedContinuation { sendsDrained = $0 } }
    }
    private func writeRaw(_ frame: Data) async throws {
        try #require(clientSendsRetired && !frame.isEmpty && frame.count <= MCPBounds.inputBytes + 1)
        let deadline = ContinuousClock.now + .seconds(5)
        var offset = 0
        while offset < frame.count {
            try #require(ContinuousClock.now < deadline)
            let count = frame.withUnsafeBytes { Darwin.write(child.input, $0.baseAddress!.advanced(by: offset), frame.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { await Task.yield() }
            else { throw WireFixtureFailure.invalidReply }
        }
    }
    func finishInput(unterminatedFrame: Data? = nil) async throws {
        guard !clientSendsRetired else { return }
        await retireClientSends()
        if let frame = unterminatedFrame {
            try #require(!frame.isEmpty && frame.count <= MCPBounds.inputBytes && !frame.contains(10))
            try await writeRaw(frame)
        }
        child.closeInput()
    }
    func sendRawPing() async throws {
        let request: MCPValue = .object(["jsonrpc": .string("2.0"), "id": .string("stdout-loss-" + UUID().uuidString), "method": .string("ping")])
        var frame = try JSONEncoder().encode(request)
        try #require(!frame.contains(10))
        frame.append(10)
        try await writeRaw(frame)
    }
    func disconnect() async {
        reader?.cancel()
        await base.disconnect()
        await reader?.value
        reader = nil
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
/// Probe the existing owned inode independently of the service's lease implementation.
private func writerLeaseAvailable(_ ownership: FixtureProcessOwnership, identity: FixtureFileIdentity) throws -> Bool {
    let fd = Darwin.open(ownership.directory.appendingPathComponent("writer.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    try #require(fd >= 0)
    defer { Darwin.close(fd) }
    try #require(try FixtureFileIdentity.capture(descriptor: fd, directory: false) == identity)
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
    try #require(errno == EWOULDBLOCK)
    return false
}
private func processCall(_ client: MCPTestClient, name: String, arguments: [String: MCPValue]) async throws -> WireReply {
    let reply = try await client.callTool(name: name, arguments: arguments)
    guard reply.content.count == 1, case let .text(text, _, _) = reply.content[0] else { throw WireFixtureFailure.invalidReply }
    let fields = try JSONDecoder().decode([String: MCPValue].self, from: Data(text.utf8))
    #expect(reply.structuredContent == .object(fields))
    return WireReply(fields: fields, isError: reply.isError)
}
private func processAccount(_ account: AccountScope) throws -> MCPValue {
    try JSONDecoder().decode(MCPValue.self, from: JSONEncoder().encode(account))
}
private func withProcessWire(_ child: OwnedFixtureChild, name: String,
                            transport suppliedTransport: (any MCPTransport)? = nil,
                            body: (MCPTestClient) async throws -> Void) async throws {
    let client = MCPTestClient(name: name, version: "1")
    do {
        let transport: any MCPTransport = suppliedTransport ?? BoundedStdioTransport(inputDescriptor: child.output, outputDescriptor: child.input)
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

private actor DropCompletedReceiveReply: MCPTransport {
    let base: BoundedStdioTransport
    private var armed = false
    private var target: MCPValue?
    private var reader: Task<Void, Never>?
    private(set) var dropped = false
    init(_ child: OwnedFixtureChild) { base = BoundedStdioTransport(inputDescriptor: child.output, outputDescriptor: child.input) }
    func arm() { armed = true }
    func connect() async throws { try await base.connect() }
    func disconnect() async {
        reader?.cancel()
        await base.disconnect()
        await reader?.value
        reader = nil
    }
    func send(_ bytes: Data) async throws {
        if armed, let message = try? JSONDecoder().decode([String: MCPValue].self, from: bytes),
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
                           let message = try? JSONDecoder().decode([String: MCPValue].self, from: bytes),
                           message["id"] == target, message["result"] != nil { dropped = true; continue }
                        continuation.yield(bytes)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            reader = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
private func paymentArguments(_ scope: AccountScope, key requestKey: String) throws -> [String: MCPValue] {
    ["account": try processAccount(scope), "requestKey": .string(requestKey),
     "destinationAddress": .string(FixtureRuntime.destination), "amountSatoshis": .string("10000")]
}
private func retainedLookup(_ scope: AccountScope, key requestKey: String, effect: String = "preparePayment") throws -> [String: MCPValue] {
    ["account": try processAccount(scope), "effect": .string(effect), "requestKey": .string(requestKey)]
}
private func prepareProcessPayment(_ child: OwnedFixtureChild, _ client: MCPTestClient, scope: AccountScope, key requestKey: String) async throws -> String {
    let prepared = try await processCall(client, name: "prepare_payment", arguments: paymentArguments(scope, key: requestKey))
    let id = try #require(prepared.operationID)
    try await wireEventually("Actual Base preview must complete") {
        try await processCall(client, name: "get_operation", arguments: retainedLookup(scope, key: requestKey)).operation["state"]?.stringValue == "prepared"
    }
    return id
}
private func settleUnknown(_ child: OwnedFixtureChild, _ client: MCPTestClient, scope: AccountScope, key requestKey: String, id: String) async throws {
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
        let args: [String: MCPValue] = ["account": try processAccount(scope), "requestKey": .string(requestKey)]
        let drop = DropCompletedReceiveReply(first)
        try await withProcessWire(first, name: "Receive response loss", transport: drop) { client in
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
            try await withProcessWire(second, name: "Retained receive new process") { next in
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
        try await withProcessWire(first, name: "Unsubmitted preview") { client in
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
            try await withProcessWire(second, name: "Invalidated retained preview") { next in
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
        try await withProcessWire(first, name: "Process restart proof") { client in
        let requestKey = key(91)
        let prepared = try await processCall(client, name: "prepare_payment", arguments: ["account": account,
            "requestKey": .string(requestKey), "destinationAddress": .string(FixtureRuntime.destination), "amountSatoshis": .string("10000")])
        let id = try #require(prepared.operationID)
        let lookup: [String: MCPValue] = ["account": account, "effect": .string("preparePayment"), "requestKey": .string(requestKey)]
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
        let original = try await processCall(client, name: "get_operation", arguments: lookup)
        let originalAttempt = try #require(original.operation["latestAttempt"]?.objectValue)
        let attemptID = try #require(originalAttempt["attemptID"]?.stringValue)
        let transactionID = try #require(original.operation["transactionID"]?.stringValue)
        #expect(!attemptID.isEmpty && !transactionID.isEmpty && originalAttempt["number"]?.stringValue == "1")
        #expect(original.operation["liabilityUnresolved"]?.boolValue == true && original.operation["accountRestriction"]?.stringValue == "held")
        if prefix == .promotedAcceptance {
            #expect(original.operation["state"]?.stringValue == "accepted")
            #expect(original.operation["evidence"]?.objectValue?["support"]?.stringValue == "supported")
        }
        let (before, beforeBytes) = try await first.snapshot()
        #expect(before.paymentID == id && before.requestKey == requestKey && before.state == (prefix == .promotedAcceptance ? "accepted" : "submitting"))
        #expect(before.ordinaryAdmissions == 1 && before.totalAdmissions == 1 && before.relayEntries == prefix.relays && before.gateHeld)
        #expect(!beforeBytes.isEmpty && before.byteDigest == FixtureRelayOracle.digest(beforeBytes))
        let exit = try await first.join(signal: SIGKILL)
        #expect(exit & 0x7f == SIGKILL)
        await client.disconnect()
        // The killed child has been joined; inspect committed rows without a live writer.
        let killedPayment: PaymentRecord
        do {
            let journal = try SQLiteJournal(path: ownership.directory.appendingPathComponent("journal.sqlite").path, createIfMissing: false)
            killedPayment = try #require(try journal.read()?.payments.first { $0.id == id })
        }
        let acceptedReceipt: EvidenceRecord?
        if prefix == .promotedAcceptance {
            #expect(killedPayment.disposition == .accepted && killedPayment.evidenceSupported)
            let receipt = try #require(killedPayment.evidence.first { $0.chainTip == "relay" && $0.observation == nil && $0.valid })
            let contents = try JSONDecoder().decode([String].self, from: receipt.contents)
            try #require(contents.count == 2)
            #expect(contents[0] == attemptID && contents[1].hasPrefix("accepted("))
            acceptedReceipt = receipt
        } else { acceptedReceipt = nil }
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
        // Startup reconciliation schedules a retained retry; observe its refusal before the read baseline.
        try await wireEventually("The fresh runtime retry must settle before observational lookup") {
            try await second.facts().blocker == "relayNotEligible"
        }
        let settled = try await second.facts()
        #expect(settled.blocker == "relayNotEligible")
        let (after, afterBytes) = try await second.snapshot()
        // Actual startup joins fresh funding-only reconciliation; no exact payment is published.
        let retainedState = "uncertain"
        #expect(after.paymentID == id && after.requestKey == requestKey && after.state == retainedState)
        #expect(after.ordinaryAdmissions == 1 && after.totalAdmissions == 1 && after.relayEntries == prefix.relays && after.gateHeld)
        let fullBytesEqualAfterRestart = afterBytes == beforeBytes
        #expect(fullBytesEqualAfterRestart && after.byteDigest == before.byteDigest)
        try await withProcessWire(second, name: "New connection original grant") { next in
        let result = try await processCall(next, name: "get_operation", arguments: lookup)
        #expect(result.isError != true && result.operationID == id && result.operation["state"]?.stringValue == retainedState)
        #expect(result.operation["ordinaryAdmissions"]?.stringValue == "1")
        #expect(result.operation["identity"] == original.operation["identity"] && result.operation["request"] == original.operation["request"])
        #expect(result.operation["transactionID"]?.stringValue == transactionID && result.operation["latestAttempt"]?.objectValue?["attemptID"]?.stringValue == attemptID)
        #expect(result.operation["liabilityUnresolved"]?.boolValue == true && result.operation["accountRestriction"]?.stringValue == "held")
        let (lookupAfter, lookupBytes) = try await second.snapshot()
        let factsAfterLookup = try await second.facts()
        #expect(factsAfterLookup.blocker == "relayNotEligible")
        #expect(factsAfterLookup.keyReads == settled.keyReads && factsAfterLookup.chainQueries == settled.chainQueries)
        #expect(lookupAfter.stateDigest == after.stateDigest)
        #expect(lookupAfter.totalAdmissions == 1)
        #expect(lookupAfter.relayEntries == prefix.relays)
        let fullBytesEqualAfterLookup = lookupBytes == beforeBytes
        #expect(fullBytesEqualAfterLookup && lookupAfter.gateHeld)
        #expect(try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384) == durableOracle)
        let cleanExit = try await second.close()
        #expect(cleanExit == 0)
        await next.disconnect()
        // The second child is also joined before reading authoritative evidence rows.
        let reconciledPayment: PaymentRecord
        do {
            let journal = try SQLiteJournal(path: ownership.directory.appendingPathComponent("journal.sqlite").path, createIfMissing: false)
            reconciledPayment = try #require(try journal.read()?.payments.first { $0.id == id })
        }
        #expect(reconciledPayment.disposition == .uncertain)
        #expect(reconciledPayment.attempts == killedPayment.attempts)
        #expect(killedPayment.evidence.allSatisfy { reconciledPayment.evidence.contains($0) })
        if let acceptedReceipt {
            #expect(!reconciledPayment.evidenceSupported && reconciledPayment.evidenceRevision > killedPayment.evidenceRevision)
            #expect(reconciledPayment.evidence.first { $0.id == acceptedReceipt.id } == acceptedReceipt)
            let removal = try #require(reconciledPayment.evidence.compactMap(\.observation).first { $0.supportRemoved })
            #expect(removal.complete && removal.fresh && removal.exactTransactionBytes == nil)
        }
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

    @Test func gracefulStopClosesAdmissionAndRetainsWriterUntilActualRelayDrain() async throws {
        let ownership = try ownedNamespace()
        let child = try OwnedFixtureChild.launch(executable: fixtureExecutable())
        let ready = try await child.bootstrap(ownership, resume: false)
        let credential = try await child.control.receiveAsync(); try #require(credential.0 == 2 && credential.1.count == 32)
        let scope = try #require(ready.snapshot?.account), requestKey = key(97)
        try await withProcessWire(child, name: "Graceful stop drains actual relay") { client in
            let id = try await prepareProcessPayment(child, client, scope: scope, key: requestKey)
            let lookup = try retainedLookup(scope, key: requestKey)
            _ = try await processCall(client, name: "submit_payment", arguments: ["account": try processAccount(scope), "operationID": .string(id)])
            _ = try await child.event("relayEntered")
            let before = try await child.snapshot()
            let writer = try FixtureFileIdentity.capture(ownership.directory.appendingPathComponent("writer.lock").path, directory: false)
            #expect(before.0.state == "submitting" && before.0.totalAdmissions == 1 && before.0.relayEntries == 1 && before.0.gateHeld)
            let oraclePath = ownership.namespace.appendingPathComponent("relay-oracle.jsonl")
            let oracle = try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384)
            #expect(oracle.split(separator: 10).count == 1)
            let stop = FixtureControlMessage(kind: "stop"); try child.control.send(stop)
            let admissionClosed = try await child.event("admissionClosed")
            #expect(admissionClosed.id == stop.id && admissionClosed.snapshot?.state == "submitting")
            #expect(try !writerLeaseAvailable(ownership, identity: writer))
            let unavailable = try await processCall(client, name: "get_operation", arguments: lookup)
            #expect(unavailable.isError == true && unavailable.errorCode == "unavailable")
            await client.disconnect()
            // Losing the wire connection cannot prove that the admitted transport had no effect.
            #expect(try !writerLeaseAvailable(ownership, identity: writer))
            #expect(try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384) == oracle)
            _ = try await child.command("releaseRelay")
            let complete = try await child.event("shutdownComplete")
            #expect(complete.id == stop.id)
            #expect(try writerLeaseAvailable(ownership, identity: writer))
            let after = try await child.snapshot(), facts = try await child.facts()
            let bytesRetained = after.1 == before.1
            #expect(bytesRetained && after.0.state == "uncertain" && after.0.totalAdmissions == 1 && after.0.relayEntries == 1 && after.0.gateHeld)
            #expect(try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384) == oracle)
            let closed = try await child.close(); #expect(closed == 0)
            #expect(try writerLeaseAvailable(ownership, identity: writer))
            try appendProcessProof(scenario: "graceful-stop-held-relay-drain", children: [(child.pid, ready.epoch!)],
                snapshot: after.0, generation: facts.generation, bytesEqual: bytesRetained, lookupDelta: 0, exits: [closed], facts: facts)
        }
        try FileManager.default.removeItem(at: ownership.namespace)
    }

    @Test(arguments: FixtureStdioClosure.allCases)
    private func ordinaryCLIStdioClosureCompletesAndPreservesTerminatedReceiveRequests(_ trigger: FixtureStdioClosure) async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = parent.appendingPathComponent("opal-process-cli-" + UUID().uuidString)
        let trace = directory.appendingPathComponent("trace.jsonl")
        let child = try OwnedFixtureChild.launch(executable: fixtureExecutable(), mode: .ordinary(directory: directory, trace: trace))
        let transport = HalfClosingProcessTransport(child)
        try await withProcessWire(child, name: "Ordinary CLI stdio closure", transport: transport) { client in
            let wallets = try await processCall(client, name: "list_wallets", arguments: [:])
            let wallet = try #require(wallets.result["items"]?.arrayValue?.first?.objectValue?["scope"])
            let accounts = try await processCall(client, name: "list_accounts", arguments: ["wallet": wallet, "page": .object([:])])
            let account = try #require(accounts.result["page"]?.objectValue?["items"]?.arrayValue?.first?.objectValue?["scope"])
            let scope = try JSONDecoder().decode(AccountScope.self, from: JSONEncoder().encode(account))
            let requestKey = key(110), incompleteKey = key(111)
            let created = try await processCall(client, name: "create_receive_request", arguments: ["account": account, "requestKey": .string(requestKey)])
            let operationID = try #require(created.operationID)
            let lookup = try retainedLookup(scope, key: requestKey, effect: "createReceiveRequest")
            try await wireEventually("Ordinary CLI must retain the completed allocation before stdio closure") {
                try await processCall(client, name: "get_operation", arguments: lookup).operation["state"]?.stringValue == "allocated"
            }
            let allocated = try await processCall(client, name: "get_operation", arguments: lookup)
            let address = try #require(allocated.operation["allocation"]?.objectValue?["address"]?.stringValue)
            let index = try #require(allocated.operation["allocation"]?.objectValue?["index"]?.intValue)
            let allocationIndex = try #require(UInt32(exactly: index))
            let directoryIdentity = try FixtureFileIdentity.capture(directory.path, directory: true)
            let candidate: MCPValue = .object(["jsonrpc": .string("2.0"), "id": .string("unterminated-final-receive"),
                "method": .string("tools/call"), "params": .object(["name": .string("create_receive_request"),
                    "arguments": .object(["account": account, "requestKey": .string(incompleteKey)])])])
            let frame = try JSONEncoder().encode(candidate)
            // This is a valid effect request except for the missing stdio newline, not malformed JSON.
            #expect(try JSONDecoder().decode(MCPValue.self, from: frame) == candidate)
            switch trigger {
            case .stdinEOF, .unterminatedStdinEOF:
                try await transport.finishInput(unterminatedFrame: trigger == .unterminatedStdinEOF ? frame : nil)
                #expect(fcntl(child.output, F_GETFD) >= 0)
                // The wire client remains connected; only parent stdin EOF establishes this exit.
            case .stdoutLoss:
                await transport.retireClientSends()
                await client.disconnect() // Joins borrowed tasks while both OS pipe descriptors remain open.
                try #require(fcntl(child.input, F_GETFD) >= 0 && fcntl(child.output, F_GETFD) >= 0)
                child.closeOutput()
                try #require(fcntl(child.input, F_GETFD) >= 0)
                try await transport.sendRawPing()
            }
            // No control request, input cleanup, signal or timeout supplies successful completion.
            let exit = try await child.join()
            #expect(exit == 0) // A broken stdout must not terminate this child with SIGPIPE.
            if trigger == .stdoutLoss { #expect(fcntl(child.input, F_GETFD) >= 0) }
            #expect(try FixtureFileIdentity.capture(directory.path, directory: true) == directoryIdentity)
            let state: CanonicalState
            do {
                let journal = try SQLiteJournal(path: directory.appendingPathComponent("state/journal.sqlite").path, createIfMissing: false)
                state = try #require(try journal.read())
            }
            let receives = state.requests.filter { $0.method == "create_receive_request" }
            try #require(receives.count == 1)
            let retained = try #require(receives.first)
            let result = try JSONDecoder().decode(ReceiveAllocation.self, from: retained.result)
            #expect(retained.id == operationID && retained.key == requestKey && retained.disposition == .closed)
            #expect(result.operationID == operationID && result.accountID == scope.accountID && result.network == scope.wallet.network.rawValue)
            #expect(result.address == address && result.index == allocationIndex)
            #expect(!state.requests.contains { $0.key == incompleteKey })
            let issuance = try #require(state.allocations.first { $0.accountID == scope.accountID && $0.branch == "receiving" })
            #expect(issuance.issuedIndices == [UInt64(allocationIndex)] && issuance.issuedHighWater == UInt64(allocationIndex))
            #expect(state.allocations.count == 1 && state.payments.isEmpty && state.gates.isEmpty)
            let events = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode([String: MCPValue].self, from: Data($0.utf8))
            }
            if trigger == .stdoutLoss {
                #expect(events.first?["event"]?.stringValue == "fixture-ready")
                #expect(events.contains { $0["event"]?.stringValue == "fixture-stop" })
            } else {
                #expect(events.first?["event"]?.stringValue == "fixture-ready" && events.last?["event"]?.stringValue == "fixture-stop")
            }
            #expect(events.allSatisfy { $0["relayCount"]?.intValue == 0 })
            #expect(events.filter { $0["method"]?.stringValue == "create_receive_request" }.count == 1)
            #expect(events.filter { $0["event"]?.stringValue == "stdio-output-send-failed" }.count == (trigger == .stdoutLoss ? 1 : 0))
        }
        try FileManager.default.removeItem(at: directory)
    }

    @Test(arguments: [FixtureStdioClosure.stdinEOF, .stdoutLoss])
    private func stdioClosureClosesAdmissionAndDrainsHeldRelayBeforeFreshReopen(_ trigger: FixtureStdioClosure) async throws {
        let ownership = try ownedNamespace(), executable = try fixtureExecutable()
        let first = try OwnedFixtureChild.launch(executable: executable)
        let ready = try await first.bootstrap(ownership, resume: false)
        let credential = try await first.control.receiveAsync(); try #require(credential.0 == 2 && credential.1.count == 32)
        let scope = try #require(ready.snapshot?.account), firstEpoch = try #require(ready.epoch), requestKey = key(112)
        let transport = HalfClosingProcessTransport(first)
        try await withProcessWire(first, name: "Stdio closure retains held relay ownership", transport: transport) { client in
            let id = try await prepareProcessPayment(first, client, scope: scope, key: requestKey)
            let lookup = try retainedLookup(scope, key: requestKey)
            _ = try await processCall(client, name: "submit_payment", arguments: ["account": try processAccount(scope), "operationID": .string(id)])
            _ = try await first.event("relayEntered")
            let original = try await processCall(client, name: "get_operation", arguments: lookup)
            let originalAttempt = try #require(original.operation["latestAttempt"]?.objectValue)
            let attemptID = try #require(originalAttempt["attemptID"]?.stringValue)
            let transactionID = try #require(original.operation["transactionID"]?.stringValue)
            let before = try await first.snapshot()
            #expect(before.0.paymentID == id && before.0.requestKey == requestKey && before.0.state == "submitting")
            #expect(before.0.totalAdmissions == 1 && before.0.ordinaryAdmissions == 1 && before.0.relayEntries == 1 && before.0.gateHeld)
            try #require(!before.1.isEmpty && !attemptID.isEmpty && !transactionID.isEmpty)
            #expect(before.0.byteDigest == FixtureRelayOracle.digest(before.1))
            #expect(originalAttempt["number"]?.stringValue == "1" && original.operation["liabilityUnresolved"]?.boolValue == true)
            #expect(original.operation["accountRestriction"]?.stringValue == "held")
            let writer = try FixtureFileIdentity.capture(ownership.directory.appendingPathComponent("writer.lock").path, directory: false)
            let oraclePath = ownership.namespace.appendingPathComponent("relay-oracle.jsonl")
            let oracle = try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384)
            let entries = oracle.split(separator: 10)
            try #require(entries.count == 1)
            let entry = try JSONDecoder().decode([String: MCPValue].self, from: Data(try #require(entries.first)))
            #expect(entry["version"]?.intValue == 1 && entry["ordinal"]?.intValue == 1 && entry["attempt"]?.intValue == 1)
            #expect(entry["operationID"]?.stringValue == id && entry["digest"]?.stringValue == before.0.byteDigest && entry["epoch"]?.stringValue == firstEpoch.uuidString)
            let originalLookup = OperationLookup.request(account: scope, effect: .preparePayment, key: try RequestKey(requestKey))
            if trigger == .stdoutLoss {
                await transport.retireClientSends()
                await client.disconnect() // Retire and join protocol activity before closing its borrowed read descriptor.
                try #require(fcntl(first.input, F_GETFD) >= 0 && fcntl(first.output, F_GETFD) >= 0)
                var stillAdmitted = FixtureControlMessage(kind: "integrationLookup")
                stillAdmitted.connection = "original"; stillAdmitted.lookup = originalLookup
                try first.control.send(stillAdmitted)
                let admitted = try await first.response(id: stillAdmitted.id)
                try #require(admitted.kind == "integrationLookup")
                let active = try #require(admitted.payment)
                #expect(active.identity.selector.operationID == id && active.state == .submitting)
                #expect(active.identity.requestKey.value == requestKey && admitted.snapshot?.stateDigest == before.0.stateDigest)
                first.closeOutput()
                let control = try first.control
                try #require(fcntl(first.input, F_GETFD) >= 0 && fcntl(control.descriptor, F_GETFD) >= 0)
                try await transport.sendRawPing()
                // Send-failure and receive-ended observers can race; both must be present before release.
                let failed = try await first.event("outputSendFailed", phase: "stdio-send-failed")
                #expect(failed.epoch == firstEpoch)
            } else {
                try #require(trigger == .stdinEOF)
                try await transport.finishInput()
                #expect(fcntl(first.output, F_GETFD) >= 0)
            }
            let closed = try await first.event("admissionClosed", phase: "stdio-ended")
            #expect(closed.epoch == firstEpoch)
            // The same authenticated handle was valid immediately before OS closure. Control stays open.
            var probe = FixtureControlMessage(kind: "integrationLookup")
            probe.connection = "original"; probe.lookup = originalLookup
            try first.control.send(probe)
            let unavailable = try await first.response(id: probe.id)
            #expect(unavailable.kind == "problem" && unavailable.problem == "unavailable")
            let held = try await first.snapshot()
            #expect(held.0.state == "submitting" && held.0.stateDigest == before.0.stateDigest && held.1 == before.1)
            #expect(try !writerLeaseAvailable(ownership, identity: writer))
            #expect(try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384) == oracle)
            // Only this explicit action releases the cancellation-insensitive synthetic transport.
            _ = try await first.command("releaseRelay")
            let drained = try await first.event("assemblyDrained", phase: "stdio-ended")
            #expect(drained.epoch == firstEpoch)
            #expect(try writerLeaseAvailable(ownership, identity: writer))
            let afterDrain = try await first.snapshot(), drainedFacts = try await first.facts()
            #expect(afterDrain.0.state == "uncertain" && afterDrain.0.paymentID == id && afterDrain.0.requestKey == requestKey)
            #expect(afterDrain.1 == before.1 && afterDrain.0.byteDigest == before.0.byteDigest && afterDrain.0.gateHeld)
            #expect(afterDrain.0.totalAdmissions == 1 && afterDrain.0.ordinaryAdmissions == 1 && afterDrain.0.relayEntries == 1)
            #expect(try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384) == oracle)
            // Cleanup starts only after actual stdio-loss admission closure, relay completion and writer release.
            let firstExit = try await first.close(); #expect(firstExit == 0)
            await client.disconnect()
            let retained: CanonicalState
            do {
                let journal = try SQLiteJournal(path: ownership.directory.appendingPathComponent("journal.sqlite").path, createIfMissing: false)
                retained = try #require(try journal.read())
            }
            let payment = try #require(retained.payments.first { $0.id == id })
            #expect(payment.disposition == .uncertain && payment.liabilityUnresolved && payment.canonicalBytes == before.1)
            #expect(payment.attempts.count == 1 && payment.attempts.first?.id == attemptID && payment.transactionID == transactionID)
            #expect(retained.requests.filter { $0.paymentID == id && $0.method == "prepare_payment" }.count == 1)
            let second = try OwnedFixtureChild.launch(executable: executable)
            let restarted = try await second.bootstrap(ownership, resume: true, credential: credential.1)
            let secondEpoch = try #require(restarted.epoch)
            #expect(secondEpoch != firstEpoch && restarted.problem == nil)
            try await wireEventually("Fresh stdio-closure reopen continuation must settle before observational baselines") {
                try await second.facts().blocker == "relayNotEligible"
            }
            let baseline = try await second.snapshot(), facts = try await second.facts()
            #expect(facts.blocker == "relayNotEligible" && facts.generation == drainedFacts.generation)
            try await withProcessWire(second, name: "Fresh authenticated assembly after stdio closure") { next in
                let result = try await processCall(next, name: "get_operation", arguments: lookup)
                #expect(result.isError != true && result.operationID == id && result.operation["state"]?.stringValue == "uncertain")
                #expect(result.operation["identity"] == original.operation["identity"] && result.operation["request"] == original.operation["request"])
                #expect(result.operation["transactionID"]?.stringValue == transactionID && result.operation["latestAttempt"]?.objectValue?["attemptID"]?.stringValue == attemptID)
                #expect(result.operation["liabilityUnresolved"]?.boolValue == true && result.operation["accountRestriction"]?.stringValue == "held")
                let after = try await second.snapshot(), afterFacts = try await second.facts()
                #expect(after.1 == before.1 && baseline.1 == before.1 && after.0.byteDigest == before.0.byteDigest)
                #expect(after.0.stateDigest == baseline.0.stateDigest && after.0.totalAdmissions == 1 && after.0.ordinaryAdmissions == 1 && after.0.relayEntries == 1 && after.0.gateHeld)
                #expect(afterFacts.keyReads == facts.keyReads && afterFacts.chainQueries == facts.chainQueries && afterFacts.blocker == "relayNotEligible")
                #expect(try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384) == oracle)
                let secondExit = try await second.close(); #expect(secondExit == 0)
                await next.disconnect()
                let reopened: CanonicalState
                do {
                    let journal = try SQLiteJournal(path: ownership.directory.appendingPathComponent("journal.sqlite").path, createIfMissing: false)
                    reopened = try #require(try journal.read())
                }
                let row = try #require(reopened.payments.first { $0.id == id })
                // Reconciliation may add evidence/blockers; the retained immutable payment contract cannot change.
                #expect(row.id == payment.id && row.accountID == payment.accountID && row.network == payment.network)
                #expect(row.originGrantID == payment.originGrantID && row.originCredentialGeneration == payment.originCredentialGeneration)
                #expect(row.walletGeneration == payment.walletGeneration && row.policyRevision == payment.policyRevision)
                #expect(row.request == payment.request && row.preview == payment.preview)
                #expect(row.canonicalBytes == payment.canonicalBytes && row.transactionDigest == payment.transactionDigest && row.transactionID == payment.transactionID)
                #expect(row.selectedInputs == payment.selectedInputs && row.change == payment.change && row.attempts == payment.attempts)
                #expect(row.ordinaryAdmissions == payment.ordinaryAdmissions && row.disposition == .uncertain && row.liabilityUnresolved)
                #expect(reopened.requests == retained.requests && reopened.gates == retained.gates && reopened.allocations == retained.allocations)
                #expect(reopened.installationID == retained.installationID && reopened.authorization == retained.authorization && reopened.custody == retained.custody)
                #expect(reopened.payments.count == retained.payments.count && payment.evidence.allSatisfy { row.evidence.contains($0) })
                #expect(payment.closures.allSatisfy { row.closures.contains($0) })
                #expect(try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384) == oracle)
                #expect(try writerLeaseAvailable(ownership, identity: writer))
                try appendProcessProof(scenario: trigger == .stdoutLoss ? "stdout-loss-held-relay-drain-reopen" : "stdin-eof-held-relay-drain-reopen",
                    children: [(first.pid, firstEpoch), (second.pid, secondEpoch)],
                    snapshot: after.0, generation: drainedFacts.generation, bytesEqual: after.1 == before.1,
                    lookupDelta: after.0.totalAdmissions - baseline.0.totalAdmissions + after.0.relayEntries - baseline.0.relayEntries,
                    exits: [firstExit, secondExit], facts: afterFacts)
            }
        }
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
        try await withProcessWire(first, name: "Ordinary then independent owner relay") { client in
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
        // Trusted assembly reopen verifies synthetic custody before exposing its endpoints.
        let assemblyStartup = try await second.facts(); #expect(assemblyStartup.keyReads > 0)
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
            let afterRecovery = try await third.bootstrap(ownership, resume: true, credential: secret.1, recoveryOnly: true)
            #expect(afterRecovery.problem == "integrationUnavailable")
            active = third; children.append((third.pid, afterRecovery.epoch!))
            // This explicitly selected owner-only path never opens a wrapping key or effect adapter.
            let startupEffects = try await third.facts()
            #expect(startupEffects.keyReads == 0 && startupEffects.chainQueries == 0)
            let ownerStatus = try await third.command("status")
            #expect(ownerStatus.status?.availability == .restricted && ownerStatus.status?.walletGeneration == 2)
            let afterStatus = try await third.facts()
            #expect(afterStatus.keyReads == 0 && afterStatus.chainQueries == 0)
            #expect(afterStatus.keyReads == startupEffects.keyReads && afterStatus.chainQueries == startupEffects.chainQueries)
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
        if recover { #expect(factsAfter.keyReads == 0 && factsAfter.chainQueries == 0) }
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
        try await withProcessWire(first, name: "Known original authority") { client in
            id = try await prepareProcessPayment(first, client, scope: scope, key: requestKey)
            try await settleUnknown(first, client, scope: scope, key: requestKey, id: id)
            originalBytes = try await first.snapshot().1
            if rotated {
                let selector = try #require(ready.grant?.selector)
                var rotation = FixtureControlMessage(kind: "rotateGrant"); rotation.wallet = scope.wallet; rotation.grantSelector = selector
                let result = try await first.owner(rotation, call: .rotateGrant(selector))
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
        try await withProcessWire(second, name: "New current connection original operation") { next in
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
                    let snapshot = try await second.observe()
                    return snapshot.state == "uncertain" && snapshot.ordinaryAdmissions == 2
                }
                _ = try await second.command("advanceClock") { $0.seconds = 119 }
                _ = try await second.command("continuePending")
                try await wireEventually("The third admission must retain its full 120-second delay") {
                    try await second.facts().blocker == "relayNotEligible"
                }
                let beforeThird = try await second.observe()
                #expect(beforeThird.totalAdmissions == 2 && beforeThird.ordinaryAdmissions == 2 && beforeThird.relayEntries == 2)
                _ = try await second.command("advanceClock") { $0.seconds = 1 }
                _ = try await second.command("continuePending")
                _ = try await second.event("relayEntered")
                try await wireEventually("The third actual handoff must exhaust ordinary authority") {
                    let snapshot = try await second.observe(), facts = try await second.facts()
                    return snapshot.state == "uncertain" && snapshot.ordinaryAdmissions == 3 && facts.blocker == "automaticRelayBudgetExhausted"
                }
                _ = try await second.command("advanceClock") { $0.seconds = 1_000 }
                _ = try await processCall(next, name: "submit_payment", arguments: ["account": try processAccount(scope), "operationID": .string(id)])
                _ = try await second.command("continuePending")
            }
            let (afterSnapshot, afterBytes): (FixtureProcessSnapshot, Data) = try await second.snapshot()
            let facts = try await second.facts()
            let expected = rotated ? 1 : 3
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
            let lookupDelta = afterLookup.totalAdmissions - beforeSnapshot.totalAdmissions + afterLookup.relayEntries - beforeSnapshot.relayEntries
            if rotated {
                let closed = try await second.close(); #expect(closed == 0)
                try appendProcessProof(scenario: "rotated-origin-two-unused-slots", children: [(first.pid, ready.epoch!), (second.pid, restarted.epoch!)],
                    snapshot: afterSnapshot, generation: facts.generation, bytesEqual: exact,
                    lookupDelta: lookupDelta, exits: [firstExit, closed], facts: facts)
            } else {
                #expect(facts.blocker == "automaticRelayBudgetExhausted")
                let exhausted = try await processCall(next, name: "get_operation", arguments: lookup)
                let exhaustedAttempt = try #require(exhausted.operation["latestAttempt"]?.objectValue?["attemptID"]?.stringValue)
                #expect(!exhaustedAttempt.isEmpty && exhausted.operation["latestAttempt"]?.objectValue?["number"]?.stringValue == "3")
                let oraclePath = ownership.namespace.appendingPathComponent("relay-oracle.jsonl")
                let oracle = try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384)
                let entries = try oracle.split(separator: 10).map { line in
                    try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                }
                #expect(entries.count == 3)
                for (index, entry) in entries.enumerated() {
                    #expect(entry["ordinal"] as? Int == index + 1 && entry["attempt"] as? Int == index + 1)
                    #expect(entry["operationID"] as? String == id && entry["digest"] as? String == afterSnapshot.byteDigest)
                }
                let secondExit = try await second.join(signal: SIGKILL); #expect(secondExit & 0x7f == SIGKILL)
                await next.disconnect()
                let third = try OwnedFixtureChild.launch(executable: fixtureExecutable())
                let reopened = try await third.bootstrap(ownership, resume: true, credential: currentCredential, wallTime: facts.clockWall)
                try #require(reopened.problem == nil)
                try await withProcessWire(third, name: "Exhausted ordinary authority after another death") { last in
                    let baseline = try await third.snapshot()
                    _ = try await third.command("advanceClock") { $0.seconds = 1_000 }
                    _ = try await processCall(last, name: "submit_payment", arguments: ["account": try processAccount(scope), "operationID": .string(id)])
                    _ = try await third.command("continuePending")
                    let retained = try await processCall(last, name: "get_operation", arguments: lookup)
                    let final = try await third.snapshot(), finalFacts = try await third.facts()
                    #expect(retained.operation["identity"] == exhausted.operation["identity"] && retained.operation["request"] == exhausted.operation["request"])
                    #expect(retained.operation["transactionID"] == exhausted.operation["transactionID"])
                    #expect(retained.operation["latestAttempt"]?.objectValue?["attemptID"]?.stringValue == exhaustedAttempt)
                    #expect(retained.operation["ordinaryAdmissions"]?.stringValue == "3" && retained.operation["liabilityUnresolved"]?.boolValue == true)
                    #expect(retained.operation["blocker"]?.stringValue == "automaticRelayBudgetExhausted" && retained.operation["accountRestriction"]?.stringValue == "held")
                    #expect(final.0.totalAdmissions == 3 && final.0.ordinaryAdmissions == 3 && final.0.relayEntries == 3 && final.0.gateHeld)
                    let allBytesRetained = exact && baseline.1 == originalBytes && final.1 == originalBytes
                    #expect(allBytesRetained && finalFacts.ownerReceipts == 0 && finalFacts.blocker == "automaticRelayBudgetExhausted")
                    #expect(try FixtureProcessOwnership.readOwned(oraclePath, maximum: 16_384) == oracle)
                    let closed = try await third.close(); #expect(closed == 0)
                    try appendProcessProof(scenario: "fresh-runtime-full-retry-delay", children: [(first.pid, ready.epoch!), (second.pid, restarted.epoch!), (third.pid, reopened.epoch!)],
                        snapshot: final.0, generation: finalFacts.generation, bytesEqual: allBytesRetained,
                        lookupDelta: lookupDelta, exits: [firstExit, secondExit, closed], facts: finalFacts)
                }
            }
        }
        try FileManager.default.removeItem(at: ownership.namespace)
    }
}

private enum FixtureOwnershipNegative: String, CaseIterable { case capability, adopted, symlink, profile, format, recoveryScope }
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
        #expect(throws: FixtureFailure.invalidArguments) { try FixtureProcessOwnership.attach(bootstrap) }
        return
    }
    if failure == .recoveryScope {
        try ownership.prepare(resume: false)
        try #require(Darwin.mkdir(ownership.directory.path, 0o700) == 0)
        let scope = WalletStoreScope(installationID: UUID(), walletID: UUID())
        try scope.writeNew(in: ownership.directory)
        let journal = ownership.directory.appendingPathComponent("journal.sqlite")
        let marker = Data("invalid raw database: scope rejection must happen before resolution".utf8)
        try FixtureProcessOwnership.writeNew(marker, to: journal)
        try FixtureProcessOwnership.writeNew(Data(), to: ownership.directory.appendingPathComponent("writer.lock"))
        let items = ownership.namespace.appendingPathComponent("synthetic-keychain.json")
        let group = "synthetic.scope-guard." + ownership.runID.uuidString
        let keys = try FixtureKeychainOperations(path: items, group: group, resume: false)
        try FixtureProcessOwnership.writeNew(Data(), to: ownership.namespace.appendingPathComponent("relay-oracle.jsonl"))
        try ownership.seal(walletID: scope.walletID.uuidString, installationID: scope.installationID.uuidString,
            accountID: "fixture-account", profile: "bip39-empty/bip44-145-0/v1")
        let manifest = try ownership.storeManifest(), originalItems = try Data(contentsOf: items)
        let scopePath = ownership.directory.appendingPathComponent("custody.scope")
        let identity = try FixtureFileIdentity.capture(scopePath.path, directory: false)
        let replacement = WalletStoreScope(installationID: UUID(), walletID: UUID())
        let staging = ownership.namespace.appendingPathComponent("replacement-scope", isDirectory: true)
        try #require(Darwin.mkdir(staging.path, 0o700) == 0)
        try replacement.writeNew(in: staging)
        let bytes = try Data(contentsOf: staging.appendingPathComponent("custody.scope"))
        try FileManager.default.removeItem(at: staging)
        let file = try FileHandle(forWritingTo: scopePath)
        try file.truncate(atOffset: 0); try file.write(contentsOf: bytes); try file.synchronize(); try file.close()
        #expect(try WalletStoreScope.read(in: ownership.directory) == replacement)
        #expect(try FixtureFileIdentity.capture(scopePath.path, directory: false) == identity)
        // Genuine scope/manifest encodings and unchanged inodes still pass ownership metadata.
        try FixtureProcessOwnership.attach(bootstrap).prepare(resume: true)
        let rootFiles = try FileManager.default.contentsOfDirectory(atPath: ownership.namespace.path).sorted()
        let policy = AuthorityPolicy(bridge: SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "integration"),
            owner: SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "owner"),
            accountIDs: [manifest.accountID], capabilities: ["read"], ownerAuthenticationAge: 30)
        let clock = FixtureClock()
        #expect(throws: FixtureFailure.fixtureUnavailable) {
            _ = try FixtureRecoveryRuntime(directory: ownership.directory, group: group, keys: keys, policy: policy,
                manifest: manifest, consent: FixtureConsent(clock: clock), clock: clock,
                inspection: FixtureInspection(directory: ownership.directory))
        }
        #expect(keys.reads == 0)
        #expect(try Data(contentsOf: items) == originalItems)
        #expect(try Data(contentsOf: journal) == marker)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ownership.namespace.path).sorted() == rootFiles)
        return
    }
    try ownership.prepare(resume: false)
    let marker = Data("not a SQLite database or custody item; must remain unopened".utf8)
    try #require(Darwin.mkdir(ownership.directory.path, 0o700) == 0)
    for name in ["journal.sqlite", "custody.scope", "writer.lock"] {
        try FixtureProcessOwnership.writeNew(marker, to: ownership.directory.appendingPathComponent(name))
    }
    try FixtureProcessOwnership.writeNew(marker, to: ownership.namespace.appendingPathComponent("synthetic-keychain.json"))
    try FixtureProcessOwnership.writeNew(Data(), to: ownership.namespace.appendingPathComponent("relay-oracle.jsonl"))
    try ownership.seal(walletID: UUID().uuidString, installationID: UUID().uuidString,
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
    #expect(throws: FixtureFailure.invalidArguments) { try FixtureProcessOwnership.attach(bootstrap).prepare(resume: true) }
    for name in ["journal.sqlite", "custody.scope", "writer.lock"] {
        #expect(try Data(contentsOf: ownership.directory.appendingPathComponent(name)) == marker)
    }
    #expect(try Data(contentsOf: ownership.namespace.appendingPathComponent("synthetic-keychain.json")) == marker)
}

private enum FixtureItemPersistFailure: CaseIterable { case add, update }
@Test(arguments: FixtureItemPersistFailure.allCases)
private func failedSyntheticItemPersistenceNeverAcknowledgesCachedCandidate(_ mutation: FixtureItemPersistFailure) throws {
    let ownership = try ownedNamespace()
    defer { try? FileManager.default.removeItem(at: ownership.namespace) }
    let path = ownership.namespace.appendingPathComponent("synthetic-keychain.json")
    let group = "synthetic.persist-failure." + ownership.runID.uuidString
    let operations = try FixtureKeychainOperations(path: path, group: group, resume: false)
    let installation = UUID().uuidString, wallet = UUID().uuidString
    let anchor = try KeychainContinuityAnchorStore(accessGroup: group, installationID: installation, walletID: wallet, operations: operations)
    let original = ContinuityAnchor(committed: StateReference(installationID: installation, walletID: wallet,
        network: "mainnet", generation: 1, commitID: "durable-anchor", formatVersion: 2,
        commitment: Data(repeating: 0x31, count: 32), history: .complete))
    try anchor.write(original)
    let durableBytes = try Data(contentsOf: path)
    let retained = ownership.namespace.appendingPathComponent("retained-durable-items.json")
    try FileManager.default.moveItem(at: path, to: retained)
    // A file cannot be renamed over this directory: the real persistence attempt returns EISDIR.
    try #require(Darwin.mkdir(path.path, 0o700) == 0)
    switch mutation {
    case .add:
        let provisioner = try KeychainWrappingKeyProvisioner(accessGroup: group, walletID: wallet, operations: operations,
            generateKey: { SymmetricKey(data: Data(repeating: 0x63, count: 32)) })
        #expect(throws: KeychainCustodyError.operationFailed(errSecIO)) { try provisioner.provision() }
        let reader = try KeychainWrappingKeySource(accessGroup: group, walletID: wallet, operations: operations)
        guard case .missing = try reader.wrappingKey() else {
            Issue.record("A failed synthetic key add must never be returned as persisted")
            return
        }
    case .update:
        var candidate = original
        candidate.committed?.commitID = "unpersisted-anchor"
        candidate.committed?.commitment = Data(repeating: 0x52, count: 32)
        #expect(throws: KeychainCustodyError.operationFailed(errSecIO)) { try anchor.write(candidate) }
    }
    #expect(try anchor.read() == original)
    #expect(try Data(contentsOf: retained) == durableBytes)
    #expect(try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
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
