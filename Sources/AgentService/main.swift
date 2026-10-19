import OpalDiagnostics
import Foundation
import AgentValues
import AgentServiceCore

OpalDiagnostics.configure(.init(subsystem: "com.58opals.agent", categoryFilter: .enabled(["agent.service", "agent.authorization", "agent.journal", "agent.recovery", "agent.payment"])))

// Qualified native host assembly and protected custody providers are unavailable.
OpalDiagnostics.logger(category: "agent.service").record(event: "assembly_unavailable", traceID: OpalDiagnostics.TraceID())
FileHandle.standardError.write(Data("unavailable: qualified service assembly is absent\n".utf8))
exit(69)
