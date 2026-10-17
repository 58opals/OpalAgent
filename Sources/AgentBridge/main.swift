import Foundation
import AgentClient

// Never write diagnostics or an invented MCP response to stdout.
FileHandle.standardError.write(Data("unavailable: authenticated service transport is absent\n".utf8))
exit(69)
