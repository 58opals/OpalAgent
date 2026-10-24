import AgentClient
import AgentMCP
import AgentValues
import Foundation
import AgentMCPTestSupport
import Testing
@testable import AgentProtocolFixture
@testable import AgentServiceCore

enum WireFixtureFailure: Error { case deadline, invalidReply }
func wireEventually(_ description: String, _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("\(description)")
    throw WireFixtureFailure.deadline
}
struct WireReply: Sendable {
    let fields: [String: MCPValue]
    let isError: Bool?
    var result: [String: MCPValue] { fields["result"]?.objectValue ?? [:] }
    var operation: [String: MCPValue] { result["operation"]?.objectValue ?? result }
    var errorCode: String? { fields["error"]?.objectValue?["code"]?.stringValue }
    var operationID: String? {
        operation["identity"]?.objectValue?["selector"]?.objectValue?["operationID"]?.stringValue
    }
}

/// Drops exactly one already-produced tool reply. No business inputs or service outcomes are replaced.
actor DropToolReplyTransport: MCPTransport {
    private let base: TestMCPMemoryTransport
    private let tool: String
    private var target: MCPValue?
    private var reader: Task<Void, Never>?
    private(set) var didDrop = false
    init(base: TestMCPMemoryTransport, tool: String) { self.base = base; self.tool = tool }
    func connect() async throws { try await base.connect() }
    func disconnect() async {
        reader?.cancel()
        await base.disconnect()
        await reader?.value
        reader = nil
    }
    func send(_ data: Data) async throws {
        let value = try? JSONDecoder().decode([String: MCPValue].self, from: data)
        if !didDrop, let target, value?["id"] == target,
           value?["result"] != nil || value?["error"] != nil { didDrop = true; return }
        try await base.send(data)
    }
    func receive() -> AsyncThrowingStream<Data, any Error> {
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        try Task.checkCancellation()
                        record(data)
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            reader = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func record(_ data: Data) {
        guard let value = try? JSONDecoder().decode([String: MCPValue].self, from: data),
              value["method"]?.stringValue == "tools/call",
              value["params"]?.objectValue?["name"]?.stringValue == tool else { return }
        target = value["id"]
    }
}

final class WireSession: Sendable {
    let client: MCPTestClient
    let server: MCPToolServer
    let drop: DropToolReplyTransport?
    let admission: FixtureClientSession
    private init(client: MCPTestClient, server: MCPToolServer, drop: DropToolReplyTransport?, admission: FixtureClientSession) {
        self.client = client; self.server = server; self.drop = drop; self.admission = admission
    }
    static func connect(session admission: FixtureClientSession, dropping tool: String? = nil) async throws -> WireSession {
        let pair = await TestMCPMemoryTransport.createConnectedPair()
        let server = MCPToolServer(client: admission.client)
        let drop = tool.map { DropToolReplyTransport(base: pair.server, tool: $0) }
        let client = MCPTestClient(name: "OpalAgent synthetic integration", version: "1.0.0")
        do {
            if let drop { try await server.start(transport: drop) }
            else { try await server.start(transport: pair.server) }
            let initialized = try await client.connect(transport: pair.client)
            #expect(initialized.protocolVersion == "2025-11-25")
            return WireSession(client: client, server: server, drop: drop, admission: admission)
        } catch { await admission.close(); await client.disconnect(); await server.stop(); throw error }
    }
    func call(_ name: String, _ arguments: [String: MCPValue]) async throws -> WireReply {
        let reply = try await client.callTool(name: name, arguments: arguments)
        guard reply.content.count == 1, case let .text(text, _, _) = reply.content[0] else {
            throw WireFixtureFailure.invalidReply
        }
        let fields = try JSONDecoder().decode([String: MCPValue].self, from: Data(text.utf8))
        #expect(reply.structuredContent == .object(fields))
        if reply.isError != true { #expect(fields["method"]?.stringValue == name && fields["ok"]?.boolValue == true) }
        return WireReply(fields: fields, isError: reply.isError)
    }
    func close() async {
        await admission.close()
        await client.disconnect()
        await server.stop()
        await server.waitUntilCompleted()
    }
}
func fixtureDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("opal-agent-protocol-\(UUID().uuidString)")
}
func accountValue(_ fixture: FixtureRuntime) -> MCPValue {
    .object(["wallet": .object(["walletID": .string(fixture.account.wallet.walletID), "network": .string("mainnet")]),
             "accountID": .string(fixture.account.accountID)])
}
func key(_ index: Int) -> String {
    let suffix = String(index, radix: 16)
    return String(repeating: "0", count: 32 - suffix.count) + suffix
}
func keyed(_ fixture: FixtureRuntime, _ index: Int) -> [String: MCPValue] {
    ["account": accountValue(fixture), "requestKey": .string(key(index))]
}
func selector(_ fixture: FixtureRuntime, _ id: String) -> [String: MCPValue] {
    ["account": accountValue(fixture), "operationID": .string(id)]
}
func payment(_ fixture: FixtureRuntime, _ index: Int) -> [String: MCPValue] {
    var result = keyed(fixture, index)
    result["destinationAddress"] = .string(FixtureRuntime.destination)
    result["amountSatoshis"] = .string("10000")
    return result
}
func operation(_ session: WireSession, _ fixture: FixtureRuntime, _ id: String) async throws -> WireReply {
    try await session.call("get_operation", ["operation": .object(selector(fixture, id))])
}
func waitOperation(_ session: WireSession, _ fixture: FixtureRuntime, _ id: String, state: String) async throws -> WireReply {
    try await wireEventually("Expected retained operation \(state)") {
        try await operation(session, fixture, id).operation["state"]?.stringValue == state
    }
    return try await operation(session, fixture, id)
}
