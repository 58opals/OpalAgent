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

@Test func boundedStdioClosesOversizeUnterminatedInputBeforeSDKAccumulation() async throws {
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
