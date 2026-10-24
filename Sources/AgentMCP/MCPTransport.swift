import Foundation

/// A borrowed, bounded message channel. Implementations own their asynchronous work,
/// but callers retain ownership of any file descriptors supplied at construction.
public protocol MCPTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func receive() async -> AsyncThrowingStream<Data, Error>
}

public enum MCPTransportError: Error, Sendable, Equatable {
    case connectionClosed
    case invalidRequest(String)
}
