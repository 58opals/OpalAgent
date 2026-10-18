import AgentValues
import Foundation
import Testing
@testable import AgentProtocolFixture

@Test(arguments: ["/private/tmp", FileManager.default.temporaryDirectory.path])
func syntheticFixtureAcceptsLiteralCLIFileURLsWithoutDirectoryHint(_ parent: String) async throws {
    let path = parent + "/opal-agent-cli-path-" + UUID().uuidString
    // These are exactly the CLI parser's constructors, evaluated before the directory exists.
    let directory = URL(fileURLWithPath: path)
    let trace = URL(fileURLWithPath: path + "/trace.jsonl")
    #expect(!directory.hasDirectoryPath)
    let runtime = try await FixtureRuntime.make(directory: directory, scenario: .uncertain, tracePath: trace)
    do {
        #expect(FileManager.default.fileExists(atPath: trace.path))
        guard case .listWallets(let wallets) = try await runtime.client.call(.listWallets(try PageRequest())) else {
            throw WireFixtureFailure.invalidReply
        }
        #expect(wallets.items.count == 1 && runtime.chain.counts.relays == 0)
        await runtime.shutdown()
        let rows = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 3)
        try FileManager.default.removeItem(at: directory)
    } catch {
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
