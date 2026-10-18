import AgentClient
import AgentValues
import Foundation
import MCP
import Testing
@testable import AgentMCP

private actor WireInbox {
    private let transport: InMemoryTransport
    private var frames: [Data] = []
    private var task: Task<Void, Never>?
    init(_ transport: InMemoryTransport) { self.transport = transport }
    func start() async throws {
        try await transport.connect()
        task = Task {
            do { for try await data in await transport.receive() { frames.append(data) } } catch {}
        }
        await Task.yield()
    }
    func send(_ object: [String: MCP.Value]) async throws {
        try await transport.send(JSONEncoder().encode(object))
    }
    func raw(_ text: String) async throws { try await transport.send(Data(text.utf8)) }
    func next() async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while frames.isEmpty {
            guard ContinuousClock.now < deadline else { throw MCPError.connectionClosed }
            try await Task.sleep(for: .milliseconds(2))
        }
        return frames.removeFirst()
    }
    func stop() async {
        task?.cancel()
        await transport.disconnect()
        await task?.value
    }
}
private func initialize(_ version: String = "2025-11-25", capabilities: MCP.Value = .object([:])) -> [String: MCP.Value] {
    ["jsonrpc": "2.0", "id": "init", "method": "initialize", "params": .object([
        "protocolVersion": .string(version), "capabilities": capabilities,
        "clientInfo": .object(["name": "profile-test", "version": "1"])
    ])]
}
private func parse(_ data: Data) throws -> [String: MCP.Value] { try JSONDecoder().decode([String: MCP.Value].self, from: data) }
private func ready(_ inbox: WireInbox) async throws {
    try await inbox.send(initialize())
    #expect(try parse(await inbox.next())["result"] != nil)
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
}

@Test(arguments: ["2025-11-25", "2025-06-18"])
func profilePreservesOnlyQualifiedVersionsAndListsTwelve(_ version: String) async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: base)
    try await inbox.send(initialize(version))
    let result = try parse(await inbox.next())["result"]?.objectValue
    #expect(result?["protocolVersion"] == .string(version))
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    try await inbox.send(["jsonrpc": "2.0", "id": "list", "method": "tools/list"])
    let listed = try parse(await inbox.next())["result"]?.objectValue?["tools"]?.arrayValue
    #expect(listed?.count == 12)
    await server.stop(); await inbox.stop()
}
@Test(arguments: ["2024-11-05", "2025-03-26", "2099-01-01"])
func profileRejectsOtherSDKAndUnknownVersionsWithoutNegotiating(_ version: String) async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: base)
    try await inbox.send(initialize(version))
    let response = try parse(await inbox.next())
    #expect(response["id"] == .string("init"))
    #expect(response["error"]?.objectValue?["code"] == .int(-32602))
    #expect(response["result"] == nil)
    await server.waitUntilCompleted(); await inbox.stop()
}
@Test func profileIgnoresOnlyOptionalObjectExperimentalCapability() async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: base)
    try await inbox.send(initialize(capabilities: .object(["experimental": .object(["host/optional": .object([:])])])))
    #expect(try parse(await inbox.next())["result"] != nil)
    await server.stop(); await inbox.stop()
}
@Test(arguments: [
    MCP.Value.object(["roots": .object(["listChanged": .string("true")])]),
    .object(["sampling": .object(["tools": .bool(true)])]),
    .object(["elicitation": .object(["form": .object(["owner": .bool(true)])])]),
    .object(["experimental": .object(["a": .object([:]), "b": .string("mixed")])])
])
func profileKeepsKnownAndMixedCapabilityFieldsStrict(_ capabilities: MCP.Value) async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: base)
    try await inbox.send(initialize(capabilities: capabilities))
    #expect(try parse(await inbox.next())["error"]?.objectValue?["code"] == .int(-32602))
    await server.stop(); await inbox.stop()
}
@Test func profileRejectsMalformedUnknownAndOutOfOrderCallsWithFixedErrors() async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: base)
    try await inbox.raw("{malformed")
    #expect(try parse(await inbox.next())["error"]?.objectValue?["code"] == .int(-32700))
    try await inbox.raw("{}")
    let emptyObject = try parse(await inbox.next())
    #expect(emptyObject["id"] == .null && emptyObject["error"]?.objectValue?["code"] == .int(-32600))
    try await inbox.raw("{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}")
    let invalidID = try parse(await inbox.next())
    #expect(invalidID["id"] == .null && invalidID["error"]?.objectValue?["code"] == .int(-32600))
    try await inbox.send(["jsonrpc": "2.0", "id": "before", "method": "tools/list"])
    #expect(try parse(await inbox.next())["error"]?.objectValue?["code"] == .int(-32600))
    try await ready(inbox)
    try await inbox.send(["jsonrpc": "2.0", "id": "unknown", "method": "private-owner-secret"])
    let unknown = try parse(await inbox.next())
    #expect(unknown["error"]?.objectValue?["code"] == .int(-32601))
    #expect(!String(decoding: try JSONEncoder().encode(unknown), as: UTF8.self).contains("private-owner-secret"))
    try await inbox.send(["jsonrpc": "2.0", "id": "bad", "method": "tools/call", "params": .object(["name": "list_wallets", "owner": .bool(true)])])
    #expect(try parse(await inbox.next())["error"]?.objectValue?["code"] == .int(-32602))
    await server.stop(); await inbox.stop()
}

private actor CancellableClientBoundary: CapabilityTransport {
    var started = 0
    var cancelled = 0
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        started += 1
        do { try await Task.sleep(for: .seconds(20)); throw ClientFailure.unavailable }
        catch is CancellationError { cancelled += 1; throw CancellationError() }
    }
    func waitStarted() async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while started == 0 { guard ContinuousClock.now < end else { throw MCPError.connectionClosed }; try await Task.sleep(for: .milliseconds(2)) }
    }
}
@Test func profileCancellationAndEOFJoinOwnedToolWork() async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let boundary = CancellableClientBoundary()
    let server = MCPToolServer(client: CapabilityClient(transport: boundary)); try await server.start(transport: base)
    try await ready(inbox)
    try await inbox.send(["jsonrpc": "2.0", "id": "held", "method": "tools/call", "params": .object(["name": "list_wallets", "arguments": .object([:])])])
    try await boundary.waitStarted()
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": .object(["requestId": "held"])])
    await inbox.stop()
    await server.waitUntilCompleted()
    #expect(await boundary.started == 1)
    #expect(await boundary.cancelled == 1)
}

@Test func profileInvalidNotificationsNeverEmitUnsolicitedNullIDResponse() async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: base)
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized", "params": .object(["unexpected": .bool(true)])])
    try await ready(inbox)
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized", "params": .object(["unexpected": .bool(true)])])
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": .object(["requestId": .bool(true)])])
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/unknown"])
    try await inbox.send(["jsonrpc": "2.0", "id": "after-notifications", "method": "ping"])
    let next = try parse(await inbox.next())
    #expect(next["id"] == .string("after-notifications"))
    #expect(next["result"] != nil)
    await server.stop(); await inbox.stop()
}

@Test func profileIntegralNumericIDUsesTheSDKIntegerIdentity() async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: base)
    try await inbox.raw("{\"jsonrpc\":\"2.0\",\"id\":1.0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"numeric-id\",\"version\":\"1\"}}}")
    #expect(try parse(await inbox.next())["id"] == .int(1))
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    try await inbox.send(["jsonrpc": "2.0", "id": "numeric-after", "method": "tools/list"])
    #expect(try parse(await inbox.next())["result"]?.objectValue?["tools"]?.arrayValue?.count == 12)
    await server.stop(); await inbox.stop()
}


@Test(arguments: ["2025-11-25", "2025-06-18"])
func profileDiscoveryAcceptsInformationalProtocolMetadata(_ version: String) async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: base)
    let metadata: MCP.Value = .object(["traceparent": "00-00000000000000000000000000000001-0000000000000001-01", "owner": .bool(true)])
    try await inbox.send(initialize(version))
    #expect(try parse(await inbox.next())["result"] != nil)
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized", "params": .object(["_meta": metadata])])
    try await inbox.send(["jsonrpc": "2.0", "id": "metadata-list", "method": "tools/list", "params": .object(["_meta": metadata])])
    #expect(try parse(await inbox.next())["result"]?.objectValue?["tools"]?.arrayValue?.count == 12)
    try await inbox.send(["jsonrpc": "2.0", "id": "metadata-ping", "method": "ping", "params": .object(["_meta": metadata])])
    #expect(try parse(await inbox.next())["result"] != nil)
    // Informational owner-shaped metadata cannot enable the unavailable wallet client.
    try await inbox.send(["jsonrpc": "2.0", "id": "metadata-call", "method": "tools/call", "params": .object(["name": "list_wallets", "arguments": .object([:]), "_meta": metadata])])
    let call = try parse(await inbox.next())["result"]?.objectValue
    #expect(call?["isError"] == .bool(true))
    await server.stop(); await inbox.stop()
}

@Test(arguments: [
    MCP.Value.object(["_meta": .bool(true)]),
    .object(["_meta": .null]),
    .object(["_meta": .array([])]),
    .object(["owner": .bool(true)]),
    .object(["cursor": .string("unissued")]),
    .object(["cursor": .null])
])
func profileDiscoveryKeepsMetadataShapeAndSinglePageCursorStrict(_ params: MCP.Value) async throws {
    let (client, base) = await InMemoryTransport.createConnectedPair()
    let inbox = WireInbox(client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: base)
    try await ready(inbox)
    try await inbox.send(["jsonrpc": "2.0", "id": "invalid-metadata", "method": "tools/list", "params": params])
    #expect(try parse(await inbox.next())["error"]?.objectValue?["code"] == .int(-32602))
    try await inbox.send(["jsonrpc": "2.0", "id": "after-invalid-metadata", "method": "tools/list"])
    #expect(try parse(await inbox.next())["result"]?.objectValue?["tools"]?.arrayValue?.count == 12)
    await server.stop(); await inbox.stop()
}
