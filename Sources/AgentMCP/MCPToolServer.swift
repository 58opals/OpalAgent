import AgentClient
import Foundation

/// The bounded stdio tools server. Wallet effects remain owned by the service client.
public actor MCPToolServer {
    private let dispatch: ToolDispatch
    private var transport: ProfileTransport?
    private var reader: Task<Void, Never>?
    private var requests: [RequestID: Task<Void, Never>] = [:]
    private var stopping: Task<Void, Never>?
    private var started = false

    public init(client: CapabilityClient = CapabilityClient()) {
        dispatch = ToolDispatch(client: client)
    }

    public func start(transport base: any MCPTransport) async throws {
        guard !started, stopping == nil else { throw MCPTransportError.connectionClosed }
        started = true
        let checked = ProfileTransport(base: base)
        transport = checked
        do { try await checked.connect() }
        catch { await checked.disconnect(); throw error }
        // stop() may finish while an asynchronous lower connect is suspended.
        // A late connection cannot publish new reader work after terminal cleanup.
        guard stopping == nil else {
            await checked.disconnect()
            throw MCPTransportError.connectionClosed
        }
        reader = Task { await self.readMessages(from: checked) }
    }

    public func waitUntilCompleted() async {
        await reader?.value
        await stop()
    }

    public func stop() async {
        if let stopping { await stopping.value; return }
        let transport = transport, reader = reader, pending = Array(requests.values)
        // A separate cleanup task is never entered from its reader or a handler.
        // Disconnect releases held lower writes before any of those tasks are joined.
        let cleanup = Task {
            reader?.cancel()
            for task in pending { task.cancel() }
            await transport?.disconnect()
            await reader?.value
            for task in pending { await task.value }
        }
        stopping = cleanup
        await cleanup.value
        self.reader = nil
        self.transport = nil
        requests.removeAll()
    }

    private func readMessages(from transport: ProfileTransport) async {
        do {
            for try await frame in await transport.receive() {
                try Task.checkCancellation()
                accept(frame, transport: transport)
            }
        } catch { /* Only fixed transport/protocol diagnostics cross this boundary. */ }
        // EOF cancels local waiting work; waitUntilCompleted performs the actual join.
        for task in requests.values { task.cancel() }
    }

    private func accept(_ frame: Data, transport: ProfileTransport) {
        guard stopping == nil, let envelope = try? JSONDecoder().decode(Envelope.self, from: frame) else { return }
        if envelope.method == "notifications/cancelled" {
            if let request = try? JSONDecoder().decode(Request<CancellationParameters>.self, from: frame) {
                requests[request.params.requestId]?.cancel()
            }
            return
        }
        guard let id = envelope.id else { return }
        // The profile gate has already bounded and reserved this unique request ID.
        // Register before admitting another frame so cancellation cannot overtake it.
        requests[id] = Task { await self.respond(to: envelope.method, id: id, frame: frame, transport: transport) }
    }

    private func respond(to method: String, id: RequestID, frame: Data, transport: ProfileTransport) async {
        defer { requests.removeValue(forKey: id) }
        do {
            try Task.checkCancellation()
            switch method {
            case "initialize":
                let request = try JSONDecoder().decode(Request<InitializeParameters>.self, from: frame)
                try await send(Initialization(protocolVersion: request.params.protocolVersion), id: id, over: transport)
            case "ping":
                try await send(Empty(), id: id, over: transport)
            case "tools/list":
                try await send(Tools(tools: ToolCatalog.tools()), id: id, over: transport)
            case "tools/call":
                let request = try JSONDecoder().decode(Request<ToolParameters>.self, from: frame)
                let result = await dispatch.call(name: request.params.name, arguments: request.params.arguments)
                // A service error projection must not turn cancellation into a normal reply.
                try Task.checkCancellation()
                try await send(result, id: id, over: transport)
            default: break // The profile gate admits no other request methods.
            }
        } catch is CancellationError {
            // Cancellation suppresses the response and leaves the profile's capacity reserved.
        } catch {
            // Send failures close input, but never await this task through stop/join.
            guard !Task.isCancelled else { return }
            do { try await transport.send(Self.encoder().encode(Failure(id: id))) }
            catch { await transport.disconnect() }
        }
    }

    private func send<Result: Encodable & Sendable>(_ result: Result, id: RequestID, over transport: ProfileTransport) async throws {
        try Task.checkCancellation()
        try await transport.send(Self.encoder().encode(Response(id: id, result: result)))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// IDs remain strings or exact canonical integers independently of generic JSON
    /// values: a string identifier beginning with data: remains a string identifier.
    private enum RequestID: Hashable, Codable, Sendable {
        case string(String), integer(Int)
        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) { self = .string(string) }
            else { self = .integer(try value.decode(Int.self)) }
        }
        func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .string(let string): try value.encode(string)
            case .integer(let integer): try value.encode(integer)
            }
        }
    }
    private struct Envelope: Decodable { let id: RequestID?; let method: String }
    private struct Request<Parameters: Decodable>: Decodable { let params: Parameters }
    private struct InitializeParameters: Decodable { let protocolVersion: String }
    private struct ToolParameters: Decodable { let name: String; let arguments: [String: MCPValue]? }
    private struct CancellationParameters: Decodable { let requestId: RequestID }
    private struct Response<Result: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: RequestID
        let result: Result
    }
    private struct Empty: Encodable, Sendable {}
    private struct Tools: Encodable, Sendable { let tools: [MCPTool] }
    private struct Initialization: Encodable, Sendable {
        let protocolVersion: String
        let capabilities = Capabilities()
        let serverInfo = ServerInfo()
        struct Capabilities: Encodable, Sendable { let tools = Empty() }
        struct ServerInfo: Encodable, Sendable { let name = "OpalAgent"; let version = "0.1.0" }
    }
    private struct Failure: Encodable {
        let jsonrpc = "2.0"
        let id: RequestID
        let error = Detail()
        struct Detail: Encodable { let code = -32603; let message = "Request failed" }
    }
}
