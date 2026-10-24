import AgentClient
import AgentValues
import Foundation
import Testing
@testable import AgentMCP

/// Holds the actual outbound transport call, rather than delaying receipt of an already-sent frame.
private actor HeldOutputTransport: MCPTransport {
    private let input: AsyncThrowingStream<Data, Error>
    private let incoming: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var holdID: String?
    private var held: CheckedContinuation<Void, Error>?
    private var heldCount = 0
    private var releasedCount = 0
    private var output: [Data] = []
    private var handedOff: Set<String> = []

    init() { (input, incoming) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(16)) }
    func connect() { connected = true }
    func receive() -> AsyncThrowingStream<Data, Error> { input }
    func disconnect() {
        connected = false
        incoming.finish()
        finishHeld(.failure(MCPTransportError.connectionClosed))
    }
    func holdNextResponse(id: String) { holdID = id }
    func feed(_ object: [String: MCPValue]) throws {
        guard connected else { throw MCPTransportError.connectionClosed }
        switch incoming.yield(try JSONEncoder().encode(object)) {
        case .enqueued: break
        case .dropped, .terminated: throw MCPTransportError.connectionClosed
        @unknown default: throw MCPTransportError.connectionClosed
        }
    }
    func send(_ data: Data) async throws {
        guard connected else { throw MCPTransportError.connectionClosed }
        let object = try JSONDecoder().decode([String: MCPValue].self, from: data)
        if let id = object["id"]?.stringValue, holdID == id {
            holdID = nil
            heldCount += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { held = $0 }
            } onCancel: { Task { await self.cancelHeld() } }
        }
        try Task.checkCancellation()
        guard connected else { throw MCPTransportError.connectionClosed }
        output.append(data)
        if let id = object["id"]?.stringValue { handedOff.insert(id) }
    }
    private func cancelHeld() { finishHeld(.failure(CancellationError())) }
    private func finishHeld(_ result: Result<Void, Error>) {
        guard let pending = held else { return }
        held = nil
        releasedCount += 1
        pending.resume(with: result)
    }
    func release() { finishHeld(.success(())) }
    func didHandOff(_ id: String) -> Bool { handedOff.contains(id) }
    func counts() -> (held: Int, released: Int, waiting: Bool) { (heldCount, releasedCount, held != nil) }
    func waitHeld() async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while held == nil {
            guard ContinuousClock.now < end else { throw MCPTransportError.connectionClosed }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func next() async throws -> [String: MCPValue] {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while output.isEmpty {
            guard ContinuousClock.now < end else { throw MCPTransportError.connectionClosed }
            try await Task.sleep(for: .milliseconds(2))
        }
        return try JSONDecoder().decode([String: MCPValue].self, from: output.removeFirst())
    }
}

private actor HandoffClientBoundary: CapabilityTransport {
    private let output: HeldOutputTransport
    private(set) var calls = 0
    private(set) var callsBeforeInitializationHandoff = 0
    init(output: HeldOutputTransport) { self.output = output }
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        calls += 1
        if !(await output.didHandOff("init")) { callsBeforeInitializationHandoff += 1 }
        guard case .listWallets = request.call else { throw ClientFailure.unavailable }
        return CapabilityResponse(result: .listWallets(.init(items: [])))
    }
}
private actor HandoffCompletion {
    private var completed = false
    func finish() { completed = true }
    func wait() async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !completed {
            guard ContinuousClock.now < end else { throw MCPTransportError.connectionClosed }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
private func handoffInitialize() -> [String: MCPValue] {
    ["jsonrpc": "2.0", "id": "init", "method": "initialize", "params": .object([
        "protocolVersion": "2025-11-25", "capabilities": .object([:]),
        "clientInfo": .object(["name": "held-handoff", "version": "1"])
    ])]
}
private func handoffCall(id: String) -> [String: MCPValue] {
    ["jsonrpc": "2.0", "id": .string(id), "method": "tools/call", "params": .object([
        "name": "list_wallets", "arguments": .object([:])
    ])]
}
private func handoffReady(_ output: HeldOutputTransport) async throws {
    try await output.feed(handoffInitialize())
    #expect(try await output.next()["result"] != nil)
    try await output.feed(["jsonrpc": "2.0", "method": "notifications/initialized"])
}

@Test func profileDoesNotDispatchClientBeforeActualInitializationResponseHandoff() async throws {
    let output = HeldOutputTransport()
    let boundary = HandoffClientBoundary(output: output)
    let server = MCPToolServer(client: CapabilityClient(transport: boundary))
    try await server.start(transport: output)
    do {
        await output.holdNextResponse(id: "init")
        try await output.feed(handoffInitialize())
        try await output.waitHeld()
        try await output.feed(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try await output.feed(handoffCall(id: "after-init"))
        // Give the real protocol reader tasks an opportunity to consume the pipelined input while
        // the transport call is held. The final historical counter also covers its release.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await boundary.calls == 0)
        #expect(await output.didHandOff("init") == false)
        await output.release()
        let initialization = try await output.next()
        let tool = try await output.next()
        #expect(initialization["id"] == .string("init") && initialization["result"] != nil)
        #expect(tool["id"] == .string("after-init") && tool["result"] != nil)
        #expect(await boundary.calls == 1)
        #expect(await boundary.callsBeforeInitializationHandoff == 0)
        let counts = await output.counts()
        #expect(counts.held == 1 && counts.released == 1 && !counts.waiting)
    } catch {
        await output.disconnect()
        await server.stop()
        throw error
    }
    await server.stop()
}

enum ProfileHandoffEnd: Sendable, CaseIterable { case stop, peerDisconnect }
@Test(arguments: ProfileHandoffEnd.allCases)
func profileDisconnectReleasesHeldResponseAndOwnedReader(_ end: ProfileHandoffEnd) async throws {
    let output = HeldOutputTransport()
    let boundary = HandoffClientBoundary(output: output)
    let server = MCPToolServer(client: CapabilityClient(transport: boundary))
    try await server.start(transport: output)
    await output.holdNextResponse(id: "init")
    try await output.feed(handoffInitialize())
    try await output.waitHeld()
    try await output.feed(["jsonrpc": "2.0", "method": "notifications/initialized"])
    try await output.feed(handoffCall(id: "never-dispatched"))
    let completed = HandoffCompletion()
    let stopping = Task {
        switch end {
        case .stop: await server.stop()
        case .peerDisconnect:
            await output.disconnect()
            await server.waitUntilCompleted()
        }
        await completed.finish()
    }
    do { try await completed.wait() }
    catch {
        // Release the fixture's gate even when the bounded assertion fails.
        await output.disconnect()
        stopping.cancel()
        throw error
    }
    await stopping.value
    let counts = await output.counts()
    #expect(counts.held == 1 && counts.released == 1 && !counts.waiting)
    #expect(await output.didHandOff("init") == false)
    #expect(await boundary.calls == 0)
}

@Test func profileReusedIDCannotAliasAHandlerAfterHeldHandoff() async throws {
    let output = HeldOutputTransport()
    let boundary = HandoffClientBoundary(output: output)
    let server = MCPToolServer(client: CapabilityClient(transport: boundary))
    try await server.start(transport: output)
    do {
        try await handoffReady(output)
        await output.holdNextResponse(id: "same-id")
        try await output.feed(handoffCall(id: "same-id"))
        try await output.waitHeld()
        #expect(await boundary.calls == 1)
        try await output.feed(handoffCall(id: "same-id"))
        await output.release()
        let first = try await output.next()
        let duplicate = try await output.next()
        #expect(first["id"] == .string("same-id") && first["result"] != nil)
        #expect(duplicate["id"] == .string("same-id"))
        #expect(duplicate["error"]?.objectValue?["code"] == .int(-32600))
        let completed = HandoffCompletion()
        let ending = Task { await server.waitUntilCompleted(); await completed.finish() }
        do { try await completed.wait() }
        catch { await output.disconnect(); ending.cancel(); throw error }
        await ending.value
        #expect(await boundary.calls == 1)
        #expect(await boundary.callsBeforeInitializationHandoff == 0)
    } catch {
        await output.disconnect()
        await server.stop()
        throw error
    }
}

/// Allows disconnect to finish while connect remains suspended, then connects when released.
private actor SuspendedConnectTransport: MCPTransport {
    private let input: AsyncThrowingStream<Data, Error>
    private let incoming: AsyncThrowingStream<Data, Error>.Continuation
    private var connectGate: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var connected = false
    private(set) var sent = 0
    var isConnectHeld: Bool { connectGate != nil }

    init() {
        (input, incoming) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(4))
        // Work is already queued so terminal startup must prevent any later dispatch.
        incoming.yield(Data("{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"suspended-connect\",\"version\":\"1\"}}}".utf8))
        incoming.yield(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8))
        incoming.yield(Data("{\"jsonrpc\":\"2.0\",\"id\":\"never-dispatched\",\"method\":\"tools/call\",\"params\":{\"name\":\"list_wallets\",\"arguments\":{}}}".utf8))
    }

    func connect() async {
        if !released { await withCheckedContinuation { connectGate = $0 } }
        connected = true
    }
    func disconnect() {
        connected = false
        incoming.finish()
    }
    func send(_ data: Data) throws {
        guard connected else { throw MCPTransportError.connectionClosed }
        sent += 1
    }
    func receive() -> AsyncThrowingStream<Data, Error> { input }
    func releaseConnect() {
        released = true
        connectGate?.resume()
        connectGate = nil
    }
    func waitConnectHeld() async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while connectGate == nil {
            guard ContinuousClock.now < end else { throw MCPTransportError.connectionClosed }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor StartupClientBoundary: CapabilityTransport {
    private(set) var calls = 0
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        calls += 1
        throw ClientFailure.unavailable
    }
}

@Test func profileStopDuringSuspendedConnectCannotPublishLateReaderWork() async throws {
    let output = SuspendedConnectTransport()
    let boundary = StartupClientBoundary()
    let server = MCPToolServer(client: CapabilityClient(transport: boundary))
    let starting = Task { try await server.start(transport: output) }
    do {
        try await output.waitConnectHeld()
        let completed = HandoffCompletion()
        let stopping = Task { await server.stop(); await completed.finish() }
        try await completed.wait()
        await stopping.value
        #expect(await output.isConnectHeld)
        #expect(await output.connected == false)
        await output.releaseConnect()
        await #expect(throws: MCPTransportError.connectionClosed) { try await starting.value }
        await server.waitUntilCompleted()
        await server.stop()
        #expect(await output.connected == false)
        #expect(await output.sent == 0)
        #expect(await boundary.calls == 0)
    } catch {
        await output.releaseConnect()
        _ = try? await starting.value
        await server.stop()
        throw error
    }
}
