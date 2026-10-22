#if DEBUG
import AgentClient
import AgentValues
import CryptoKit
import Darwin
import Foundation

/// Finite nonshipping process-control values. This channel is never an MCP capability.
struct FixtureControlMessage: Codable, Sendable {
    let version: Int
    let id: UUID
    let kind: String
    var namespace: String? = nil
    var runID: UUID? = nil
    var capability: Data? = nil
    var resume: Bool? = nil
    var recoveryOnly: Bool? = nil
    var epoch: UUID? = nil
    var wallet: WalletScope? = nil
    var expectedRevision: UInt64? = nil
    var approvalRequired: Bool? = nil
    var status: OwnerWalletStatus? = nil
    var policy: ApprovalPolicyProjection? = nil
    var challenge: NativeConsentChallenge? = nil
    var allow: Bool? = nil
    var snapshot: FixtureProcessSnapshot? = nil
    var problem: String? = nil
    var phase: String? = nil
    var seconds: UInt64? = nil
    var wallTime: Int64? = nil
    var operation: OperationSelector? = nil
    var requestKey: RequestKey? = nil
    var relayContext: ExactRelayReviewContext? = nil
    var relayReceipt: FixtureRelayReceipt? = nil
    var grant: GrantProjection? = nil
    var receive: ReceiveOperation? = nil
    var facts: FixtureDurableFacts? = nil
    var page: PageRequest? = nil
    var accounts: OwnerAccountDirectory? = nil
    var payments: OwnerPaymentPage? = nil
    var previewContext: ExactPreviewReviewContext? = nil
    var payment: PaymentOperation? = nil
    var revocation: FixtureGrantRevocation? = nil
    var grantSelector: GrantSelector? = nil
    var preparation: PreparePaymentRequest? = nil
    var lookup: OperationLookup? = nil
    var connection: String? = nil
    var controller: Bool? = nil
    init(id: UUID = UUID(), kind: String) { version = 1; self.id = id; self.kind = kind }
}
struct FixtureGrantRevocation: Codable, Sendable {
    let grant: GrantProjection
    let admittedOperations: [OperationSelector]
    init(_ value: GrantRevocationProjection) {
        grant = value.grant; admittedOperations = value.admittedOperations
    }
}
/// Closed test-only projection of the existing non-Codable owner receipt.
struct FixtureRelayReceipt: Codable, Sendable, Equatable {
    let wallet: WalletScope
    let requestKey: RequestKey
    let context: ExactRelayReviewContext
    let attempt: RelayAttemptProjection?
    let outcome: OwnerRelayOutcome
    let terminalReason: ServiceProblemCode?
    let payment: PaymentOperation
    init(_ value: OwnerRelayReceipt) {
        wallet = value.wallet; requestKey = value.requestKey; context = value.context
        attempt = value.attempt; outcome = value.outcome; terminalReason = value.terminalReason; payment = value.payment
    }
}
struct FixtureDurableFacts: Codable, Sendable {
    let generation: UInt64
    let mode: String
    let allGrantsRevoked: Bool
    let allApprovalsInactive: Bool
    let credentialGeneration: UInt64?
    let receiveRequests: Int
    let issuedIndices: [UInt64]
    let ownerReceipts: Int
    let blocker: String?
    let keyReads: Int
    let chainQueries: Int
    let clockWall: Int64
    let clockMonotonic: UInt64
}
struct FixtureProcessSnapshot: Codable, Sendable {
    let account: AccountScope
    let paymentID: String?
    let requestKey: String?
    let state: String?
    let ordinaryAdmissions: UInt64
    let totalAdmissions: Int
    let gateHeld: Bool
    let byteDigest: String?
    let stateDigest: String
    let relayEntries: Int
    let policyRevision: UInt64
}

/// A frame is a big-endian UInt32 length, one kind byte, then payload. Only kind 1 is
/// JSON; kinds 2/3 are correlated in-memory credential/canonical-byte slots, never traces.
final class FixtureControlSocket: @unchecked Sendable {
    static let maximumBytes = 65_536
    let descriptor: Int32
    private let writing = NSLock()
    private let lifecycle = NSLock()
    private var closed = false
    init(descriptor: Int32) throws {
        guard descriptor >= 3 else { throw FixtureFailure.invalidArguments }
        var type: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &size) == 0, type == SOCK_STREAM else {
            throw FixtureFailure.invalidArguments
        }
        self.descriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw FixtureFailure.invalidArguments }
        var yes: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    func send(_ message: FixtureControlMessage) throws { try send(kind: 1, payload: JSONEncoder().encode(message)) }
    func send(_ message: FixtureControlMessage, sensitive: Data?) throws {
        let payload = try JSONEncoder().encode(message)
        guard payload.count < Self.maximumBytes, sensitive.map({ $0.count == 32 }) ?? true else { throw FixtureFailure.invalidArguments }
        try writing.withLock {
            try writeFrame(kind: 1, payload: payload)
            if let sensitive { try writeFrame(kind: 2, payload: sensitive) }
        }
    }
    func send(kind: UInt8, payload: Data) throws {
        guard [1, 2, 3].contains(kind), payload.count < Self.maximumBytes else { throw FixtureFailure.invalidArguments }
        try writing.withLock { try writeFrame(kind: kind, payload: payload) }
    }
    private func writeFrame(kind: UInt8, payload: Data) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        var length = UInt32(payload.count + 1).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(kind); frame.append(payload)
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try wait(events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw FixtureFailure.fixtureUnavailable }
                offset += count
            }
        }
    }
    func receive() throws -> (UInt8, Data) {
        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        let header = try readExactly(4, deadline: deadline)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length >= 1, length <= Self.maximumBytes else { throw FixtureFailure.invalidArguments }
        let frame = try readExactly(Int(length), deadline: deadline)
        guard let kind = frame.first, [1, 2, 3].contains(kind) else { throw FixtureFailure.invalidArguments }
        return (kind, Data(frame.dropFirst()))
    }
    static func message(_ frame: (UInt8, Data)) throws -> FixtureControlMessage {
        guard frame.0 == 1 else { throw FixtureFailure.invalidArguments }
        let value = try JSONDecoder().decode(FixtureControlMessage.self, from: frame.1)
        let allowed: Set<String> = ["version", "id", "kind", "namespace", "runID", "capability", "resume", "recoveryOnly", "epoch", "wallet", "expectedRevision", "approvalRequired", "status", "policy", "challenge", "allow", "snapshot", "problem", "phase", "seconds", "wallTime", "operation", "requestKey", "relayContext", "relayReceipt", "grant", "receive", "facts", "page", "accounts", "payments", "previewContext", "payment", "revocation", "grantSelector", "preparation", "lookup", "connection", "controller"]
        guard value.version == 1,
              let object = try JSONSerialization.jsonObject(with: frame.1) as? [String: Any],
              Set(object.keys).isSubset(of: allowed) else { throw FixtureFailure.invalidArguments }
        return value
    }
    private func wait(events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw FixtureFailure.fixtureUnavailable }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let remaining = Int32(max(1, (deadline - now) / 1_000_000))
            let ready = poll(&item, 1, remaining)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw FixtureFailure.fixtureUnavailable }; return
        }
    }
    private func readExactly(_ count: Int, deadline: UInt64) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                try wait(events: Int16(POLLIN), deadline: deadline)
                let received = Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard received > 0 else { throw FixtureFailure.fixtureUnavailable }
                offset += received
            }
        }
        return data
    }
    func close() {
        lifecycle.withLock {
            guard !closed else { return }; closed = true
            _ = Darwin.shutdown(descriptor, SHUT_RDWR); _ = Darwin.close(descriptor)
        }
    }
    deinit { close() }
}

struct FixtureFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let mode: UInt16
    static func capture(_ path: String, directory: Bool) throws -> Self {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        defer { Darwin.close(fd) }
        return try capture(descriptor: fd, directory: directory)
    }
    static func capture(at directoryFD: Int32, name: String, directory: Bool) throws -> Self {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        defer { Darwin.close(fd) }
        return try capture(descriptor: fd, directory: directory)
    }
    static func capture(descriptor fd: Int32, directory: Bool) throws -> Self {
        var value = stat()
        guard fstat(fd, &value) == 0,
              value.st_uid == getuid(),
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              value.st_mode & 0o077 == 0 else { throw FixtureFailure.invalidArguments }
        return .init(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), owner: value.st_uid, mode: UInt16(value.st_mode))
    }
}
struct FixtureNamespaceManifest: Codable, Sendable {
    let version: Int
    let runID: UUID
    let capabilityHash: Data
    let directory: FixtureFileIdentity
}
struct FixtureStoreManifest: Codable, Sendable {
    let version: Int
    let runID: UUID
    let directory: FixtureFileIdentity
    let files: [String: FixtureFileIdentity]
    let syntheticItems: FixtureFileIdentity
    let grantID: String
    let walletID: String
    let installationID: String
    let accountID: String
    let profile: String
}

/// Parent-created namespace and capability. An existing/adopted root cannot become owned
/// merely by supplying a path. This protects disposable tests, not against a hostile same-user process.
final class FixtureProcessOwnership: @unchecked Sendable {
    let namespace: URL
    let runID: UUID
    let capability: Data
    let directory: URL
    private let identity: FixtureFileIdentity
    private let namespaceFD: Int32
    private var stateFD: Int32?
    private init(namespace: URL, runID: UUID, capability: Data, identity: FixtureFileIdentity) throws {
        let fd = Darwin.open(namespace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        guard try FixtureFileIdentity.capture(descriptor: fd, directory: true) == identity else {
            Darwin.close(fd); throw FixtureFailure.invalidArguments
        }
        self.namespace = namespace; self.runID = runID; self.capability = capability
        self.directory = namespace.appendingPathComponent("state", isDirectory: true); self.identity = identity
        self.namespaceFD = fd
    }
    static func create(namespace: URL) throws -> FixtureProcessOwnership {
        try requireTemporaryParent(namespace)
        guard mkdir(namespace.path, 0o700) == 0 else { throw FixtureFailure.invalidArguments }
        let identity = try FixtureFileIdentity.capture(namespace.path, directory: true)
        let capability = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let runID = UUID()
        let manifest = FixtureNamespaceManifest(version: 1, runID: runID,
            capabilityHash: Data(SHA256.hash(data: capability)), directory: identity)
        try writeNew(JSONEncoder().encode(manifest), to: namespace.appendingPathComponent("owner.json"))
        return try FixtureProcessOwnership(namespace: namespace, runID: runID, capability: capability, identity: identity)
    }
    static func attach(_ message: FixtureControlMessage) throws -> FixtureProcessOwnership {
        guard message.kind == "bootstrap", let path = message.namespace, path.utf8.count <= 4096,
              let runID = message.runID, let capability = message.capability, capability.count == 32,
              message.epoch != nil, message.resume != nil else { throw FixtureFailure.invalidArguments }
        let namespace = URL(fileURLWithPath: path, isDirectory: true)
        try requireTemporaryParent(namespace)
        let identity = try FixtureFileIdentity.capture(namespace.path, directory: true)
        let fd = Darwin.open(namespace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        defer { Darwin.close(fd) }
        guard try FixtureFileIdentity.capture(descriptor: fd, directory: true) == identity else { throw FixtureFailure.invalidArguments }
        let bytes = try readAt(fd, name: "owner.json", maximum: 4096)
        let manifest = try JSONDecoder().decode(FixtureNamespaceManifest.self, from: bytes)
        guard manifest.version == 1, manifest.runID == runID, manifest.directory == identity,
              manifest.capabilityHash == Data(SHA256.hash(data: capability)) else { throw FixtureFailure.invalidArguments }
        return try FixtureProcessOwnership(namespace: namespace, runID: runID, capability: capability, identity: identity)
    }
    func prepare(resume: Bool) throws {
        guard try FixtureFileIdentity.capture(namespace.path, directory: true) == identity else { throw FixtureFailure.invalidArguments }
        let entries = try Self.names(namespaceFD)
        if !resume {
            // Actual initializeNew owns absent-directory creation. The capability only owns its parent.
            guard entries == ["owner.json"] else { throw FixtureFailure.invalidArguments }
            return
        }
        guard entries == ["owner.json", "state", "store.json", "relay-oracle.jsonl", "synthetic-keychain.json"] else { throw FixtureFailure.invalidArguments }
        let manifest = try storeManifest()
        let fd = openat(namespaceFD, "state", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        stateFD = fd
        guard manifest.version == 1, manifest.runID == runID,
              manifest.directory == (try FixtureFileIdentity.capture(descriptor: fd, directory: true)),
              UUID(uuidString: manifest.walletID) != nil, UUID(uuidString: manifest.installationID) != nil,
              !manifest.grantID.isEmpty, manifest.profile == "bip39-empty/bip44-145-0/v1",
              Set(manifest.files.keys) == ["journal.sqlite", "custody.scope", "writer.lock"] else {
            throw FixtureFailure.invalidArguments
        }
        let actual = try Self.names(fd)
        guard actual.isSubset(of: Set(manifest.files.keys).union(["journal.sqlite-journal"])) else { throw FixtureFailure.invalidArguments }
        for (name, expected) in manifest.files {
            guard try FixtureFileIdentity.capture(at: fd, name: name, directory: false) == expected else { throw FixtureFailure.invalidArguments }
        }
        // Synthetic custody persists by atomic replacement. Independent item content and scope
        // are checked by the injected Security adapter and actual service startup, never an old inode.
        let items = try FixtureFileIdentity.capture(at: namespaceFD, name: "synthetic-keychain.json", directory: false)
        guard items.device == manifest.syntheticItems.device, items.owner == manifest.syntheticItems.owner,
              items.mode == manifest.syntheticItems.mode else { throw FixtureFailure.invalidArguments }
        if actual.contains("journal.sqlite-journal") { _ = try FixtureFileIdentity.capture(at: fd, name: "journal.sqlite-journal", directory: false) }
        guard try FixtureFileIdentity.capture(descriptor: fd, directory: true) == FixtureFileIdentity.capture(directory.path, directory: true) else { throw FixtureFailure.invalidArguments }
    }
    func storeManifest() throws -> FixtureStoreManifest {
        try JSONDecoder().decode(FixtureStoreManifest.self, from: Self.readAt(namespaceFD, name: "store.json", maximum: 8192))
    }
    func seal(walletID: String, installationID: String, accountID: String, profile: String,
              grantID: String = "protocol-fixture-grant") throws {
        let names = ["journal.sqlite", "custody.scope", "writer.lock"]
        if stateFD == nil {
            let fd = openat(namespaceFD, "state", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FixtureFailure.invalidArguments }; stateFD = fd
        }
        guard let stateFD,
              try FixtureFileIdentity.capture(descriptor: stateFD, directory: true) == FixtureFileIdentity.capture(directory.path, directory: true) else { throw FixtureFailure.invalidArguments }
        let files = try Dictionary(uniqueKeysWithValues: names.map { ($0, try FixtureFileIdentity.capture(at: stateFD, name: $0, directory: false)) })
        let manifest = FixtureStoreManifest(version: 1, runID: runID,
            directory: try FixtureFileIdentity.capture(descriptor: stateFD, directory: true), files: files,
            syntheticItems: try FixtureFileIdentity.capture(at: namespaceFD, name: "synthetic-keychain.json", directory: false),
            grantID: grantID, walletID: walletID, installationID: installationID, accountID: accountID, profile: profile)
        guard try !Self.names(namespaceFD).contains("store.json") else { throw FixtureFailure.invalidArguments }
        try writeRootNew(JSONEncoder().encode(manifest), name: "store.json")
    }
    func readRoot(_ name: String, maximum: Int) throws -> Data { try Self.readAt(namespaceFD, name: name, maximum: maximum) }
    func openRoot(_ name: String, flags: Int32) throws -> Int32 {
        guard ["relay-oracle.jsonl"].contains(name) else { throw FixtureFailure.invalidArguments }
        let fd = openat(namespaceFD, name, flags | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        do { _ = try FixtureFileIdentity.capture(descriptor: fd, directory: false); return fd }
        catch { Darwin.close(fd); throw error }
    }
    func writeRootNew(_ data: Data, name: String) throws {
        guard ["store.json", "relay-oracle.jsonl"].contains(name) else { throw FixtureFailure.invalidArguments }
        let fd = openat(namespaceFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize()
    }
    private static func readAt(_ directoryFD: Int32, name: String, maximum: Int) throws -> Data {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        _ = try FixtureFileIdentity.capture(descriptor: fd, directory: false)
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw FixtureFailure.invalidArguments }; return data
    }
    private static func names(_ directoryFD: Int32) throws -> Set<String> {
        let copy = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw FixtureFailure.invalidArguments }
        defer { closedir(stream) }
        var result = Set<String>()
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.insert(name) }
        }
        return result
    }
    static func readOwned(_ path: URL, maximum: Int) throws -> Data {
        _ = try FixtureFileIdentity.capture(path.path, directory: false)
        let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw FixtureFailure.invalidArguments }; return data
    }
    static func writeNew(_ data: Data, to path: URL) throws {
        let fd = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FixtureFailure.invalidArguments }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize()
    }
    private static func requireTemporaryParent(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw FixtureFailure.invalidArguments }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let roots = [URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path,
                     FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path]
        guard roots.contains(where: { parent == $0 || parent.hasPrefix($0 + "/") }),
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw FixtureFailure.invalidArguments }
    }
    deinit { if let stateFD { Darwin.close(stateFD) }; Darwin.close(namespaceFD) }
}
#endif
