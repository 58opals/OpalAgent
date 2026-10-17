import Foundation
import AgentValues
import AgentServiceCore

// Production persistence, protected storage and authenticated IPC are deliberately absent.
FileHandle.standardError.write(Data("unavailable: production service adapters are absent\n".utf8))
exit(69)
