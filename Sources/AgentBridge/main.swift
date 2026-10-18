import AgentClient
import AgentMCP
import Foundation

// Ordinary construction has no qualified native/custody provider. Tools return unavailable.
// This entry never installs a service, opens custody or selects a synthetic runtime.
let server = MCPToolServer(client: CapabilityClient())
do {
    try await server.start(transport: BoundedStdioTransport())
    await server.waitUntilCompleted()
} catch {
    FileHandle.standardError.write(Data("unavailable: MCP transport closed\n".utf8))
    await server.stop()
    exit(69)
}
