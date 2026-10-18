import AgentValues
import CSQLite
import Darwin
import Foundation
import Testing
@testable import AgentServiceCore

struct SQLiteJournalTests {
    @Test func normalizedRowsSurviveReopenWithTheSameCompleteCommitment() throws {
        let fixture = try SQLiteFixture()
        defer { fixture.remove() }
        let state = sqliteState()
        do {
            let journal = try SQLiteJournal(path: fixture.database)
            #expect(try journal.read() == nil)
            try journal.write(state)
        }
        let reopened = try SQLiteJournal(path: fixture.database)
        #expect(try reopened.read() == state.canonicalized())
        #expect(try reopened.read()?.reference() == state.reference())
        try withSQL(fixture.database) { (db: OpaquePointer) throws -> Void in
            #expect(try scalar(db, "SELECT count(*) FROM attempts") == 1)
            #expect(try scalar(db, "SELECT count(*) FROM evidence") == 1)
            #expect(try scalar(db, "SELECT count(*) FROM closures") == 1)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.database)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aSymlinkStoreIsRejectedWithoutChangingItsDestination() throws {
        let fixture = try SQLiteFixture()
        defer { fixture.remove() }
        let state = sqliteState()
        let journal = try SQLiteJournal(path: fixture.database)
        try journal.write(state)
        let alias = fixture.directory.appendingPathComponent("alias.sqlite").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.database)
        #expect(throws: (any Error).self) { try SQLiteJournal(path: alias) }
        #expect(try journal.read() == state.canonicalized())
    }

    @Test func omittedActualRowsCannotHideBehindRootMetadata() throws {
        let fixture = try SQLiteFixture()
        defer { fixture.remove() }
        let original = sqliteState()
        let journal = try SQLiteJournal(path: fixture.database)
        try journal.write(original)
        let anchor = try SQLiteTestAnchor(path: fixture.anchor, initial: ContinuityAnchor(committed: original.reference()))
        try withSQL(fixture.database) { try execute($0, "DELETE FROM requests WHERE id = 'request'") }
        #expect(try journal.read()?.reference() != original.reference())
        let coordinator = ContinuityCoordinator(database: journal, anchor: anchor)
        #expect(coordinator.status() == .quarantined)
        #expect(throws: ContinuityError.recoveryRequired) { try coordinator.startup() }
    }

    @Test func duplicateEffectNamespacesAndAttemptNumbersRollBackAtomically() throws {
        let fixture = try SQLiteFixture()
        defer { fixture.remove() }
        let original = sqliteState()
        let journal = try SQLiteJournal(path: fixture.database)
        try journal.write(original)
        var duplicateRequest = original
        var request = original.requests[0]
        request.id = "another-request"
        duplicateRequest.requests.append(request)
        #expect(throws: (any Error).self) { try journal.write(duplicateRequest) }
        #expect(try journal.read() == original.canonicalized())
        var duplicateAttempt = original
        var attempt = original.payments[0].attempts[0]
        attempt.id = "another-attempt"
        duplicateAttempt.payments[0].attempts.append(attempt)
        #expect(throws: (any Error).self) { try journal.write(duplicateAttempt) }
        #expect(try journal.read() == original.canonicalized())
    }

    @Test func typedIdentityCorruptionAndUnknownDatabaseSchemasAreRejected() throws {
        let fixture = try SQLiteFixture()
        defer { fixture.remove() }
        let journal = try SQLiteJournal(path: fixture.database)
        try journal.write(sqliteState())
        try withSQL(fixture.database) { try execute($0, "UPDATE grants SET integration_id = 'other'") }
        #expect(throws: SQLiteJournalError.corruptState) { try journal.read() }
        try withSQL(fixture.database) { try execute($0, "PRAGMA user_version = 999") }
        #expect(throws: SQLiteJournalError.incompatibleSchema) { try journal.read() }
        #expect(throws: SQLiteJournalError.incompatibleSchema) { try SQLiteJournal(path: fixture.database) }
        let foreign = fixture.directory.appendingPathComponent("foreign.sqlite").path
        try withSQL(foreign) { try execute($0, "CREATE TABLE unrelated (id INTEGER)") }
        #expect(throws: SQLiteJournalError.incompatibleSchema) { try SQLiteJournal(path: foreign) }
    }

    @Test func commitBusyRollsBackBeforeReadbackAndNeverAcknowledgesTheTarget() throws {
        let fixture = try SQLiteFixture()
        defer { fixture.remove() }
        let original = sqliteState()
        let commits = SQLiteCommitCounter()
        let journal = try SQLiteJournal(path: fixture.database) { point in commits.observe(point) }
        try journal.write(original)
        let anchor = try SQLiteTestAnchor(path: fixture.anchor, initial: ContinuityAnchor(committed: original.reference()))
        let coordinator = ContinuityCoordinator(database: journal, anchor: anchor)
        try withSQL(fixture.database) { reader in
            try execute(reader, "BEGIN; SELECT payload FROM root")
            defer { try? execute(reader, "ROLLBACK") }
            var proposed = original
            proposed.commitID = "uncommitted"
            #expect(throws: SQLiteJournalError.sqlite(SQLITE_BUSY)) { try journal.write(proposed) }
            #expect(commits.count == 2) // The initial write and this failed COMMIT both reached the boundary.
            #expect(try journal.read() == original.canonicalized())
            var acknowledged = false
            #expect(throws: ContinuityError.recoveryRequired) {
                try coordinator.transaction { $0.allocations[0].issuedHighWater = 2 }
                acknowledged = true
            }
            #expect(!acknowledged)
            #expect(commits.count == 3)
            #expect(try journal.read() == original.canonicalized())
        }
        #expect(try SQLiteJournal(path: fixture.database).read() == original.canonicalized())
        #expect(coordinator.status() == .quarantined)
        #expect(try anchor.read()?.pending != nil)
    }

    @Test(arguments: SQLiteJournalFaultPoint.allCases)
    func ambiguousCommitOutcomeUsesOnlyActualCommittedContents(_ point: SQLiteJournalFaultPoint) throws {
        let fixture = try SQLiteFixture()
        defer { fixture.remove() }
        let original = sqliteState()
        try SQLiteJournal(path: fixture.database).write(original)
        let anchor = try SQLiteTestAnchor(path: fixture.anchor, initial: ContinuityAnchor(committed: original.reference()))
        let journal = try SQLiteJournal(path: fixture.database) { actual in
            if actual == point { throw SQLiteInjectedFailure.stop }
        }
        let coordinator = ContinuityCoordinator(database: journal, anchor: anchor)
        if point == .beforeCommit {
            #expect(throws: ContinuityError.recoveryRequired) {
                try coordinator.transaction { $0.allocations[0].issuedHighWater = 2 }
            }
            #expect(try journal.read() == original.canonicalized())
            #expect(coordinator.status() == .quarantined)
        } else {
            let result = try coordinator.transaction(mutation: { state in
                state.allocations[0].issuedHighWater = 2
                return "committed"
            })
            #expect(result == "committed")
            #expect(try journal.read()?.allocations[0].issuedHighWater == 2)
            #expect(try anchor.read()?.pending == nil)
            #expect(try anchor.read()?.committed == journal.read()?.reference())
        }
    }

    @Test(arguments: SQLiteJournalFaultPoint.allCases)
    func processTerminationAtSQLCommitRequiresRestrictedOwnerRecovery(_ point: SQLiteJournalFaultPoint) async throws {
        let fixture = try SQLiteFixture()
        defer { fixture.remove() }
        let original = sqliteState()
        try SQLiteJournal(path: fixture.database).write(original)
        _ = try SQLiteTestAnchor(path: fixture.anchor, initial: ContinuityAnchor(committed: original.reference()))
        let databasePath = fixture.database
        let anchorPath = fixture.anchor
        await #expect(processExitsWith: .signal(SIGKILL)) { [databasePath = databasePath as String, anchorPath = anchorPath as String, point] in
            let journal = try SQLiteJournal(path: databasePath) { actual in
                if actual == point { terminateSQLiteChild() }
            }
            let anchor = try SQLiteTestAnchor(path: anchorPath)
            let coordinator = ContinuityCoordinator(database: journal, anchor: anchor)
            try coordinator.transaction { $0.allocations[0].issuedHighWater = 2 }
        }
        let journal = try SQLiteJournal(path: fixture.database)
        let anchor = try SQLiteTestAnchor(path: fixture.anchor)
        let restarted = ContinuityCoordinator(database: journal, anchor: anchor)
        #expect(restarted.status() == .quarantined)
        #expect(try anchor.read()?.pending != nil)
        #expect(try journal.read()?.allocations[0].issuedHighWater == (point == .beforeCommit ? 1 : 2))
        let recovered = try restarted.recover(ownerAuthorized: true, recoveryID: "stable-sql-recovery")
        #expect(recovered.mode == .restricted && recovered.history == .complete)
        #expect(recovered.authorization.generation == 2)
        #expect(recovered.authorization.grants.allSatisfy { $0.revoked })
        #expect(recovered.approvals.allSatisfy { !$0.active })
        #expect(recovered.payments[0].canonicalBytes == original.payments[0].canonicalBytes)
        #expect(recovered.gates == original.gates)
        #expect(try anchor.read()?.recovery == nil)
    }
}

private func terminateSQLiteChild() -> Never {
    precondition(kill(getpid(), SIGKILL) == 0)
    while true { _ = Darwin.pause() }
}

private enum SQLiteInjectedFailure: Error { case stop }

private final class SQLiteCommitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func observe(_ point: SQLiteJournalFaultPoint) {
        if point == .beforeCommit { lock.withLock { value += 1 } }
    }
}

private struct SQLiteFixture {
    let directory: URL
    var database: String { directory.appendingPathComponent("store.sqlite").path }
    // The test anchor is deliberately outside the database file/backup domain.
    var anchor: String { directory.appendingPathComponent("independent-anchor.json").path }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Disposable injected evidence only; no production Keychain or durability substitute.
private final class SQLiteTestAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let path: String
    init(path: String, initial: ContinuityAnchor? = nil) throws {
        self.path = path
        if let initial { try write(initial) }
    }
    func read() throws -> ContinuityAnchor? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try JSONDecoder().decode(ContinuityAnchor.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    func write(_ anchor: ContinuityAnchor) throws {
        try JSONEncoder().encode(anchor).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private func sqliteState() -> CanonicalState {
    var state = CanonicalState(installationID: "installation",
        authorization: AuthorizationLedger(walletID: "wallet", network: "synthetic", generation: 1,
            grants: [GrantRecord(id: "grant", integrationID: "integration", accountIDs: ["account"],
                capabilities: ["read"], credentialDigest: Data(repeating: 1, count: 32),
                credentialGeneration: 1, expiresAt: nil, revoked: false)]),
        commitID: "initial", mode: .enabled, history: .complete)
    state.payments = [PaymentRecord(id: "payment", accountID: "account", network: "synthetic", originGrantID: "grant",
        canonicalBytes: Data([1, 2, 3]), transactionDigest: Data([4]), selectedInputs: ["input"], change: Data([5]),
        disposition: .possiblyRelayed, liabilityUnresolved: true,
        attempts: [AttemptRecord(id: "attempt", number: 1, commandID: nil, outcome: "unknown")],
        evidence: [EvidenceRecord(id: "evidence", source: "fixture", chainTip: "tip", observedAt: 1, contents: Data([6]), valid: false)],
        closures: [ClosureRecord(id: "closure", reason: "prior", evidenceIDs: ["evidence"])])]
    state.approvals = [ApprovalRecord(id: "approval", paymentID: "payment", generation: 1, context: Data([7]), active: true)]
    state.requests = [RequestRecord(id: "request", principalID: "grant", paymentID: "payment", method: "prepare",
        key: "0123456789abcdef0123456789abcdef", binding: Data([8]), disposition: .consumed,
        result: Data([9]), consumedAttemptID: "attempt", tombstone: true)]
    state.gates = [SpendingGate(accountID: "account", liabilityIDs: ["payment"], restrictions: ["uncertain"])]
    state.allocations = [AllocationRecord(accountID: "account", branch: "receive", issuedIndices: [0, 1],
        issuedHighWater: 1, confirmedHistoryHorizon: nil, issuanceEvidence: Data([10]))]
    return state
}

private func withSQL<T>(_ path: String, _ operation: (OpaquePointer) throws -> T) throws -> T {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard result == SQLITE_OK, let database else { throw SQLiteJournalError.sqlite(result) }
    defer { sqlite3_close_v2(database) }
    sqlite3_busy_timeout(database, 0)
    return try operation(database)
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw SQLiteJournalError.sqlite(result) }
}

private func scalar(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else { throw SQLiteJournalError.sqlite(result) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteJournalError.corruptState }
    return sqlite3_column_int64(statement, 0)
}

private enum IncompatibleStorageVariant: String, CaseIterable, Sendable {
    case futureSQLVersion, wrongApplicationID, futureCanonicalFormat, futureAnchorFormat
}

@Test(arguments: IncompatibleStorageVariant.allCases)
private func incompatibleOwnedStorageIsRejectedWithoutChangingBytesOrStartingEffects(variant: IncompatibleStorageVariant) async throws {
    let fixture = try SQLiteFixture()
    defer { fixture.remove() }
    var original = sqliteState()
    original.authorization.network = "mainnet"
    for index in original.payments.indices { original.payments[index].network = "mainnet" }
    do { try SQLiteJournal(path: fixture.database).write(original) }
    let anchor = try SQLiteTestAnchor(path: fixture.anchor, initial: .init(committed: original.reference()))
    switch variant {
    case .futureSQLVersion:
        try withSQL(fixture.database) { try execute($0, "PRAGMA user_version = 999") }
    case .wrongApplicationID:
        try withSQL(fixture.database) { try execute($0, "PRAGMA application_id = 123456") }
    case .futureCanonicalFormat:
        try withSQL(fixture.database) { database in
            let bytes: Data
            do {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "SELECT payload FROM root", -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw SQLiteJournalError.corruptState }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else {
                    throw SQLiteJournalError.corruptState
                }
                bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            }
            var root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            root["formatVersion"] = 99
            let payload = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(database, "UPDATE root SET payload = ?", -1, &update, nil) == SQLITE_OK,
                  let update else { throw SQLiteJournalError.corruptState }
            defer { sqlite3_finalize(update) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bound = payload.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32($0.count), transient) }
            guard bound == SQLITE_OK, sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
                throw SQLiteJournalError.corruptState
            }
        }
    case .futureAnchorFormat:
        var value = try #require(try anchor.read()); value.formatVersion = 99; try anchor.write(value)
    }
    let before = try incompatibleStorageFiles(fixture.directory)
    switch variant {
    case .futureSQLVersion, .wrongApplicationID:
        #expect(throws: SQLiteJournalError.incompatibleSchema) { try SQLiteJournal(path: fixture.database) }
    case .futureCanonicalFormat:
        let reader = try SQLiteJournal(path: fixture.database)
        #expect(throws: ContinuityError.incompatibleSchema) { try reader.read() }
    case .futureAnchorFormat:
        let reader = ContinuityCoordinator(database: try SQLiteJournal(path: fixture.database), anchor: anchor)
        #expect(throws: ContinuityError.incompatibleSchema) { try reader.startup() }
    }
    let effects = RecoveryStorageEffects()
    let database = IncompatibleStorageDatabase(path: fixture.database, effects: effects)
    let readOnlyAnchor = IncompatibleStorageAnchor(base: anchor, effects: effects)
    let continuity = ContinuityCoordinator(database: database, anchor: readOnlyAnchor)
    #expect(continuity.status() == (variant == .futureAnchorFormat ? .incompatibleSchema : .quarantined))
    #expect(throws: (any Error).self) { try continuity.startup() }
    let (owner, context) = recoveryStorageOwner(continuity: continuity, effects: effects)
    if variant == .futureAnchorFormat {
        let response = try await owner.send(OwnerControlRequest(call: .status), connection: context)
        guard case .status(let status) = response.result else { throw ContinuityError.invalidState }
        // The earlier incompatible-schema observation latched quarantine; readable recovery metadata remains.
        #expect(status.availability == .recoveryRequired)
    } else {
        await #expect(throws: ServiceProblem(.recoveryRequired)) {
            try await owner.send(OwnerControlRequest(call: .status), connection: context)
        }
    }
    #expect(effects.counts == RecoveryStorageEffects.Counts())
    let after = try incompatibleStorageFiles(fixture.directory)
    let allBytesAndSidecarsUnchanged = before == after
    #expect(allBytesAndSidecarsUnchanged)
    #expect(Set(before.keys) == ["store.sqlite", "independent-anchor.json"])
    try writeRecoveryStorageReceipt(name: "c2-" + variant.rawValue, contents: [
        "scenario": "C2", "variant": variant.rawValue, "parentPID": getpid(),
        "filesBefore": before.keys.sorted(), "filesAfter": after.keys.sorted(),
        "allBytesAndSidecarsUnchanged": allBytesAndSidecarsUnchanged,
        "effectCounts": try recoveryStorageCountMetadata(effects.counts),
        "existingHotJournalOrWALExercised": false
    ])
}

/// Lazy opening lets the real coordinator/owner metadata path encounter unknown SQL
/// identity before there is any initialized writer. No recovery/reset is attempted.
private final class IncompatibleStorageDatabase: ContinuityDatabase, @unchecked Sendable {
    let path: String
    let effects: RecoveryStorageEffects
    init(path: String, effects: RecoveryStorageEffects) { self.path = path; self.effects = effects }
    func read() throws -> CanonicalState? { try SQLiteJournal(path: path).read() }
    func write(_ state: CanonicalState) throws { try effects.rejectWrite() }
}
private final class IncompatibleStorageAnchor: ContinuityAnchorStore, @unchecked Sendable {
    let base: SQLiteTestAnchor
    let effects: RecoveryStorageEffects
    init(base: SQLiteTestAnchor, effects: RecoveryStorageEffects) { self.base = base; self.effects = effects }
    func read() throws -> ContinuityAnchor? { try base.read() }
    func write(_ anchor: ContinuityAnchor) throws { try effects.rejectWrite() }
}
private func incompatibleStorageFiles(_ directory: URL) throws -> [String: Data] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return try Dictionary(uniqueKeysWithValues: names.map { name in
        (name, try Data(contentsOf: directory.appendingPathComponent(name)))
    })
}
