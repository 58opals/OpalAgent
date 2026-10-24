import AgentMCP
import Foundation

public struct MCPTestInitialization: Decodable, Sendable {
    public let protocolVersion: String
}
public struct MCPTestToolList: Decodable, Sendable {
    public let tools: [MCPTool]
}

/// A test-only client for the three operations used by the owned integration fixtures.
public actor MCPTestClient {
    private let name: String
    private let version: String
    private var transport: (any MCPTransport)?
    private var reader: Task<Void, Never>?
    private var writes: [UUID: Task<Void, Never>] = [:]
    private var requestWrites: [String: UUID] = [:]
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var stopping: Task<Void, Never>?
    private var started = false
    private var terminal = false
    private var nextID = 0

    public init(name: String, version: String) { self.name = name; self.version = version }

    public func connect(transport base: any MCPTransport) async throws -> MCPTestInitialization {
        guard !started, !terminal else { throw MCPTransportError.connectionClosed }
        started = true; transport = base
        do {
            try await base.connect()
            guard !terminal else { await base.disconnect(); throw MCPTransportError.connectionClosed }
            reader = Task { await self.read(from: base) }
            let initialized: MCPTestInitialization = try await request("initialize", params: .object([
                "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string(name), "version": .string(version)])
            ]))
            try await notify("notifications/initialized")
            return initialized
        } catch { await disconnect(); throw error }
    }

    public func listTools() async throws -> MCPTestToolList { try await request("tools/list") }
    public func callTool(name: String, arguments: [String: MCPValue]? = nil) async throws -> MCPToolResult {
        try await request("tools/call", params: .object([
            "name": .string(name), "arguments": .object(arguments ?? [:])
        ]))
    }

    public func disconnect() async {
        if let stopping { await stopping.value; return }
        terminal = true
        failPending(MCPTransportError.connectionClosed)
        let base = transport, reader = reader, writes = Array(writes.values)
        let cleanup = Task {
            reader?.cancel()
            for write in writes { write.cancel() }
            await base?.disconnect()
            await reader?.value
            for write in writes { await write.value }
        }
        stopping = cleanup
        await cleanup.value
        self.reader = nil; transport = nil
        self.writes.removeAll(); requestWrites.removeAll()
    }

    private func request<Result: Decodable & Sendable>(_ method: String, params: MCPValue? = nil) async throws -> Result {
        guard !terminal, transport != nil else { throw MCPTransportError.connectionClosed }
        nextID += 1
        let id = "test-\(nextID)"
        var object: [String: MCPValue] = ["jsonrpc": "2.0", "id": .string(id), "method": .string(method)]
        object["params"] = params
        let frame = try JSONEncoder().encode(object)
        let data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                beginWrite(frame, requestID: id)
            }
        } onCancel: { Task { await self.cancelRequest(id) } }
        try Task.checkCancellation()
        let reply = try JSONDecoder().decode(Reply<Result>.self, from: data)
        guard reply.jsonrpc == "2.0", reply.id == id, reply.error == nil, let result = reply.result else {
            throw MCPTransportError.invalidRequest("Test request failed")
        }
        return result
    }

    private func notify(_ method: String) async throws {
        let frame = try JSONEncoder().encode(["jsonrpc": MCPValue.string("2.0"), "method": .string(method)])
        try await withCheckedThrowingContinuation { continuation in beginWrite(frame, completion: continuation) }
    }

    private func beginWrite(_ frame: Data, requestID: String? = nil,
                            completion: CheckedContinuation<Void, Error>? = nil) {
        guard !terminal, let transport else {
            if let requestID { pending.removeValue(forKey: requestID)?.resume(throwing: MCPTransportError.connectionClosed) }
            completion?.resume(throwing: MCPTransportError.connectionClosed)
            return
        }
        let token = UUID()
        let task = Task {
            do { try await transport.send(frame); completion?.resume() }
            catch {
                completion?.resume(throwing: error)
                terminal = true
                failPending(error)
                await transport.disconnect()
            }
            writes.removeValue(forKey: token)
            if let requestID, requestWrites[requestID] == token { requestWrites.removeValue(forKey: requestID) }
        }
        writes[token] = task
        if let requestID { requestWrites[requestID] = token }
    }

    private func cancelRequest(_ id: String) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.resume(throwing: CancellationError())
        if let token = requestWrites[id], let write = writes[token] { await write.value }
        guard !terminal else { return }
        if let frame = try? JSONEncoder().encode(["jsonrpc": MCPValue.string("2.0"),
            "method": .string("notifications/cancelled"), "params": .object(["requestId": .string(id)])]) {
            beginWrite(frame)
        }
    }

    private func read(from base: any MCPTransport) async {
        do {
            for try await data in await base.receive() {
                try Task.checkCancellation()
                let reply = try JSONDecoder().decode(ReplyID.self, from: data)
                guard reply.jsonrpc == "2.0", let id = reply.id else {
                    throw MCPTransportError.invalidRequest("Invalid test reply")
                }
                pending.removeValue(forKey: id)?.resume(returning: data)
            }
        } catch { /* Pending calls receive the fixed connection failure below. */ }
        terminal = true
        failPending(MCPTransportError.connectionClosed)
        await base.disconnect()
    }
    private func failPending(_ error: any Error) {
        let calls = Array(pending.values); pending.removeAll()
        for call in calls { call.resume(throwing: error) }
    }
    private struct ReplyID: Decodable { let jsonrpc: String; let id: String? }
    private struct Reply<Result: Decodable>: Decodable {
        let jsonrpc: String
        let id: String
        let result: Result?
        let error: Failure?
        struct Failure: Decodable { let code: Int }
    }
}
