import CryptoKit
import Foundation

// Synthetic authoritative rows. No signer, chain engine, or persistence backend is supplied.
enum WalletMode: String, Codable, Sendable { case restricted, enabled }
enum HistoryCoverage: String, Codable, Sendable { case complete, incomplete }
enum HistoryProofKind: String, Codable, Sendable { case committed, stagedTarget, integrityOnly, unproven }
struct HistoryProvenance: Codable, Equatable, Sendable {
    var kind: HistoryProofKind = .unproven
    var sourceCommitment: Data? = nil
    var parentCommitment: Data? = nil
}
enum RequestDisposition: String, Codable, Sendable { case unsubmitted, invalidated, consumed, closed }
enum PaymentDisposition: String, Codable, Sendable { case unsubmitted, invalidated, possiblyRelayed, closed }

struct ApprovalRecord: Codable, Equatable, Sendable {
    var id: String
    var paymentID: String
    var generation: UInt64
    var context: Data
    var active: Bool
}

struct RequestRecord: Codable, Equatable, Sendable {
    var id: String
    var principalID: String
    var paymentID: String? = nil
    var method: String
    var key: String
    var binding: Data
    var disposition: RequestDisposition
    var result: Data
    var consumedAttemptID: String?
    var tombstone: Bool
}

struct AttemptRecord: Codable, Equatable, Sendable {
    var id: String
    var number: UInt64
    var commandID: String?
    var outcome: String
}

struct EvidenceRecord: Codable, Equatable, Sendable {
    var id: String
    var source: String
    var chainTip: String
    var observedAt: Int64
    var contents: Data
    var valid: Bool
}

struct ClosureRecord: Codable, Equatable, Sendable {
    var id: String
    var reason: String
    var evidenceIDs: [String]
}

struct PaymentRecord: Codable, Equatable, Sendable {
    var id: String
    var accountID: String
    var network: String
    var originGrantID: String? = nil
    var canonicalBytes: Data
    var transactionDigest: Data
    var selectedInputs: [String]
    var change: Data
    var disposition: PaymentDisposition
    var liabilityUnresolved: Bool
    var attempts: [AttemptRecord]
    var evidence: [EvidenceRecord]
    var closures: [ClosureRecord]
}

struct SpendingGate: Codable, Equatable, Sendable {
    var accountID: String
    var liabilityIDs: [String]
    var restrictions: [String]
}

struct AllocationRecord: Codable, Equatable, Sendable {
    var accountID: String
    var branch: String
    var issuedIndices: [UInt64]
    var issuedHighWater: UInt64?
    var confirmedHistoryHorizon: UInt64?
    var issuanceEvidence: Data
}

struct CanonicalState: Codable, Equatable, Sendable {
    var formatVersion: UInt64 = 1
    var installationID: String
    var authorization: AuthorizationLedger
    var commitID: String = UUID().uuidString
    var mode: WalletMode = .restricted
    var history: HistoryCoverage = .incomplete
    var historyProvenance = HistoryProvenance()
    var approvals: [ApprovalRecord] = []
    var requests: [RequestRecord] = []
    var payments: [PaymentRecord] = []
    var gates: [SpendingGate] = []
    var allocations: [AllocationRecord] = []

    mutating func invalidateUnsubmitted(grantID: String) {
        let affected = Set(payments.filter { $0.originGrantID == grantID && $0.disposition == .unsubmitted }.map(\.id))
        for index in payments.indices where affected.contains(payments[index].id) {
            payments[index].disposition = .invalidated
        }
        for index in requests.indices where requests[index].paymentID.map(affected.contains) == true &&
            requests[index].disposition == .unsubmitted {
            requests[index].disposition = .invalidated
        }
        for index in approvals.indices where affected.contains(approvals[index].paymentID) {
            approvals[index].active = false
        }
    }

    mutating func invalidateAllUnsubmitted() -> Bool {
        let affected = Set(payments.filter { $0.disposition == .unsubmitted }.map(\.id))
            .union(requests.filter { $0.disposition == .unsubmitted }.compactMap(\.paymentID))
        var changed = false
        for index in payments.indices where payments[index].disposition == .unsubmitted {
            payments[index].disposition = .invalidated
            changed = true
        }
        for index in requests.indices where requests[index].disposition == .unsubmitted {
            requests[index].disposition = .invalidated
            changed = true
        }
        for index in approvals.indices where approvals[index].active && affected.contains(approvals[index].paymentID) {
            approvals[index].active = false
            changed = true
        }
        return changed
    }

    func canonicalized() -> Self {
        var copy = self
        copy.authorization = authorization.canonicalized()
        copy.approvals.sort { $0.id < $1.id }
        copy.requests.sort { $0.id < $1.id }
        copy.payments = payments.map { payment in
            var row = payment
            row.selectedInputs.sort()
            row.attempts.sort { $0.id < $1.id }
            row.evidence.sort { $0.id < $1.id }
            row.closures = row.closures.map { closure in
                var value = closure
                value.evidenceIDs.sort()
                return value
            }.sorted { $0.id < $1.id }
            return row
        }.sorted { $0.id < $1.id }
        copy.gates = gates.map { gate in
            var row = gate
            row.liabilityIDs = Array(Set(row.liabilityIDs)).sorted()
            row.restrictions = Array(Set(row.restrictions)).sorted()
            return row
        }.sorted { $0.accountID < $1.accountID }
        copy.allocations = allocations.map { allocation in
            var row = allocation
            row.issuedIndices = Array(Set(row.issuedIndices)).sorted()
            return row
        }.sorted { ($0.accountID, $0.branch) < ($1.accountID, $1.branch) }
        return copy
    }

    func reference() throws -> StateReference {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = Data(SHA256.hash(data: try encoder.encode(canonicalized())))
        return StateReference(installationID: installationID, walletID: authorization.walletID,
                              network: authorization.network, generation: authorization.generation,
                              commitID: commitID, formatVersion: formatVersion,
                              commitment: digest, history: history)
    }

    func validate() throws {
        guard formatVersion == 1 else { throw ContinuityError.incompatibleSchema }
        guard !installationID.isEmpty, !authorization.walletID.isEmpty, !authorization.network.isEmpty,
              !commitID.isEmpty, unique(authorization.grants.map(\.id)), unique(approvals.map(\.id)),
              unique(requests.map(\.id)), unique(payments.map(\.id)), unique(gates.map(\.accountID)),
              unique(allocations.map { "\($0.accountID)\u{0}\($0.branch)" }) else {
            throw ContinuityError.invalidState
        }
        for payment in payments {
            guard !payment.accountID.isEmpty, payment.network == authorization.network,
                  unique(payment.attempts.map(\.id)), unique(payment.evidence.map(\.id)),
                  unique(payment.closures.map(\.id)),
                  payment.disposition != .possiblyRelayed || payment.liabilityUnresolved else {
                throw ContinuityError.invalidState
            }
            if payment.liabilityUnresolved || payment.disposition == .possiblyRelayed || !payment.attempts.isEmpty {
                guard !payment.canonicalBytes.isEmpty, !payment.transactionDigest.isEmpty else {
                    throw ContinuityError.invalidState
                }
            }
        }
        for allocation in allocations {
            guard !allocation.accountID.isEmpty, !allocation.branch.isEmpty,
                  allocation.issuedIndices.allSatisfy({ index in
                      allocation.issuedHighWater.map { index <= $0 } ?? false
                  }) else { throw ContinuityError.invalidState }
        }
    }

    func hasCompleteGateCoverage() -> Bool {
        payments.filter(\.liabilityUnresolved).allSatisfy { payment in
            gates.contains { $0.accountID == payment.accountID && $0.liabilityIDs.contains(payment.id) }
        } && gates.allSatisfy { gate in
            gate.liabilityIDs.allSatisfy { id in
                payments.contains { $0.id == id && $0.accountID == gate.accountID }
            }
        }
    }

    fileprivate func restricted(generation: UInt64, commitID: String, history: HistoryCoverage, provenance: HistoryProvenance) -> Self {
        var copy = self
        copy.authorization = authorization.disablingAllGrants()
        copy.authorization.generation = generation
        copy.commitID = commitID
        copy.mode = .restricted
        copy.history = history
        copy.historyProvenance = provenance
        for index in copy.approvals.indices { copy.approvals[index].active = false }
        for index in copy.requests.indices where copy.requests[index].disposition == .unsubmitted {
            copy.requests[index].disposition = .invalidated
        }
        for index in copy.payments.indices where copy.payments[index].disposition == .unsubmitted {
            copy.payments[index].disposition = .invalidated
        }
        for payment in copy.payments where payment.liabilityUnresolved {
            if let index = copy.gates.firstIndex(where: { $0.accountID == payment.accountID }) {
                copy.gates[index].liabilityIDs.append(payment.id)
            } else {
                copy.gates.append(SpendingGate(accountID: payment.accountID,
                                                liabilityIDs: [payment.id], restrictions: []))
            }
        }
        return copy.canonicalized()
    }
}

private func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }

struct StateReference: Codable, Equatable, Sendable {
    var installationID: String
    var walletID: String
    var network: String
    var generation: UInt64
    var commitID: String
    var formatVersion: UInt64
    var commitment: Data
    var history: HistoryCoverage

    fileprivate func sameWallet(as other: Self) -> Bool {
        installationID == other.installationID && walletID == other.walletID && network == other.network
    }
}

struct PendingState: Codable, Equatable, Sendable {
    var parent: StateReference?
    var target: StateReference
    var classification: String
}

struct RetainedProof: Codable, Equatable, Sendable {
    var reference: StateReference
    var parent: StateReference?
    var classification: String
}

enum RecoveryReason: String, Codable, Sendable {
    case ownerReset, missingAnchor, interruptedUpdate, stateMismatch, incompleteHistory
}

struct RecoveryLatch: Codable, Equatable, Sendable {
    var id: String
    var targetGeneration: UInt64
    var observedCommitted: StateReference? = nil
    var observedPending: PendingState? = nil
    var observedDatabase: StateReference? = nil
    var reason: RecoveryReason = .ownerReset
}

struct ContinuityAnchor: Codable, Equatable, Sendable {
    var formatVersion: UInt64 = 1
    var committed: StateReference?
    var pending: PendingState? = nil
    var recovery: RecoveryLatch? = nil
    var originalProofs: [RetainedProof] = []

    fileprivate func validate() throws {
        guard formatVersion == 1 else { throw ContinuityError.incompatibleSchema }
        let references = [committed, pending?.target, pending?.parent].compactMap { $0 }
            + originalProofs.flatMap { [$0.reference, $0.parent].compactMap { $0 } }
        guard references.allSatisfy({ $0.formatVersion == 1 && $0.commitment.count == 32 }) else {
            throw ContinuityError.incompatibleSchema
        }
        if let pending {
            guard pending.parent == committed, !pending.classification.isEmpty,
                  pending.parent.map({ pending.target.sameWallet(as: $0) }) ?? (recovery != nil),
                  pending.target.generation == committed?.generation ||
                    pending.target.generation == recovery?.targetGeneration else {
                throw ContinuityError.recoveryRequired
            }
        }
        if let recovery {
            guard !recovery.id.isEmpty, committed.map({ recovery.targetGeneration >= $0.generation }) ?? true else {
                throw ContinuityError.recoveryRequired
            }
        }
        if let wallet = committed ?? pending?.target ?? originalProofs.first?.reference {
            guard references.allSatisfy({ $0.sameWallet(as: wallet) }) else {
                throw ContinuityError.recoveryRequired
            }
        }
        for proof in originalProofs {
            guard ["committed", "stagedTarget"].contains(proof.classification) else {
                throw ContinuityError.recoveryRequired
            }
            if proof.classification == "stagedTarget" {
                guard let parent = proof.parent, proof.reference.sameWallet(as: parent) else {
                    throw ContinuityError.recoveryRequired
                }
            }
        }
    }

    fileprivate var proofs: [RetainedProof] {
        var result = originalProofs
        if let committed {
            result.append(RetainedProof(reference: committed, parent: nil, classification: "committed"))
        }
        if let pending {
            result.append(RetainedProof(reference: pending.target, parent: pending.parent,
                                        classification: "stagedTarget"))
        }
        return result
    }
}

enum ContinuityStoreError: Error { case unavailable, failed }
enum ContinuityError: Error, Equatable {
    case recoveryRequired, keyUnavailable, storageUnavailable, incompatibleSchema
    case ownerRequired, incompleteHistory, invalidState, identifierExhausted
}

protocol ContinuityDatabase: AnyObject, Sendable {
    func read() throws -> CanonicalState?
    func write(_ state: CanonicalState) throws
}

protocol ContinuityAnchorStore: AnyObject, Sendable {
    func read() throws -> ContinuityAnchor?
    func write(_ anchor: ContinuityAnchor) throws
}

enum ContinuityStatus: Equatable, Sendable {
    case trusted(mode: WalletMode, history: HistoryCoverage, generation: UInt64)
    case quarantined
    case keyUnavailable
    case storageUnavailable
    case incompatibleSchema
}

// All store operations and result projection are synchronous while the same lock is held.
// Store implementations must make each individual write atomic; this is not a disk backend.
final class ContinuityCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let database: any ContinuityDatabase
    private let anchor: any ContinuityAnchorStore
    private var quarantine = false

    init(database: any ContinuityDatabase, anchor: any ContinuityAnchorStore) {
        self.database = database
        self.anchor = anchor
    }

    // Service startup must finish this barrier before exposing any client authority.
    // Surviving preparation records are invalidated, never rehydrated as live leases.
    @discardableResult
    func startup() throws -> CanonicalState {
        lock.lock()
        defer { lock.unlock() }
        let original = try trusted()
        var proposed = original.state
        guard proposed.invalidateAllUnsubmitted() else { return original.state }
        proposed.commitID = UUID().uuidString
        try validateRetention(from: original.state, to: proposed)
        try handshake(proposed, from: original.anchor, classification: "startupInvalidation")
        return proposed.canonicalized()
    }

    func status() -> ContinuityStatus {
        lock.lock()
        defer { lock.unlock() }
        do {
            let state = try trusted().state
            return .trusted(mode: state.mode, history: state.history, generation: state.authorization.generation)
        }
        catch ContinuityError.keyUnavailable { return .keyUnavailable }
        catch ContinuityError.storageUnavailable { return .storageUnavailable }
        catch ContinuityError.incompatibleSchema { return .incompatibleSchema }
        catch { return .quarantined }
    }

    func inspect<Result>(_ projection: (CanonicalState) throws -> Result) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try projection(trusted().state)
    }

    func transaction<Result>(classification: String = "command",
                             mutation: (inout CanonicalState) throws -> Result) throws -> Result {
        try transaction(classification: classification, mutation: { state in
            let result = try mutation(&state)
            return result
        }, projection: { _, result in result })
    }

    func transaction<Intermediate, Result>(classification: String = "command",
                                           mutation: (inout CanonicalState) throws -> Intermediate,
                                           projection: (CanonicalState, Intermediate) throws -> Result) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        let original = try trusted()
        var proposed = original.state
        let intermediate = try mutation(&proposed)
        // The coordinator owns identity and provenance, including enablement.
        guard proposed.installationID == original.state.installationID,
              proposed.authorization.walletID == original.state.authorization.walletID,
              proposed.authorization.network == original.state.authorization.network,
              proposed.authorization.generation == original.state.authorization.generation,
              proposed.history == original.state.history,
              proposed.mode == original.state.mode else { throw ContinuityError.invalidState }
        try validateRetention(from: original.state, to: proposed)
        // Observational commands keep the complete verified state and project under this lock.
        if proposed.canonicalized() == original.state.canonicalized() {
            return try projection(original.state.canonicalized(), intermediate)
        }
        proposed.commitID = UUID().uuidString
        try handshake(proposed, from: original.anchor, classification: classification)
        return try projection(proposed.canonicalized(), intermediate)
    }

    func enable(ownerAuthorized: Bool) throws -> CanonicalState {
        lock.lock()
        defer { lock.unlock() }
        guard ownerAuthorized else { throw ContinuityError.ownerRequired }
        let original = try trusted()
        guard original.state.history == .complete, original.state.hasCompleteGateCoverage() else {
            throw ContinuityError.incompleteHistory
        }
        var proposed = original.state
        proposed.mode = .enabled
        proposed.commitID = UUID().uuidString
        try handshake(proposed, from: original.anchor, classification: "enableWallet")
        return proposed
    }

    func recover(ownerAuthorized: Bool, source: CanonicalState? = nil,
                 recoveryID: String = UUID().uuidString) throws -> CanonicalState {
        lock.lock()
        defer { lock.unlock() }
        guard ownerAuthorized else { throw ContinuityError.ownerRequired }
        var currentAnchor = try readAnchor() ?? ContinuityAnchor(committed: nil)
        try currentAnchor.validate()
        let stored = try readDatabase()
        let candidate = source ?? stored
        guard let candidate else { throw ContinuityError.invalidState }
        try candidate.validate()
        let candidateReference = try candidate.reference()
        if let known = currentAnchor.committed ?? currentAnchor.originalProofs.first?.reference {
            guard candidateReference.sameWallet(as: known) else { throw ContinuityError.invalidState }
        }
        // Preserve independent original endorsements before selecting or replacing a baseline.
        let proofs = currentAnchor.proofs
        if currentAnchor.recovery == nil {
            let maximum = proofs.map(\.reference.generation).max() ?? candidate.authorization.generation
            guard maximum < UInt64.max, !recoveryID.isEmpty else { throw ContinuityError.identifierExhausted }
            let observed = try? stored?.reference()
            let reason: RecoveryReason = currentAnchor.committed == nil ? .missingAnchor
                : currentAnchor.pending != nil ? .interruptedUpdate
                : observed != currentAnchor.committed ? .stateMismatch
                : candidate.history == .incomplete ? .incompleteHistory : .ownerReset
            currentAnchor.recovery = RecoveryLatch(id: recoveryID, targetGeneration: maximum + 1,
                observedCommitted: currentAnchor.committed, observedPending: currentAnchor.pending,
                observedDatabase: observed, reason: reason)
            currentAnchor.originalProofs = deduplicated(proofs.filter { $0.reference.history == .complete })
            try writeAnchorAndVerify(currentAnchor)
        }
        guard let latch = currentAnchor.recovery else { throw ContinuityError.recoveryRequired }
        // An interrupted completed reset can clear its latch without resetting it again.
        if currentAnchor.committed == candidateReference || currentAnchor.pending?.target == candidateReference,
           candidate.authorization.generation == latch.targetGeneration, candidate.commitID == latch.id,
           candidate.mode == .restricted, recoveredAuthorityDisabled(candidate),
           candidate.hasCompleteGateCoverage(), stored.map({ (try? $0.reference()) == candidateReference }) == true {
            var finished = currentAnchor
            if finished.pending != nil {
                finished.committed = candidateReference
                finished.pending = nil
                try writeAnchorAndVerify(finished)
            }
            finished.recovery = nil
            try writeAnchorAndVerify(finished)
            quarantine = false
            return candidate
        }
        let qualified = proofs.first { $0.reference == candidateReference }
        let coverage: HistoryCoverage = qualified?.reference.history == .complete ? .complete : .incomplete
        let kind: HistoryProofKind = coverage == .incomplete ? (qualified == nil ? .unproven : .integrityOnly)
            : (qualified?.classification == "stagedTarget" ? .stagedTarget : .committed)
        let provenance = HistoryProvenance(kind: kind, sourceCommitment: qualified?.reference.commitment,
                                            parentCommitment: qualified?.parent?.commitment)
        let reset = candidate.restricted(generation: latch.targetGeneration, commitID: latch.id,
                                         history: coverage, provenance: provenance)
        // Baseline selection is separate and remains protected by the stable latch.
        currentAnchor.committed = qualified?.reference ?? currentAnchor.committed
        currentAnchor.pending = nil
        if coverage == .complete { currentAnchor.originalProofs = [] }
        try writeAnchorAndVerify(currentAnchor)
        try handshake(reset, from: currentAnchor, classification: "ownerRecovery")
        var finished = try readAnchorRequired()
        guard finished.recovery == latch, finished.pending == nil,
              finished.committed == (try reset.reference()),
              (try readDatabase()?.reference()) == (try reset.reference()) else {
            quarantine = true
            throw ContinuityError.recoveryRequired
        }
        finished.recovery = nil
        try writeAnchorAndVerify(finished)
        quarantine = false
        return reset
    }

    private func trusted() throws -> (state: CanonicalState, anchor: ContinuityAnchor) {
        guard !quarantine else { throw ContinuityError.recoveryRequired }
        do {
            let currentAnchor = try readAnchorRequired()
            try currentAnchor.validate()
            guard currentAnchor.pending == nil, currentAnchor.recovery == nil,
                  let state = try readDatabase(), let reference = currentAnchor.committed,
                  (try state.reference()) == reference, state.hasCompleteGateCoverage(),
                  state.mode != .enabled || state.history == .complete,
                  state.mode != .restricted || recoveredAuthorityDisabled(state) else {
                throw ContinuityError.recoveryRequired
            }
            return (state, currentAnchor)
        } catch ContinuityError.keyUnavailable {
            throw ContinuityError.keyUnavailable
        } catch ContinuityError.storageUnavailable {
            throw ContinuityError.storageUnavailable
        } catch {
            quarantine = true
            throw error
        }
    }

    private func handshake(_ state: CanonicalState, from original: ContinuityAnchor,
                           classification: String) throws {
        try state.validate()
        guard original.pending == nil, !classification.isEmpty else {
            quarantine = true
            throw ContinuityError.recoveryRequired
        }
        let target = try state.reference()
        var staged = original
        staged.pending = PendingState(parent: original.committed, target: target, classification: classification)
        try writeAnchorAndVerify(staged)
        do { try database.write(state.canonicalized()) } catch { /* Verify an ambiguous write. */ }
        guard let actual = try readDatabase(), (try actual.reference()) == target else {
            quarantine = true
            throw ContinuityError.recoveryRequired
        }
        var promoted = staged
        promoted.committed = target
        promoted.pending = nil
        try writeAnchorAndVerify(promoted)
    }

    private func writeAnchorAndVerify(_ expected: ContinuityAnchor) throws {
        do { try anchor.write(expected) } catch { /* Read-back, never infer a write outcome. */ }
        do {
            guard try readAnchor() == expected else {
                quarantine = true
                throw ContinuityError.recoveryRequired
            }
        } catch {
            quarantine = true
            throw error
        }
    }

    private func readAnchor() throws -> ContinuityAnchor? {
        do { return try anchor.read() }
        catch ContinuityStoreError.unavailable { throw ContinuityError.keyUnavailable }
        catch { throw ContinuityError.recoveryRequired }
    }

    private func readAnchorRequired() throws -> ContinuityAnchor {
        guard let value = try readAnchor() else { throw ContinuityError.recoveryRequired }
        return value
    }

    private func readDatabase() throws -> CanonicalState? {
        do { return try database.read() }
        catch ContinuityStoreError.unavailable { throw ContinuityError.storageUnavailable }
        catch { throw ContinuityError.recoveryRequired }
    }
}

private func recoveredAuthorityDisabled(_ state: CanonicalState) -> Bool {
    state.authorization.grants.allSatisfy(\.revoked) && state.approvals.allSatisfy { !$0.active }
        && state.requests.allSatisfy { $0.disposition != .unsubmitted }
        && state.payments.allSatisfy { $0.disposition != .unsubmitted }
}

private func deduplicated(_ proofs: [RetainedProof]) -> [RetainedProof] {
    var result: [RetainedProof] = []
    for proof in proofs where !result.contains(proof) { result.append(proof) }
    return result
}

private func validateRetention(from old: CanonicalState, to new: CanonicalState) throws {
    try new.validate()
    if old.mode == .restricted {
        guard new.authorization == old.authorization, new.approvals.allSatisfy({ !$0.active }),
              new.requests.allSatisfy({ $0.disposition != .unsubmitted }),
              new.payments.allSatisfy({ $0.disposition != .unsubmitted }) else {
            throw ContinuityError.invalidState
        }
    }
    guard new.hasCompleteGateCoverage(),
          Set(old.authorization.grants.map(\.id)).isSubset(of: Set(new.authorization.grants.map(\.id))),
          old.authorization.grants.filter(\.expiredObserved).allSatisfy({ grant in
              new.authorization.grants.contains { $0.id == grant.id && $0.expiredObserved }
          }),
          Set(old.approvals.map(\.id)).isSubset(of: Set(new.approvals.map(\.id))),
          old.requests.allSatisfy({ request in
              new.requests.contains { $0.id == request.id && $0.principalID == request.principalID &&
                  $0.method == request.method && $0.key == request.key && $0.paymentID == request.paymentID && $0.binding == request.binding &&
                  (!request.tombstone || $0.tombstone) &&
                  (request.consumedAttemptID == nil || $0.consumedAttemptID == request.consumedAttemptID) }
          }),
          old.payments.allSatisfy({ payment in
              new.payments.contains { row in
                  row.id == payment.id && row.accountID == payment.accountID && row.network == payment.network && row.originGrantID == payment.originGrantID &&
                  row.canonicalBytes == payment.canonicalBytes && row.transactionDigest == payment.transactionDigest &&
                  row.selectedInputs.sorted() == payment.selectedInputs.sorted() && row.change == payment.change &&
                  (!payment.liabilityUnresolved || row.liabilityUnresolved) &&
                  payment.attempts.allSatisfy({ row.attempts.contains($0) }) &&
                  payment.closures.allSatisfy({ row.closures.contains($0) }) &&
                  payment.evidence.allSatisfy({ row.evidence.contains($0) })
              }
          }),
          old.allocations.allSatisfy({ allocation in
              new.allocations.contains { row in
                  row.accountID == allocation.accountID && row.branch == allocation.branch &&
                  Set(allocation.issuedIndices).isSubset(of: Set(row.issuedIndices)) &&
                  (allocation.issuedHighWater.map { oldHigh in row.issuedHighWater.map { $0 >= oldHigh } ?? false } ?? true)
              }
          }) else { throw ContinuityError.invalidState }
}
