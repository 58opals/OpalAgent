import CryptoKit
import Darwin
import Foundation
import MCP

enum AcceptanceFailure: Error, CustomStringConvertible {
    case rejected(String)
    var description: String { switch self { case .rejected(let reason): reason } }
}

/// This binding selects a previously reviewed executable; it supplies no source or signing authority.
struct FixtureExecutable: Sendable {
    let url: URL
    let sha256: String

    static func required(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard let path = environment["OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE"],
              let digest = environment["OPAL_AGENT_PROTOCOL_FIXTURE_SHA256"],
              path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AcceptanceFailure.rejected("Both exact fixture executable and lowercase SHA-256 bindings are required")
        }
        let value = Self(url: URL(fileURLWithPath: path), sha256: digest)
        try value.verify()
        return value
    }

    func verify() throws {
        guard url.lastPathComponent == "AgentProtocolFixture",
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            throw AcceptanceFailure.rejected("Fixture binding must name AgentProtocolFixture without symlinks")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AcceptanceFailure.rejected("Bound fixture could not be opened") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var facts = stat()
        guard fstat(descriptor, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
              facts.st_uid == getuid(), facts.st_mode & 0o100 != 0,
              facts.st_mode & 0o022 == 0, facts.st_size > 0, facts.st_size <= 512 * 1024 * 1024 else {
            throw AcceptanceFailure.rejected("Bound fixture is not an owned, protected regular executable")
        }
        var hash = SHA256()
        var count = 0
        while let bytes = try file.read(upToCount: 512 * 1024), !bytes.isEmpty {
            count += bytes.count
            guard count <= facts.st_size else { throw AcceptanceFailure.rejected("Fixture bytes changed while hashing") }
            hash.update(data: bytes)
        }
        let observed = hash.finalize().map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
        var current = stat()
        guard count == facts.st_size, observed == sha256,
              lstat(url.path, &current) == 0, current.st_dev == facts.st_dev,
              current.st_ino == facts.st_ino, current.st_size == facts.st_size,
              current.st_mode == facts.st_mode, current.st_uid == facts.st_uid,
              current.st_mtimespec.tv_sec == facts.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == facts.st_mtimespec.tv_nsec else {
            throw AcceptanceFailure.rejected("Fixture SHA-256 or file identity differs from the binding")
        }
    }
}

/// Process plumbing only: all MCP encoding, framing and client state belong to the official SDK.
/// Locks protect the cross-queue stop/failure observations; relay buffers are queue-local and bounded.
final class OwnedFixture: @unchecked Sendable {
    let process = Process()
    let sdkTransport: MCP.StdioTransport
    let directory: URL
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let sdkInput = Pipe()
    private let lock = NSLock()
    private let relayGroup = DispatchGroup()
    private var stopped = false
    private var inputClosed = false
    private var expectingExit = false
    private var failure: String?
    private var stderrBytes = Data()

    init(binding: FixtureExecutable) throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("opal-mcp-interop-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        sdkTransport = MCP.StdioTransport(
            input: .init(rawValue: sdkInput.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: stdin.fileHandleForWriting.fileDescriptor)
        )
        process.executableURL = binding.url
        process.arguments = ["--state-directory", directory.appendingPathComponent("fixture").path,
                             "--scenario", "autonomous"]
        process.currentDirectoryURL = directory
        // Disposable fixture boundaries establish that the selected child has no live provider.
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            for handle in [stdout.fileHandleForReading, stderr.fileHandleForReading,
                           sdkInput.fileHandleForWriting] {
                let fd = handle.fileDescriptor
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw AcceptanceFailure.rejected("Could not configure bounded pipe observation")
                }
            }
            for handle in [stdin.fileHandleForWriting, sdkInput.fileHandleForWriting] {
                guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                    throw AcceptanceFailure.rejected("Could not suppress SIGPIPE on an owned pipe")
                }
            }
            try binding.verify() // Rebind the actual path immediately before this one launch.
            try process.run()
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            startRelay(source: stdout.fileHandleForReading, destination: sdkInput.fileHandleForWriting,
                       maximumBytes: 8 * 1024 * 1024, maximumFrame: 262_144)
            startRelay(source: stderr.fileHandleForReading, destination: nil,
                       maximumBytes: 64 * 1024, maximumFrame: nil)
        } catch {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            closeHandles()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    var problem: String? { lock.withLock { failure } }
    var exitIsExpected: Bool { lock.withLock { expectingExit } }
    private func failed(_ reason: String) { lock.withLock { if failure == nil { failure = reason } } }

    func watchdog(client: MCP.Client) -> Task<Void, Never> {
        Task {
            let deadline = ContinuousClock.now + .seconds(60)
            while !Task.isCancelled {
                if let problem { failed(problem); break }
                if !process.isRunning && !exitIsExpected { failed("Fixture exited before acceptance completed"); break }
                if ContinuousClock.now >= deadline { failed("Independent SDK acceptance exceeded 60 seconds"); break }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await terminateIfNeeded()
            await client.disconnect() // Release SDK pending continuations after a failed child/relay.
        }
    }

    func finishInputAndWait() async throws {
        lock.withLock { expectingExit = true }
        closeInput()
        let deadline = ContinuousClock.now + .seconds(8)
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !process.isRunning else { throw AcceptanceFailure.rejected("Fixture did not exit naturally after stdin EOF") }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw AcceptanceFailure.rejected("Fixture did not exit naturally with status zero")
        }
    }

    func checkOutput() async throws {
        guard await joinRelays() else {
            throw AcceptanceFailure.rejected("Owned output observers did not finish")
        }
        if let problem { throw AcceptanceFailure.rejected(problem) }
        guard lock.withLock({ stderrBytes.isEmpty }) else { throw AcceptanceFailure.rejected("Fixture emitted unexpected stderr") }
    }

    func cleanup() async {
        closeInput()
        await terminateIfNeeded()
        lock.withLock { stopped = true }
        if !(await joinRelays()) { failed("Owned output observers did not stop") }
        closeHandles()
        try? FileManager.default.removeItem(at: directory)
    }

    private func joinRelays() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "opal.mcp.interoperability.join").async { [relayGroup] in
                continuation.resume(returning: relayGroup.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    private func terminateIfNeeded() async {
        guard process.isRunning else { process.waitUntilExit(); return }
        process.terminate()
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit() // Reap only this Process, including failure cleanup.
    }

    private func closeInput() {
        let shouldClose = lock.withLock { if inputClosed { return false }; inputClosed = true; return true }
        if shouldClose { try? stdin.fileHandleForWriting.close() }
    }
    private func closeHandles() {
        for pipe in [stdin, stdout, stderr, sdkInput] {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }

    private func startRelay(source: FileHandle, destination: FileHandle?, maximumBytes: Int, maximumFrame: Int?) {
        relayGroup.enter()
        DispatchQueue(label: "opal.mcp.interoperability.pipe").async { [self] in
            defer { try? destination?.close(); relayGroup.leave() }
            let input = source.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 4096)
            var total = 0, frame = 0
            while !lock.withLock({ stopped }) {
                var event = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&event, 1, 20)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { failed("Owned pipe polling failed"); return }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
                if count == 0 {
                    if maximumFrame != nil && frame != 0 { failed("Fixture stdout ended with an incomplete frame") }
                    return
                }
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0, count <= maximumBytes - total else { failed("Owned output byte limit or read failed"); return }
                total += count
                for byte in buffer.prefix(count) {
                    if byte == 10 { frame = 0 }
                    else { frame += 1 }
                    if let maximumFrame, frame > maximumFrame { failed("Fixture stdout exceeded its frame limit"); return }
                }
                if let destination {
                    var offset = 0
                    while offset < count && !lock.withLock({ stopped }) {
                        let written = buffer.withUnsafeBytes { bytes in
                            Darwin.write(destination.fileDescriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                        }
                        if written > 0 { offset += written }
                        else if written < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) {
                            var writable = pollfd(fd: destination.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                            _ = Darwin.poll(&writable, 1, 20)
                        } else { failed("SDK byte relay write failed"); return }
                    }
                } else {
                    lock.withLock { stderrBytes.append(contentsOf: buffer.prefix(count)) }
                }
            }
        }
    }
}
