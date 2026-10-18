import Darwin
import Foundation
import Logging
import MCP

public enum MCPBounds {
    public static let inputBytes = 65_536
    public static let outputBytes = 262_144
    public static let concurrentRequests = 16
}

/// Newline framing is bounded before appending stdin bytes, independently of SDK decoding.
public actor BoundedStdioTransport: Transport {
    public nonisolated let logger = Logger(label: "opal.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
    private let input: Int32
    private let output: Int32
    private var connected = false
    private var used = false
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private struct Write {
        let bytes: Data
        let completion: CheckedContinuation<Void, Error>
    }
    private var writes: [Write] = []

    public init(inputDescriptor: Int32 = STDIN_FILENO, outputDescriptor: Int32 = STDOUT_FILENO) {
        input = inputDescriptor
        output = outputDescriptor
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(MCPBounds.concurrentRequests))
    }

    public func connect() throws {
        guard !used else { throw MCPError.connectionClosed }
        used = true
        for descriptor in [input, output] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw MCPError.connectionClosed
            }
        }
        // Broken stdout must fail a write rather than terminate a process with SIGPIPE.
        guard fcntl(output, F_SETNOSIGPIPE, 1) == 0 else { throw MCPError.connectionClosed }
        connected = true
        reader = Task { await readFrames() }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> { stream }

    public func send(_ data: Data) async throws {
        guard connected, data.count <= MCPBounds.outputBytes, !data.contains(10),
              writes.count < MCPBounds.concurrentRequests else { throw MCPError.connectionClosed }
        var framed = data
        framed.append(10)
        try await withCheckedThrowingContinuation { completion in
            writes.append(Write(bytes: framed, completion: completion))
            if writer == nil { writer = Task { await writeFrames() } }
        }
    }

    public func disconnect() async {
        connected = false
        continuation.finish()
        reader?.cancel()
        writer?.cancel()
        let pending = writes
        writes.removeAll()
        for item in pending { item.completion.resume(throwing: MCPError.connectionClosed) }
        let oldReader = reader
        let oldWriter = writer
        reader = nil
        writer = nil
        await oldReader?.value
        await oldWriter?.value
    }

    private func readFrames() async {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()
        while connected && !Task.isCancelled {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count == 0 {
                // A non-newline-terminated final fragment is not a complete stdio message.
                if pending.isEmpty { continuation.finish() }
                else { continuation.finish(throwing: MCPError.invalidRequest("Incomplete frame")) }
                return
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
                    continue
                }
                continuation.finish(throwing: MCPError.connectionClosed)
                return
            }
            var start = 0
            for index in 0..<count where buffer[index] == 10 {
                let segment = buffer[start..<index]
                guard pending.count <= MCPBounds.inputBytes - segment.count else {
                    continuation.finish(throwing: MCPError.invalidRequest("Frame too large"))
                    return
                }
                pending.append(contentsOf: segment)
                guard !pending.isEmpty else {
                    continuation.finish(throwing: MCPError.invalidRequest("Empty frame"))
                    return
                }
                switch continuation.yield(pending) {
                case .enqueued: break
                case .dropped, .terminated:
                    continuation.finish(throwing: MCPError.invalidRequest("Input capacity exceeded"))
                    return
                @unknown default: return
                }
                pending.removeAll(keepingCapacity: true)
                start = index + 1
            }
            let remaining = buffer[start..<count]
            guard pending.count <= MCPBounds.inputBytes - remaining.count else {
                continuation.finish(throwing: MCPError.invalidRequest("Frame too large"))
                return
            }
            pending.append(contentsOf: remaining)
        }
        continuation.finish()
    }

    private func writeFrames() async {
        while connected && !Task.isCancelled && !writes.isEmpty {
            let item = writes.removeFirst()
            do {
                var offset = 0
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while offset < item.bytes.count {
                    try Task.checkCancellation()
                    guard connected, ContinuousClock.now < deadline else { throw MCPError.connectionClosed }
                    let count = item.bytes.withUnsafeBytes { bytes in
                        Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    }
                    if count > 0 { offset += count }
                    else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                        try await Task.sleep(for: .milliseconds(5))
                    } else { throw MCPError.connectionClosed }
                }
                item.completion.resume()
            } catch {
                item.completion.resume(throwing: MCPError.connectionClosed)
                connected = false
                continuation.finish(throwing: MCPError.connectionClosed)
            }
        }
        let pending = writes
        writes.removeAll()
        for item in pending { item.completion.resume(throwing: MCPError.connectionClosed) }
        writer = nil
    }
}
