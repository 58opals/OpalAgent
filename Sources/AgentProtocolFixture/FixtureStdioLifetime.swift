#if DEBUG
import AgentMCP
import Foundation
import MCP

/// Closes service admission on stdio EOF before the SDK can begin joining suspended handlers.
/// The host chooses explicit fixture-fault release separately and awaits factual drain.
actor FixtureStdioLifetime: MCP.Transport {
    nonisolated let logger = MCP.InMemoryTransport().logger
    private let base = BoundedStdioTransport()
    private let ended: @Sendable () async -> Void
    private var reader: Task<Void, Never>?
    init(ended: @escaping @Sendable () async -> Void) { self.ended = ended }
    func connect() async throws { try await base.connect() }
    func send(_ data: Data) async throws { try await base.send(data) }
    func receive() -> AsyncThrowingStream<Data, any Error> {
        let base = self.base, ended = self.ended
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        try Task.checkCancellation()
                        continuation.yield(data)
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
        reader?.cancel()
        await base.disconnect()
        await reader?.value
        reader = nil
    }
}
#endif
