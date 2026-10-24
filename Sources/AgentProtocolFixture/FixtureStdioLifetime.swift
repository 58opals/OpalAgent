#if DEBUG
import AgentMCP
import Foundation

/// Runs host-owned admission closure on input termination before the protocol server joins suspended handlers.
/// The host chooses explicit fixture-fault release separately and awaits factual drain.
actor FixtureStdioLifetime: MCPTransport {
    private let base: any MCPTransport
    private let ended: @Sendable () async -> Void
    private let outputSendFailed: @Sendable () async -> Void
    private var reader: Task<Void, Never>?
    private var disconnecting = false
    private var activeSends = 0
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    init(base: any MCPTransport, ended: @escaping @Sendable () async -> Void,
         outputSendFailed: @escaping @Sendable () async -> Void = {}) {
        self.base = base; self.ended = ended; self.outputSendFailed = outputSendFailed
    }
    func connect() async throws { try await base.connect() }
    func send(_ data: Data) async throws {
        guard !disconnecting else { throw MCPTransportError.connectionClosed }
        activeSends += 1
        defer {
            activeSends -= 1
            if activeSends == 0 {
                let waiters = sendWaiters; sendWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        do { try await base.send(data) }
        catch {
            // A lower send failed; its public error does not expose a syscall errno.
            await outputSendFailed()
            throw error
        }
    }
    func receive() -> AsyncThrowingStream<Data, any Error> {
        let base = self.base, ended = self.ended
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(MCPBounds.concurrentRequests)) { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        try Task.checkCancellation()
                        switch continuation.yield(data) {
                        case .enqueued: break
                        case .dropped, .terminated: throw MCPTransportError.invalidRequest("Input capacity exceeded")
                        @unknown default: throw MCPTransportError.connectionClosed
                        }
                    }
                    await ended()
                    continuation.finish()
                } catch {
                    await ended()
                    continuation.finish(throwing: error)
                }
            }
            reader = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func disconnect() async {
        disconnecting = true
        reader?.cancel()
        // Release queued lower sends before joining their observers. A send retires
        // before rethrowing into the protocol server's disconnect, avoiding self-join.
        await base.disconnect()
        if activeSends > 0 {
            await withCheckedContinuation { sendWaiters.append($0) }
        }
        await reader?.value
        reader = nil
    }
}
#endif
