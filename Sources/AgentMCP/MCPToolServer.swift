import AgentClient
import Foundation
import MCP

/// The adapter has no service engine or persistence dependency.
public actor MCPToolServer {
    private let server: Server
    private let calls = ToolTaskLifetime()
    private var transport: ProfileTransport?
    private var started = false

    public init(client: CapabilityClient = CapabilityClient()) {
        server = Server(name: "OpalAgent", version: "0.1.0", capabilities: .init(tools: .init()), configuration: .strict)
        let dispatch = ToolDispatch(client: client)
        self.dispatch = dispatch
    }
    private let dispatch: ToolDispatch

    public func start(transport: any Transport) async throws {
        guard !started else { throw MCPError.connectionClosed }
        started = true
        let dispatch = dispatch
        let calls = calls
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.tools()) }
        await server.withMethodHandler(CallTool.self) { parameters in
            try await calls.run {
                try Task.checkCancellation()
                let result = await dispatch.call(name: parameters.name, arguments: parameters.arguments)
                try Task.checkCancellation()
                return result
            }
        }
        let checked = ProfileTransport(base: transport)
        self.transport = checked
        try await server.start(transport: checked)
    }
    public func waitUntilCompleted() async {
        await server.waitUntilCompleted()
        await stop()
    }
    public func stop() async {
        // End input/output before cancelling and joining adapter-owned work.
        await server.stop()
        await calls.stop()
        transport = nil
    }
}

private actor ToolTaskLifetime {
    private var tasks: [UUID: Task<CallTool.Result, Error>] = [:]
    private var stopped = false
    func run(_ body: @escaping @Sendable () async throws -> CallTool.Result) async throws -> CallTool.Result {
        guard !stopped, tasks.count < MCPBounds.concurrentRequests else { throw MCPError.internalError("Unavailable") }
        let id = UUID()
        let task = Task { try await body() }
        tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
    func stop() async {
        stopped = true
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
    }
}
