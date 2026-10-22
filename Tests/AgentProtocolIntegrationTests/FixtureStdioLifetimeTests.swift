import Foundation
import MCP
import Testing
@testable import AgentProtocolFixture

/// Delivers only on demand: no lower queue, overflow, error or EOF can close the wrapper.
private actor OpenFrameSource: MCP.Transport {
    nonisolated let logger = MCP.InMemoryTransport().logger
    private var emitted = 0
    private var closed = false
    private var waiting: CheckedContinuation<Data?, Never>?

    func connect() {}
    func send(_ data: Data) throws { throw MCPError.connectionClosed }
    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(unfolding: { await self.next() })
    }
    private func next() async -> Data? {
        guard !closed else { return nil }
        if emitted < 17 {
            emitted += 1
            return Data("{\"frame\":\(emitted)}".utf8)
        }
        return await withCheckedContinuation { waiting = $0 }
    }
    func facts() -> (emitted: Int, closed: Bool) { (emitted, closed) }
    func disconnect() {
        closed = true
        waiting?.resume(returning: nil); waiting = nil
    }
}

private actor StdioEndObservation {
    private(set) var count = 0
    func record() { count += 1 }
}

@Test func fixtureStdioLifetimeRejectsInputOverflowBeforeLowerTermination() async throws {
    let source = OpenFrameSource(), ended = StdioEndObservation()
    let transport = FixtureStdioLifetime(base: source, ended: { await ended.record() })
    try await transport.connect()
    // Intentionally leave this consumer paused while the wrapper reads the open lower source.
    let input = await transport.receive()
    do {
        try await wireEventually("The demand-driven lower source must deliver seventeen frames") {
            await source.facts().emitted == 17
        }
        try await wireEventually("The wrapper must close its own full input queue before lower termination or test cleanup") {
            await ended.count == 1
        }
        let lower = await source.facts()
        #expect(lower.emitted == 17 && !lower.closed)
        var received = 0, capacityFailure = false
        do { for try await _ in input { received += 1 } }
        catch MCPError.invalidRequest(_) { capacityFailure = true }
        #expect(capacityFailure && received <= 16)
        #expect(await ended.count == 1)
    } catch {
        await transport.disconnect()
        throw error
    }
    // Closing the lower source only cleans up after the wrapper-owned terminal observation.
    await transport.disconnect()
}
