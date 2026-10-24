import AgentClient
import AgentValues
import Foundation
import AgentMCPTestSupport
import Testing
@testable import AgentMCP

private actor WireInbox {
    private let transport: TestMCPMemoryTransport
    private var frames: [Data] = []
    private var task: Task<Void, Never>?
    init(_ transport: TestMCPMemoryTransport) { self.transport = transport }
    func start() async throws {
        try await transport.connect()
        task = Task {
            do { for try await data in await transport.receive() { frames.append(data) } } catch {}
        }
        await Task.yield()
    }
    func send(_ object: [String: MCPValue]) async throws {
        try await transport.send(JSONEncoder().encode(object))
    }
    func raw(_ text: String) async throws { try await transport.send(Data(text.utf8)) }
    func next() async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while frames.isEmpty {
            guard ContinuousClock.now < deadline else { throw MCPTransportError.connectionClosed }
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
private func initialize(_ version: String = "2025-11-25", capabilities: MCPValue = .object([:])) -> [String: MCPValue] {
    ["jsonrpc": "2.0", "id": "init", "method": "initialize", "params": .object([
        "protocolVersion": .string(version), "capabilities": capabilities,
        "clientInfo": .object(["name": "profile-test", "version": "1"])
    ])]
}
private func parse(_ data: Data) throws -> [String: MCPValue] { try JSONDecoder().decode([String: MCPValue].self, from: data) }
private func ready(_ inbox: WireInbox) async throws {
    try await inbox.send(initialize())
    #expect(try parse(await inbox.next())["result"] != nil)
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
}

@Test(arguments: ["2025-11-25", "2025-06-18"])
func profilePreservesOnlyQualifiedVersionsAndListsTwelve(_ version: String) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    try await inbox.send(["jsonrpc": "2.0", "id": 7, "method": "ping"])
    #expect(try parse(await inbox.next()) == ["jsonrpc": "2.0", "id": 7, "result": .object([:])])
    try await inbox.send(initialize(version))
    let response = try parse(await inbox.next())
    #expect(response == ["jsonrpc": "2.0", "id": "init", "result": .object([
        "protocolVersion": .string(version),
        "capabilities": .object(["tools": .object([:])]),
        "serverInfo": .object(["name": "OpalAgent", "version": "0.1.0"])
    ])])
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    try await inbox.send(["jsonrpc": "2.0", "id": "list", "method": "tools/list"])
    let listed = try parse(await inbox.next())["result"]?.objectValue?["tools"]?.arrayValue
    #expect(listed?.count == 12)
    await server.stop(); await inbox.stop()
}
@Test(arguments: ["2024-11-05", "2025-03-26", "2099-01-01"])
func profileRejectsOtherSDKAndUnknownVersionsWithoutNegotiating(_ version: String) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    try await inbox.send(initialize(version))
    let response = try parse(await inbox.next())
    #expect(response["id"] == .string("init"))
    #expect(response["error"]?.objectValue?["code"] == .int(-32602))
    #expect(response["result"] == nil)
    await server.waitUntilCompleted(); await inbox.stop()
}
@Test func profileIgnoresOnlyOptionalObjectExperimentalCapability() async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    try await inbox.send(initialize(capabilities: .object(["experimental": .object(["host/optional": .object([:])])])))
    #expect(try parse(await inbox.next())["result"] != nil)
    await server.stop(); await inbox.stop()
}
@Test(arguments: [
    MCPValue.object(["roots": .object(["listChanged": .string("true")])]),
    .object(["sampling": .object(["tools": .bool(true)])]),
    .object(["elicitation": .object(["form": .object(["owner": .bool(true)])])]),
    .object(["experimental": .object(["a": .object([:]), "b": .string("mixed")])])
])
func profileKeepsKnownAndMixedCapabilityFieldsStrict(_ capabilities: MCPValue) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    try await inbox.send(initialize(capabilities: capabilities))
    #expect(try parse(await inbox.next())["error"]?.objectValue?["code"] == .int(-32602))
    await server.stop(); await inbox.stop()
}
@Test func profileRejectsMalformedUnknownAndOutOfOrderCallsWithFixedErrors() async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
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
        while started == 0 { guard ContinuousClock.now < end else { throw MCPTransportError.connectionClosed }; try await Task.sleep(for: .milliseconds(2)) }
    }
    func waitCancelled() async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while cancelled == 0 { guard ContinuousClock.now < end else { throw MCPTransportError.connectionClosed }; try await Task.sleep(for: .milliseconds(2)) }
    }
}
enum ProfileCancellationCause: Sendable, CaseIterable { case notification, inputEOF }
@Test(arguments: ProfileCancellationCause.allCases)
func profileCancellationAndEOFJoinOwnedToolWork(_ cause: ProfileCancellationCause) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let boundary = CancellableClientBoundary()
    let server = MCPToolServer(client: CapabilityClient(transport: boundary)); try await server.start(transport: pair.server)
    do {
        try await ready(inbox)
        try await inbox.send(["jsonrpc": "2.0", "id": "held", "method": "tools/call", "params": .object(["name": "list_wallets", "arguments": .object([:])])])
        try await boundary.waitStarted()
        if cause == .notification {
            try await inbox.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": .object(["requestId": "held"])])
            // EOF/stop must not supply this notification-specific cancellation witness.
            try await boundary.waitCancelled()
            #expect(await boundary.cancelled == 1)
        }
        await inbox.stop()
        await server.waitUntilCompleted()
        #expect(await boundary.started == 1)
        #expect(await boundary.cancelled == 1)
    } catch {
        await inbox.stop(); await server.stop()
        throw error
    }
}

@Test func profileDataURLShapedRequestIDsRemainStringsAndCancelOwnedToolWork() async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let boundary = CancellableClientBoundary()
    let server = MCPToolServer(client: CapabilityClient(transport: boundary)); try await server.start(transport: pair.server)
    do {
        try await inbox.raw("{\"jsonrpc\":\"2.0\",\"id\":\"data:text/plain;base64,aWQ=\",\"method\":\"ping\"}")
        // Generic value decoders can interpret data URLs as media; request IDs must stay strings.
        let replyData = try await inbox.next()
        let reply = try #require(try JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        #expect(reply["id"] as? String == "data:text/plain;base64,aWQ=")
        #expect((reply["result"] as? [String: Any])?.isEmpty == true)
        #expect(reply["error"] == nil)
        try await ready(inbox)
        try await inbox.raw("{\"jsonrpc\":\"2.0\",\"id\":\"data:text/plain;base64,aGVsZA==\",\"method\":\"tools/call\",\"params\":{\"name\":\"list_wallets\",\"arguments\":{}}}")
        try await boundary.waitStarted()
        try await inbox.raw("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"data:text/plain;base64,aGVsZA==\"}}")
        // Observe notification-specific cancellation before stop/EOF can cancel the work.
        try await boundary.waitCancelled()
        #expect(await boundary.started == 1)
        #expect(await boundary.cancelled == 1)
    } catch {
        await inbox.stop(); await server.stop()
        throw error
    }
    await server.stop(); await inbox.stop()
}

@Test func profileInvalidNotificationsNeverEmitUnsolicitedNullIDResponse() async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
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

@Test func profileIntegralNumericIDUsesTheIntegerIdentity() async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    try await inbox.raw("{\"jsonrpc\":\"2.0\",\"id\":1.0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"numeric-id\",\"version\":\"1\"}}}")
    #expect(try parse(await inbox.next())["id"] == .int(1))
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    try await inbox.send(["jsonrpc": "2.0", "id": "numeric-after", "method": "tools/list"])
    #expect(try parse(await inbox.next())["result"]?.objectValue?["tools"]?.arrayValue?.count == 12)
    await server.stop(); await inbox.stop()
}


@Test(arguments: ["2025-11-25", "2025-06-18"])
func profileDiscoveryAcceptsInformationalProtocolMetadata(_ version: String) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    let metadata: MCPValue = .object(["traceparent": "00-00000000000000000000000000000001-0000000000000001-01", "owner": .bool(true)])
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
    MCPValue.object(["_meta": .bool(true)]),
    .object(["_meta": .null]),
    .object(["_meta": .array([])]),
    .object(["owner": .bool(true)]),
    .object(["cursor": .string("unissued")]),
    .object(["cursor": .null])
])
func profileDiscoveryKeepsMetadataShapeAndSinglePageCursorStrict(_ params: MCPValue) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    try await ready(inbox)
    try await inbox.send(["jsonrpc": "2.0", "id": "invalid-metadata", "method": "tools/list", "params": params])
    #expect(try parse(await inbox.next())["error"]?.objectValue?["code"] == .int(-32602))
    try await inbox.send(["jsonrpc": "2.0", "id": "after-invalid-metadata", "method": "tools/list"])
    #expect(try parse(await inbox.next())["result"]?.objectValue?["tools"]?.arrayValue?.count == 12)
    await server.stop(); await inbox.stop()
}

@Test(arguments: [
    "\"title\":true",
    "\"description\":7",
    "\"websiteUrl\":[]",
    "\"icons\":false",
    "\"icons\":[{}]",
    "\"icons\":[{\"src\":7}]",
    "\"icons\":[{\"src\":\"unused\",\"mimeType\":true}]",
    "\"icons\":[{\"src\":\"unused\",\"sizes\":[1]}]",
    "\"icons\":[{\"src\":\"unused\",\"theme\":\"unrecognized\"}]"
])
func profileRejectsMalformedOptionalClientMetadataWithoutPoisoningInitialization(_ field: String) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    // Literal wire fields are independent of the owned metadata representation. The prior
    // SDK typed decode projected these optional-field failures as a fixed -32603 response.
    try await inbox.raw("{\"jsonrpc\":\"2.0\",\"id\":\"bad-init\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"metadata-test\",\"version\":\"1\",\(field)}}}")
    let rejected = try parse(await inbox.next())
    #expect(rejected["id"] == .string("bad-init"))
    #expect(rejected["error"]?.objectValue?["code"] == .int(-32603))
    #expect(rejected["error"]?.objectValue?["message"] == .string("Request failed"))
    #expect(rejected["result"] == nil)
    try await ready(inbox)
    try await inbox.send(["jsonrpc": "2.0", "id": "after-invalid-client-info", "method": "tools/list"])
    #expect(try parse(await inbox.next())["result"]?.objectValue?["tools"]?.arrayValue?.count == 12)
    await server.stop(); await inbox.stop()
}

@Test(arguments: [
    "\"title\":null,\"description\":null,\"websiteUrl\":null,\"icons\":null,\"unknown\":{\"owner\":true}",
    "\"title\":\"Client display name\",\"description\":\"Informational\",\"websiteUrl\":\"not authority\",\"icons\":[{\"src\":\"unused\",\"mimeType\":null,\"sizes\":[\"any\"],\"theme\":\"dark\",\"unknown\":true}]"
])
func profileAcceptsOptionalClientMetadataWithoutTreatingItAsAuthority(_ fields: String) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    try await inbox.raw("{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"metadata-test\",\"version\":\"1\",\(fields)}}}")
    #expect(try parse(await inbox.next())["result"]?.objectValue?["protocolVersion"] == .string("2025-11-25"))
    try await inbox.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    try await inbox.send(["jsonrpc": "2.0", "id": "after-client-metadata", "method": "tools/call", "params": .object(["name": "list_wallets", "arguments": .object([:])])])
    let call = try parse(await inbox.next())["result"]?.objectValue
    #expect(call?["isError"] == .bool(true))
    #expect(call?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("unavailable"))
    await server.stop(); await inbox.stop()
}

@Test(arguments: ["null", "false", "1.5", "9007199254740992", "-9007199254740992",
                  "\"" + String(repeating: "界", count: 43) + "\""])
func profileRejectsNoncanonicalOrOversizeRequestIDs(_ wireID: String) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    try await inbox.raw("{\"jsonrpc\":\"2.0\",\"id\":\(wireID),\"method\":\"ping\"}")
    let rejected = try parse(await inbox.next())
    #expect(rejected["id"] == .null)
    #expect(rejected["error"]?.objectValue?["code"] == .int(-32600))
    await server.stop(); await inbox.stop()
}

@Test(arguments: ["9007199254740991", "-9007199254740991",
                  "\"" + String(repeating: "a", count: 128) + "\""])
func profileAcceptsExactRequestIDBounds(_ wireID: String) async throws {
    let pair = await TestMCPMemoryTransport.createConnectedPair()
    let inbox = WireInbox(pair.client); try await inbox.start()
    let server = MCPToolServer(); try await server.start(transport: pair.server)
    try await inbox.raw("{\"jsonrpc\":\"2.0\",\"id\":\(wireID),\"method\":\"ping\"}")
    let reply = try parse(await inbox.next())
    let expectedID = try JSONDecoder().decode(MCPValue.self, from: Data(wireID.utf8))
    #expect(reply["id"] == expectedID)
    #expect(reply["result"] == .object([:]))
    #expect(reply["error"] == nil)
    await server.stop(); await inbox.stop()
}
