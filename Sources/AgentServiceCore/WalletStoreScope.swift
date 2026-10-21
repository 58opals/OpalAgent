import Darwin
import Foundation

/// Nonsecret location metadata, never authentication or an alternative continuity anchor.
/// The service selects and retains the directory; clients cannot select a scope or path.
struct WalletStoreScope: Equatable, Sendable {
    let installationID: UUID
    let walletID: UUID
    private static let header = "opal-agent-custody-scope-v1"
    private static let filename = "custody.scope"

    static func requireDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw SQLiteJournalError.invalidPath }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw DurableWalletStoreError.scopeUnavailable
        }
    }

    func writeNew(in directory: URL) throws {
        let path = directory.appendingPathComponent(Self.filename).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                              S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DurableWalletStoreError.scopeUnavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        // An interrupted prefix is retained. Neither fresh initialization nor reopen repairs it.
        try file.write(contentsOf: encoded)
        try file.synchronize()
    }

    static func read(in directory: URL) throws -> Self {
        let path = directory.appendingPathComponent(filename).path
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DurableWalletStoreError.scopeUnavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 256,
              let bytes = try file.read(upToCount: 257), bytes.count <= 256,
              let text = String(data: bytes, encoding: .utf8) else {
            throw DurableWalletStoreError.invalidScope
        }
        let fields = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == header, fields[3].isEmpty,
              let installation = UUID(uuidString: String(fields[1])),
              let wallet = UUID(uuidString: String(fields[2])) else {
            throw DurableWalletStoreError.invalidScope
        }
        let result = Self(installationID: installation, walletID: wallet)
        guard result.encoded == bytes else { throw DurableWalletStoreError.invalidScope }
        return result
    }

    private var encoded: Data {
        Data("\(Self.header)\n\(installationID.uuidString)\n\(walletID.uuidString)\n".utf8)
    }
}
