import Darwin
import Foundation
import OpalDiagnostics
import Testing
@testable import AgentMCP

private struct TestPipes {
    let inputRead: Int32
    let inputWrite: Int32
    let outputRead: Int32
    let outputWrite: Int32
    init() throws {
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0 else { throw PipeFailure.failed }
        inputRead = input[0]; inputWrite = input[1]; outputRead = output[0]; outputWrite = output[1]
    }
    func closeAll() { for fd in [inputRead, inputWrite, outputRead, outputWrite] { _ = Darwin.close(fd) } }
}
private enum PipeFailure: Error { case failed }

private actor BrokenOutputResults {
    private var sent: Bool?
    private var received: Bool?
    func finishSend(_ connectionClosed: Bool) { sent = connectionClosed }
    func finishReceive(_ connectionClosed: Bool) { received = connectionClosed }
    func waitForCompletion() async throws -> (sent: Bool, received: Bool) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            if let sent, let received { return (sent, received) }
            guard ContinuousClock.now < deadline else { throw PipeFailure.failed }
            await Task.yield()
        }
    }
}

@Test func boundedStdioBrokenOutputFailsSendAndReceiveWithInputOpen() async throws {
    let configuration = OpalDiagnostics.Configuration(
        subsystem: "com.58opals.agent.tests", categoryFilter: .enabled(["agent.mcp"]),
        bufferPolicy: .enabled(capacity: 4), routingPolicy: .disabled)
    try await OpalDiagnostics.withConfiguration(configuration) {
        let pipes = try TestPipes()
        var ownsOutputRead = true
        defer {
            if ownsOutputRead { _ = Darwin.close(pipes.outputRead) }
            for fd in [pipes.inputRead, pipes.inputWrite, pipes.outputWrite] { _ = Darwin.close(fd) }
        }
        let transport = BoundedStdioTransport(inputDescriptor: pipes.inputRead, outputDescriptor: pipes.outputWrite)
        try await transport.connect()
        var sender: Task<Void, Never>?
        var receiver: Task<Void, Never>?
        do {
            ownsOutputRead = false
            try #require(Darwin.close(pipes.outputRead) == 0)
            // This independent raw probe observes EPIPE; the transport/child public error does not expose errno.
            var probe: UInt8 = 0
            let written = withUnsafeBytes(of: &probe) { Darwin.write(pipes.outputWrite, $0.baseAddress, $0.count) }
            let observedErrno = errno
            #expect(written == -1 && observedErrno == EPIPE)
            #expect(fcntl(pipes.inputWrite, F_GETFD) >= 0)
            let results = BrokenOutputResults()
            receiver = Task {
                do {
                    for try await _ in await transport.receive() {}
                    await results.finishReceive(false)
                } catch MCPTransportError.connectionClosed { await results.finishReceive(true) }
                catch { await results.finishReceive(false) }
            }
            sender = Task {
                do {
                    try await transport.send(Data("{\"id\":1}".utf8))
                    await results.finishSend(false)
                } catch MCPTransportError.connectionClosed { await results.finishSend(true) }
                catch { await results.finishSend(false) }
            }
            let completed = try await results.waitForCompletion()
            #expect(completed.sent && completed.received)
            #expect(fcntl(pipes.inputWrite, F_GETFD) >= 0)
            let records = OpalDiagnostics.recentRecords
            #expect(records.count == 1)
            #expect(records.first?.event.rawValue == "transport_failed")
            #expect(records.first?.fields == [.publicField("reason", value: "write")])
            await #expect(throws: MCPTransportError.self) { try await transport.send(Data("{\"id\":2}".utf8)) }
            #expect(OpalDiagnostics.configuration == configuration)
        } catch {
            await transport.disconnect()
            await sender?.value; await receiver?.value
            throw error
        }
        // Neither disconnect nor cancellation can supply the terminal observations above.
        await transport.disconnect()
        await sender?.value; await receiver?.value
    }
}

@Test func boundedStdioClosesOversizeUnterminatedInputBeforeProtocolAccumulation() async throws {
    let pipes = try TestPipes(); defer { pipes.closeAll() }
    let transport = BoundedStdioTransport(inputDescriptor: pipes.inputRead, outputDescriptor: pipes.outputWrite)
    try await transport.connect()
    let reader = Task {
        do { for try await _ in await transport.receive() {} ; return false }
        catch { return true }
    }
    let writer = Task.detached {
        var bytes = [UInt8](repeating: 120, count: 4096)
        var total = 0
        while total <= MCPBounds.inputBytes {
            let count = bytes.withUnsafeMutableBytes { Darwin.write(pipes.inputWrite, $0.baseAddress, $0.count) }
            if count > 0 { total += count }
            else { throw PipeFailure.failed }
        }
    }
    try await writer.value
    #expect(await reader.value)
    await transport.disconnect()
}
@Test func boundedStdioRejectsPartialEOFAndFinishesEmptyEOF() async throws {
    for partial in [false, true] {
        let pipes = try TestPipes()
        let transport = BoundedStdioTransport(inputDescriptor: pipes.inputRead, outputDescriptor: pipes.outputWrite)
        try await transport.connect()
        if partial { _ = "{".withCString { Darwin.write(pipes.inputWrite, $0, 1) } }
        _ = Darwin.close(pipes.inputWrite)
        var failed = false
        do { for try await _ in await transport.receive() {} } catch { failed = true }
        #expect(failed == partial)
        await transport.disconnect()
        for fd in [pipes.inputRead, pipes.outputRead, pipes.outputWrite] { _ = Darwin.close(fd) }
    }
}
@Test func boundedStdioSerializesConcurrentOutputAndRejectsOversize() async throws {
    let configuration = OpalDiagnostics.Configuration(
        subsystem: "com.58opals.agent.tests", categoryFilter: .enabled(["agent.mcp"]),
        bufferPolicy: .enabled(capacity: 4), routingPolicy: .disabled)
    try await OpalDiagnostics.withConfiguration(configuration) {
        let pipes = try TestPipes(); defer { pipes.closeAll() }
        let transport = BoundedStdioTransport(inputDescriptor: pipes.inputRead, outputDescriptor: pipes.outputWrite)
        try await transport.connect()
        await #expect(throws: (any Error).self) { try await transport.send(Data(repeating: 1, count: MCPBounds.outputBytes + 1)) }
        async let first: Void = transport.send(Data("{\"id\":1}".utf8))
        async let second: Void = transport.send(Data("{\"id\":2}".utf8))
        try await first; try await second
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(pipes.outputRead, $0.baseAddress, $0.count) }
        let lines = String(decoding: buffer.prefix(count), as: UTF8.self).split(separator: "\n")
        #expect(Set(lines) == ["{\"id\":1}", "{\"id\":2}"])
        await transport.disconnect()
        let records = OpalDiagnostics.recentRecords
        #expect(records.count == 1)
        #expect(records.first?.event.rawValue == "transport_failed")
        #expect(records.first?.fields == [.publicField("reason", value: "send")])
        #expect(OpalDiagnostics.configuration == configuration)
    }
}
