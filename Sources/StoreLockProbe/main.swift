import Foundation
import AgentServiceCore

// Development fixture only; excluded from the proposed installed artifact inventory.
let arguments = CommandLine.arguments
guard arguments.count == 3, let milliseconds = UInt32(arguments[2]), milliseconds <= 60_000 else {
    FileHandle.standardError.write(Data("usage: StoreLockProbe lock-file hold-milliseconds\n".utf8))
    exit(64)
}
do {
    let lease = try StoreLock(path: arguments[1])
    withExtendedLifetime(lease) {
        FileHandle.standardOutput.write(Data("locked\n".utf8))
        usleep(milliseconds * 1_000)
    }
} catch StoreLockFailure.busy {
    exit(73)
} catch {
    FileHandle.standardError.write(Data("lock unavailable\n".utf8))
    exit(74)
}
