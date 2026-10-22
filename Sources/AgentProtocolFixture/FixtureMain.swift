import Darwin
import Foundation
#if DEBUG
import AgentMCP

@main enum AgentProtocolFixture {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.count == 2, arguments[0] == "--test-control-fd", let fd = Int32(arguments[1]), fd == 3 {
                let socket = try FixtureControlSocket(descriptor: fd)
                let session = try await FixtureProcessSession.make(socket: socket)
                try await session.run()
                return
            }
            let options = try parse(arguments)
            let runtime = try await FixtureRuntime.make(directory: options.directory, scenario: options.scenario,
                tracePath: options.trace)
            let server = MCPToolServer(client: runtime.client)
            let transport = FixtureStdioLifetime(ended: { await runtime.shutdown() }, outputSendFailed: {
                try? runtime.trace?.emit(event: "stdio-output-send-failed", relayCount: runtime.chain.counts.relays)
            })
            do {
                try await server.start(transport: transport)
                await server.waitUntilCompleted()
                // SDK receive completion does not join every response-send task.
                await transport.disconnect()
                await runtime.shutdown()
            } catch {
                let drain = await runtime.beginShutdown()
                await runtime.releaseFixtureFaults()
                await drain.value
                await server.stop()
                await transport.disconnect()
                throw error
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Synthetic protocol fixture unavailable.\n".utf8))
            exit(69)
        }
    }
    private static func parse(_ arguments: [String]) throws -> (directory: URL, scenario: FixtureScenario, trace: URL?) {
        guard arguments.count == 4 || arguments.count == 6 else { throw FixtureFailure.invalidArguments }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard ["--state-directory", "--scenario", "--trace-file"].contains(arguments[index]),
                  values[arguments[index]] == nil, arguments[index + 1].utf8.count <= 4096 else { throw FixtureFailure.invalidArguments }
            values[arguments[index]] = arguments[index + 1]
        }
        guard let path = values["--state-directory"], path.hasPrefix("/"),
              let name = values["--scenario"], let scenario = FixtureScenario(rawValue: name),
              values["--trace-file"].map({ $0.hasPrefix("/") }) ?? true else { throw FixtureFailure.invalidArguments }
        return (URL(fileURLWithPath: path), scenario, values["--trace-file"].map { URL(fileURLWithPath: $0) })
    }
}
#else
/// Release builds cannot assemble synthetic custody or a service through this development product.
@main enum AgentProtocolFixture {
    static func main() {
        try? FileHandle.standardError.write(contentsOf: Data("Synthetic protocol fixture unavailable.\n".utf8))
        exit(69)
    }
}
#endif
