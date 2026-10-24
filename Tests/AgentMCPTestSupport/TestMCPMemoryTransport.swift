import AgentMCP
import Foundation

/// A bounded test-only byte channel. Closing either endpoint finishes both directions.
public actor TestMCPMemoryTransport: MCPTransport {
    private let input: AsyncThrowingStream<Data, Error>
    private let incoming: AsyncThrowingStream<Data, Error>.Continuation
    private var peer: TestMCPMemoryTransport?
    private var connected = false
    private var closed = false

    private init() {
        (input, incoming) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(MCPBounds.concurrentRequests))
    }

    public static func createConnectedPair() async -> (client: TestMCPMemoryTransport, server: TestMCPMemoryTransport) {
        let client = TestMCPMemoryTransport(), server = TestMCPMemoryTransport()
        await client.attach(server)
        await server.attach(client)
        return (client, server)
    }

    private func attach(_ peer: TestMCPMemoryTransport) { self.peer = peer; connected = true }
    public func connect() throws {
        guard !closed, peer != nil else { throw MCPTransportError.connectionClosed }
        connected = true
    }
    public func disconnect() async { await close() }
    public func receive() -> AsyncThrowingStream<Data, Error> { input }
    public func send(_ data: Data) async throws {
        guard connected, !closed, let peer else { throw MCPTransportError.connectionClosed }
        guard data.count <= MCPBounds.outputBytes else {
            let error = MCPTransportError.invalidRequest("Test message exceeds capacity")
            await close(error)
            throw error
        }
        do { try await peer.deliver(data) }
        catch { await close(error); throw error }
    }

    private func deliver(_ data: Data) throws {
        guard connected, !closed else { throw MCPTransportError.connectionClosed }
        switch incoming.yield(data) {
        case .enqueued: break
        case .dropped: throw MCPTransportError.invalidRequest("Test message queue exceeds capacity")
        case .terminated: throw MCPTransportError.connectionClosed
        @unknown default: throw MCPTransportError.connectionClosed
        }
    }
    private func close(_ error: (any Error)? = nil) async {
        guard !closed else { return }
        closed = true; connected = false
        incoming.finish(throwing: error)
        let peer = peer; self.peer = nil
        await peer?.peerClosed(error)
    }
    private func peerClosed(_ error: (any Error)?) {
        closed = true; connected = false; peer = nil
        incoming.finish(throwing: error)
    }
}
