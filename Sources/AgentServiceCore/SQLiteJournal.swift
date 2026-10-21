import CSQLite
import Darwin
import Foundation

enum SQLiteJournalFaultPoint: String, Codable, CaseIterable, Sendable {
    case beforeCommit, afterCommit
}

enum SQLiteJournalError: Error, Equatable {
    case invalidPath, incompatibleSchema, corruptState, transactionNotCommitted
    case sqlite(Int32)
}

/// The authoritative rows, not a second operation journal. The service owns the lifetime store lock.
/// Each read opens a new committed snapshot; a failed COMMIT can never verify this writer's rows.
final class SQLiteJournal: ContinuityDatabase, @unchecked Sendable {
    private static let applicationID: Int64 = 0x4f41474a
    private static let schemaVersion: Int64 = 1
    private let lock = NSLock()
    private let path: String
    private let connection: OpaquePointer
    private let fault: (@Sendable (SQLiteJournalFaultPoint) throws -> Void)?
    private var poisoned = false

    init(path: String, createIfMissing: Bool = true,
         fault: (@Sendable (SQLiteJournalFaultPoint) throws -> Void)? = nil) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw SQLiteJournalError.invalidPath }
        let url = URL(fileURLWithPath: path)
        // macOS temporary roots include /var -> /private/var. Resolve parents, never the store itself.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw SQLiteJournalError.invalidPath
        }
        let path = String(cString: parent) + "/" + url.lastPathComponent
        free(parent)
        self.path = path
        self.fault = fault
        connection = try Self.open(path: path,
            flags: SQLITE_OPEN_READWRITE | (createIfMissing ? SQLITE_OPEN_CREATE : 0))
        do {
            let version = try Self.integerScalar(connection, "PRAGMA user_version")
            let identity = try Self.integerScalar(connection, "PRAGMA application_id")
            let isNew = version == 0 && identity == 0
            if isNew {
                guard createIfMissing else { throw SQLiteJournalError.incompatibleSchema }
                guard try Self.integerScalar(connection,
                    "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'") == 0 else {
                    throw SQLiteJournalError.incompatibleSchema
                }
            } else {
                try Self.requireSchema(connection)
            }
            // Reject unknown storage before changing its journal mode or permissions.
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw SQLiteJournalError.sqlite(SQLITE_PERM) }
            try Self.execute(connection, "PRAGMA journal_mode = DELETE")
            try Self.execute(connection, "PRAGMA synchronous = EXTRA")
            try Self.execute(connection, "PRAGMA fullfsync = ON")
            try Self.execute(connection, "PRAGMA foreign_keys = ON")
            try Self.execute(connection, "PRAGMA trusted_schema = OFF")
            guard try Self.textScalar(connection, "PRAGMA journal_mode") == "delete",
                  try Self.integerScalar(connection, "PRAGMA synchronous") == 3,
                  try Self.integerScalar(connection, "PRAGMA fullfsync") == 1,
                  try Self.integerScalar(connection, "PRAGMA foreign_keys") == 1 else {
                throw SQLiteJournalError.incompatibleSchema
            }
            if isNew {
                try Self.execute(connection, "BEGIN IMMEDIATE")
                do {
                    try Self.execute(connection, Self.schema)
                    try Self.execute(connection, "PRAGMA application_id = \(Self.applicationID)")
                    try Self.execute(connection, "PRAGMA user_version = \(Self.schemaVersion)")
                    try Self.execute(connection, "COMMIT")
                } catch {
                    try? Self.execute(connection, "ROLLBACK")
                    throw error
                }
            } else {
                try Self.requireSchema(connection)
            }
        } catch {
            sqlite3_close_v2(connection)
            throw error
        }
    }

    deinit { sqlite3_close_v2(connection) }

    func read() throws -> CanonicalState? {
        try lock.withLock {
            guard !poisoned, sqlite3_get_autocommit(connection) != 0 else {
                throw SQLiteJournalError.transactionNotCommitted
            }
            let snapshot = try Self.open(path: path, flags: SQLITE_OPEN_READONLY)
            defer { sqlite3_close_v2(snapshot) }
            try Self.execute(snapshot, "BEGIN")
            do {
                try Self.requireSchema(snapshot)
                let result = try Self.readState(snapshot)
                try Self.execute(snapshot, "COMMIT")
                return result
            } catch {
                try? Self.execute(snapshot, "ROLLBACK")
                throw error
            }
        }
    }

    func write(_ state: CanonicalState) throws {
        try lock.withLock {
            guard !poisoned, sqlite3_get_autocommit(connection) != 0 else {
                throw SQLiteJournalError.transactionNotCommitted
            }
            try state.validate()
            try Self.requireSchema(connection)
            try Self.execute(connection, "BEGIN IMMEDIATE")
            do {
                for table in ["attempts", "evidence", "closures", "approvals", "requests", "gates",
                              "allocations", "payments", "grants", "root"] {
                    try Self.execute(connection, "DELETE FROM \(table)")
                }
                var root = state.canonicalized()
                root.authorization.grants = []
                root.approvals = []; root.requests = []; root.payments = []
                root.gates = []; root.allocations = []
                try Self.insert(connection, "INSERT INTO root VALUES (1, ?)", [.blob(try Self.encode(root))])
                for row in state.authorization.grants {
                    try Self.insert(connection, "INSERT INTO grants VALUES (?, ?, ?)",
                        [.text(row.id), .text(row.integrationID), .blob(try Self.encode(row))])
                }
                for row in state.payments {
                    var payment = row
                    payment.attempts = []; payment.evidence = []; payment.closures = []
                    try Self.insert(connection, "INSERT INTO payments VALUES (?, ?, ?, ?)",
                        [.text(row.id), .text(row.accountID), .text(row.network), .blob(try Self.encode(payment))])
                    for attempt in row.attempts {
                        try Self.insert(connection, "INSERT INTO attempts VALUES (?, ?, ?, ?)",
                            [.text(row.id), .text(attempt.id), .text(String(attempt.number)), .blob(try Self.encode(attempt))])
                    }
                    for evidence in row.evidence {
                        try Self.insert(connection, "INSERT INTO evidence VALUES (?, ?, ?)",
                            [.text(row.id), .text(evidence.id), .blob(try Self.encode(evidence))])
                    }
                    for closure in row.closures {
                        try Self.insert(connection, "INSERT INTO closures VALUES (?, ?, ?)",
                            [.text(row.id), .text(closure.id), .blob(try Self.encode(closure))])
                    }
                }
                for row in state.approvals {
                    try Self.insert(connection, "INSERT INTO approvals VALUES (?, ?, ?)",
                        [.text(row.id), .text(row.paymentID), .blob(try Self.encode(row))])
                }
                for row in state.requests {
                    try Self.insert(connection, "INSERT INTO requests VALUES (?, ?, ?, ?, ?, ?)",
                        [.text(row.id), .text(row.principalID), row.paymentID.map(SQLValue.text) ?? .null,
                         .text(row.method), .text(row.key), .blob(try Self.encode(row))])
                }
                for row in state.gates {
                    try Self.insert(connection, "INSERT INTO gates VALUES (?, ?)",
                        [.text(row.accountID), .blob(try Self.encode(row))])
                }
                for row in state.allocations {
                    try Self.insert(connection, "INSERT INTO allocations VALUES (?, ?, ?)",
                        [.text(row.accountID), .text(row.branch), .blob(try Self.encode(row))])
                }
                try fault?(.beforeCommit)
                let result = sqlite3_exec(connection, "COMMIT", nil, nil, nil)
                guard result == SQLITE_OK, sqlite3_get_autocommit(connection) != 0 else {
                    throw SQLiteJournalError.sqlite(result == SQLITE_OK ? SQLITE_ERROR : result)
                }
                try fault?(.afterCommit)
            } catch {
                // SQLITE_BUSY at COMMIT leaves a transaction open. Roll it back before read-back.
                if sqlite3_get_autocommit(connection) == 0 {
                    let result = sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
                    if result != SQLITE_OK || sqlite3_get_autocommit(connection) == 0 { poisoned = true }
                }
                throw error
            }
        }
    }

    private static func readState(_ db: OpaquePointer) throws -> CanonicalState? {
        let roots = try rows(db, "SELECT payload FROM root") { try decode(CanonicalState.self, statement: $0, column: 0) }
        guard roots.count <= 1 else { throw SQLiteJournalError.corruptState }
        guard var state = roots.first else {
            for table in ["grants", "payments", "attempts", "evidence", "closures", "approvals", "requests", "gates", "allocations"] {
                guard try integerScalar(db, "SELECT count(*) FROM \(table)") == 0 else { throw SQLiteJournalError.corruptState }
            }
            return nil
        }
        guard state.authorization.grants.isEmpty, state.payments.isEmpty, state.requests.isEmpty,
              state.approvals.isEmpty, state.gates.isEmpty, state.allocations.isEmpty else {
            throw SQLiteJournalError.corruptState
        }
        state.authorization.grants = try rows(db, "SELECT id, integration_id, payload FROM grants") { statement in
            let row = try decode(GrantRecord.self, statement: statement, column: 2)
            guard try text(statement, 0) == row.id, try text(statement, 1) == row.integrationID else { throw SQLiteJournalError.corruptState }
            return row
        }
        state.payments = try rows(db, "SELECT id, account_id, network, payload FROM payments") { statement in
            let row = try decode(PaymentRecord.self, statement: statement, column: 3)
            guard try text(statement, 0) == row.id, try text(statement, 1) == row.accountID,
                  try text(statement, 2) == row.network, row.attempts.isEmpty, row.evidence.isEmpty,
                  row.closures.isEmpty else { throw SQLiteJournalError.corruptState }
            return row
        }
        let attempts: [(String, AttemptRecord)] = try rows(db, "SELECT payment_id, id, number, payload FROM attempts") { statement in
            let row = try decode(AttemptRecord.self, statement: statement, column: 3)
            guard try text(statement, 1) == row.id, try text(statement, 2) == String(row.number) else { throw SQLiteJournalError.corruptState }
            return (try text(statement, 0), row)
        }
        let evidence: [(String, EvidenceRecord)] = try rows(db, "SELECT payment_id, id, payload FROM evidence") { statement in
            let row = try decode(EvidenceRecord.self, statement: statement, column: 2)
            guard try text(statement, 1) == row.id else { throw SQLiteJournalError.corruptState }
            return (try text(statement, 0), row)
        }
        let closures: [(String, ClosureRecord)] = try rows(db, "SELECT payment_id, id, payload FROM closures") { statement in
            let row = try decode(ClosureRecord.self, statement: statement, column: 2)
            guard try text(statement, 1) == row.id else { throw SQLiteJournalError.corruptState }
            return (try text(statement, 0), row)
        }
        let paymentIDs = Set(state.payments.map(\.id))
        guard attempts.allSatisfy({ paymentIDs.contains($0.0) }), evidence.allSatisfy({ paymentIDs.contains($0.0) }),
              closures.allSatisfy({ paymentIDs.contains($0.0) }) else { throw SQLiteJournalError.corruptState }
        let attemptsByPayment = Dictionary(grouping: attempts, by: \.0)
        let evidenceByPayment = Dictionary(grouping: evidence, by: \.0)
        let closuresByPayment = Dictionary(grouping: closures, by: \.0)
        for index in state.payments.indices {
            let id = state.payments[index].id
            state.payments[index].attempts = attemptsByPayment[id, default: []].map(\.1)
            state.payments[index].evidence = evidenceByPayment[id, default: []].map(\.1)
            state.payments[index].closures = closuresByPayment[id, default: []].map(\.1)
        }
        state.approvals = try rows(db, "SELECT id, payment_id, payload FROM approvals") { statement in
            let row = try decode(ApprovalRecord.self, statement: statement, column: 2)
            guard try text(statement, 0) == row.id, try text(statement, 1) == row.paymentID else { throw SQLiteJournalError.corruptState }
            return row
        }
        state.requests = try rows(db, "SELECT id, principal_id, payment_id, method, request_key, payload FROM requests") { statement in
            let row = try decode(RequestRecord.self, statement: statement, column: 5)
            let paymentID = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : try text(statement, 2)
            guard try text(statement, 0) == row.id, try text(statement, 1) == row.principalID, paymentID == row.paymentID,
                  try text(statement, 3) == row.method, try text(statement, 4) == row.key else { throw SQLiteJournalError.corruptState }
            return row
        }
        state.gates = try rows(db, "SELECT account_id, payload FROM gates") { statement in
            let row = try decode(SpendingGate.self, statement: statement, column: 1)
            guard try text(statement, 0) == row.accountID else { throw SQLiteJournalError.corruptState }
            return row
        }
        state.allocations = try rows(db, "SELECT account_id, branch, payload FROM allocations") { statement in
            let row = try decode(AllocationRecord.self, statement: statement, column: 2)
            guard try text(statement, 0) == row.accountID, try text(statement, 1) == row.branch else { throw SQLiteJournalError.corruptState }
            return row
        }
        try state.validate()
        return state.canonicalized()
    }

    private enum SQLValue { case text(String), blob(Data), null }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func open(path: String, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw SQLiteJournalError.sqlite(result)
        }
        sqlite3_busy_timeout(db, 0)
        return db
    }

    private static func requireSchema(_ db: OpaquePointer) throws {
        guard try integerScalar(db, "PRAGMA user_version") == schemaVersion,
              try integerScalar(db, "PRAGMA application_id") == applicationID else {
            throw SQLiteJournalError.incompatibleSchema
        }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw SQLiteJournalError.sqlite(result) }
    }

    private static func insert(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue]) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw SQLiteJournalError.sqlite(prepared) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, Int32(text.utf8.count), transient) }
            case .blob(let data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(offset + 1), $0.baseAddress, Int32($0.count), transient) }
            case .null: result = sqlite3_bind_null(statement, Int32(offset + 1))
            }
            guard result == SQLITE_OK else { throw SQLiteJournalError.sqlite(result) }
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw SQLiteJournalError.sqlite(result) }
    }

    private static func rows<T>(_ db: OpaquePointer, _ sql: String, _ decode: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw SQLiteJournalError.sqlite(prepared) }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw SQLiteJournalError.sqlite(step) }
            result.append(try decode(statement))
        }
    }

    private static func integerScalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        let result = try rows(db, sql) { sqlite3_column_int64($0, 0) }
        guard result.count == 1, let value = result.first else { throw SQLiteJournalError.corruptState }
        return value
    }

    private static func textScalar(_ db: OpaquePointer, _ sql: String) throws -> String {
        let result = try rows(db, sql) { try text($0, 0) }
        guard result.count == 1, let value = result.first else { throw SQLiteJournalError.corruptState }
        return value
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, column),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else {
            throw SQLiteJournalError.corruptState
        }
        return value
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, statement: OpaquePointer, column: Int32) throws -> T {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB, let bytes = sqlite3_column_blob(statement, column) else {
            throw SQLiteJournalError.corruptState
        }
        do { return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))) }
        catch { throw SQLiteJournalError.corruptState }
    }

    private static let schema = """
    CREATE TABLE root (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), payload BLOB NOT NULL);
    CREATE TABLE grants (id TEXT PRIMARY KEY NOT NULL, integration_id TEXT NOT NULL, payload BLOB NOT NULL);
    CREATE TABLE payments (id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL, network TEXT NOT NULL, payload BLOB NOT NULL);
    CREATE TABLE attempts (payment_id TEXT NOT NULL REFERENCES payments(id), id TEXT NOT NULL, number TEXT NOT NULL,
        payload BLOB NOT NULL, PRIMARY KEY(payment_id, id), UNIQUE(payment_id, number));
    CREATE TABLE evidence (payment_id TEXT NOT NULL REFERENCES payments(id), id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(payment_id, id));
    CREATE TABLE closures (payment_id TEXT NOT NULL REFERENCES payments(id), id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(payment_id, id));
    CREATE TABLE approvals (id TEXT PRIMARY KEY NOT NULL, payment_id TEXT NOT NULL REFERENCES payments(id), payload BLOB NOT NULL);
    CREATE TABLE requests (id TEXT PRIMARY KEY NOT NULL, principal_id TEXT NOT NULL, payment_id TEXT REFERENCES payments(id),
        method TEXT NOT NULL, request_key TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(principal_id, method, request_key));
    CREATE TABLE gates (account_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
    CREATE TABLE allocations (account_id TEXT NOT NULL, branch TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(account_id, branch));
    """
}
