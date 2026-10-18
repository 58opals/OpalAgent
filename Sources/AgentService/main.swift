import Foundation
import AgentValues
import AgentServiceCore

// Qualified native host assembly and protected custody providers are unavailable.
FileHandle.standardError.write(Data("unavailable: qualified service assembly is absent\n".utf8))
exit(69)
