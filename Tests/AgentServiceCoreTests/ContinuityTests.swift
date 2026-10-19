import Foundation
import OpalDiagnostics
import Testing
@testable import AgentServiceCore

private enum WriteFailure { case before, after, silentDrop }

private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ event: String) { lock.withLock { entries.append(event) } }
    var events: [String] { lock.withLock { entries } }
}

private final class MemoryDatabase: ContinuityDatabase, @unchecked Sendable {
    private let lock = NSLock()
    var value: CanonicalState?
    var readFailures: [Int: ContinuityStoreError] = [:]
    var writeFailures: [Int: WriteFailure] = [:]
    var corruptReadAt: Int?
    private(set) var reads = 0
    private(set) var writes = 0
    let trace: Trace
    init(_ value: CanonicalState?, trace: Trace = Trace()) { self.value = value; self.trace = trace }
    func read() throws -> CanonicalState? {
        try lock.withLock {
            reads += 1
            trace.append("database.read")
            if let error = readFailures[reads] { throw error }
            var result = value
            if corruptReadAt == reads { result?.requests.removeAll() }
            return result
        }
    }
    func write(_ state: CanonicalState) throws {
        try lock.withLock {
            writes += 1
            trace.append("database.write")
            let fault = writeFailures[writes]
            if fault == .before { throw ContinuityStoreError.failed }
            if fault == .silentDrop { return }
            value = state
            if fault == .after { throw ContinuityStoreError.failed }
        }
    }
}

private final class MemoryAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    var value: ContinuityAnchor?
    var readFailures: [Int: ContinuityStoreError] = [:]
    var writeFailures: [Int: WriteFailure] = [:]
    private(set) var history: [ContinuityAnchor] = []
    private(set) var reads = 0
    private(set) var writes = 0
    let trace: Trace
    init(_ value: ContinuityAnchor?, trace: Trace = Trace()) { self.value = value; self.trace = trace }
    func read() throws -> ContinuityAnchor? {
        try lock.withLock {
            reads += 1
            trace.append("anchor.read")
            if let error = readFailures[reads] { throw error }
            return value
        }
    }
    func write(_ anchor: ContinuityAnchor) throws {
        try lock.withLock {
            writes += 1
            trace.append("anchor.write")
            let fault = writeFailures[writes]
            if fault == .before { throw ContinuityStoreError.failed }
            if fault == .silentDrop { return }
            value = anchor
            history.append(anchor)
            if fault == .after { throw ContinuityStoreError.failed }
        }
    }
}

private func fixture() -> CanonicalState {
    let grant = GrantRecord(id: "grant", integrationID: "integration", accountIDs: ["account"],
                            capabilities: ["pay"], credentialDigest: Data([1, 2]),
                            credentialGeneration: 3, expiresAt: nil, revoked: false)
    var state = CanonicalState(installationID: "installation",
                               authorization: AuthorizationLedger(walletID: "wallet", network: "synthetic", generation: 3, grants: [grant]),
                               commitID: "original", mode: .enabled, history: .complete)
    state.approvals = [ApprovalRecord(id: "approval", paymentID: "possible", generation: 3,
                                      context: Data([7]), active: true)]
    state.requests = [RequestRecord(id: "request", principalID: "principal", paymentID: "possible", method: "pay", key: "key", binding: Data([9]),
                                    disposition: .consumed, result: Data([8]), consumedAttemptID: "attempt", tombstone: true),
                      RequestRecord(id: "unsubmitted-request", principalID: "principal", paymentID: "unsubmitted", method: "pay", key: "other-key", binding: Data([4]),
                                    disposition: .unsubmitted, result: Data([5]), consumedAttemptID: nil, tombstone: false)]
    state.payments = [PaymentRecord(id: "possible", accountID: "account", network: "synthetic", originGrantID: "grant", canonicalBytes: Data([10, 11]),
                                    transactionDigest: Data([12]), selectedInputs: ["input"], change: Data([13]), disposition: .possiblyRelayed, liabilityUnresolved: true,
                                    attempts: [AttemptRecord(id: "attempt", number: 1, commandID: "owner-command", outcome: "unknown")],
                                    evidence: [EvidenceRecord(id: "evidence", source: "synthetic-source", chainTip: "tip", observedAt: 42, contents: Data([14]), valid: false)],
                                    closures: [ClosureRecord(id: "closure", reason: "priorAcceptance", evidenceIDs: ["evidence"])]),
                      PaymentRecord(id: "unsubmitted", accountID: "account", network: "synthetic", originGrantID: "grant", canonicalBytes: Data([21]),
                                    transactionDigest: Data([22]), selectedInputs: ["other-input"], change: Data([23]), disposition: .unsubmitted, liabilityUnresolved: false,
                                    attempts: [], evidence: [], closures: [])]
    state.gates = [SpendingGate(accountID: "account", liabilityIDs: ["possible"], restrictions: ["uncertain"])]
    state.allocations = [AllocationRecord(accountID: "account", branch: "receive", issuedIndices: [0, 1], issuedHighWater: 1,
                                          confirmedHistoryHorizon: 0, issuanceEvidence: Data([15]))]
    return state
}

private func stores(_ state: CanonicalState = fixture()) throws -> (MemoryDatabase, MemoryAnchor, ContinuityCoordinator) {
    let trace = Trace()
    let database = MemoryDatabase(state, trace: trace)
    let anchor = MemoryAnchor(ContinuityAnchor(committed: try state.reference()), trace: trace)
    return (database, anchor, ContinuityCoordinator(database: database, anchor: anchor))
}

@Test func commitmentCoversEveryAuthoritativeRowAndCanonicalOrder() throws {
    let original = fixture()
    let reference = try original.reference()
    var reordered = original
    reordered.requests.reverse()
    reordered.payments.reverse()
    #expect(try reordered.reference() == reference)
    let changes: [(inout CanonicalState) -> Void] = [
        { $0.mode = .restricted }, { $0.history = .incomplete }, { $0.installationID += "-changed" },
        { $0.authorization.generation += 1 }, { $0.authorization.grants[0].revoked = true },
        { $0.authorization.grants[0].credentialDigest.append(99) }, { $0.approvals[0].active = false },
        { $0.requests[0].tombstone = false }, { $0.requests[0].binding.append(99) },
        { $0.requests[0].consumedAttemptID = "another-attempt" }, { $0.requests[0].result.append(99) },
        { $0.payments[0].canonicalBytes.append(99) }, { $0.payments[0].selectedInputs.append("another-input") },
        { $0.payments[0].attempts[0].outcome = "different" }, { $0.payments[0].evidence[0].valid = true },
        { $0.payments[0].closures[0].reason = "different" }, { $0.gates[0].restrictions.append("custody") },
        { $0.gates[0].liabilityIDs = [] }, { $0.allocations[0].issuedIndices.append(1) },
        { $0.allocations[0].issuedHighWater = 2 }, { $0.allocations[0].confirmedHistoryHorizon = 1 },
        { $0.allocations[0].issuanceEvidence.append(99) }, { $0.historyProvenance.kind = .integrityOnly }
    ]
    for (index, change) in changes.enumerated() {
        var changed = original
        change(&changed)
        if index == 18 { // Issued indices are a set; duplicate entries do not alter meaning.
            #expect(try changed.reference() == reference)
        } else {
            #expect(try changed.reference() != reference)
        }
    }
}

@Test func fullActualReadbackRejectsRowsOmittedBehindMatchingHeader() throws {
    let (database, anchor, coordinator) = try stores()
    database.corruptReadAt = 2
    #expect(throws: ContinuityError.recoveryRequired) {
        try coordinator.transaction { $0.allocations[0].issuedHighWater = 2 }
    }
    #expect(anchor.value?.pending != nil)
    #expect(coordinator.status() == .quarantined)
}

private enum OrdinaryFault: CaseIterable {
    case stageBefore, stageReadback, databaseBefore, databaseReadback, promotionBefore, promotionReadback
}

@Test(arguments: OrdinaryFault.allCases)
private func ordinaryFailuresNeverAcknowledgeAndRestartOnlyTrustsCleanExactState(_ fault: OrdinaryFault) throws {
    let (database, anchor, coordinator) = try stores()
    switch fault {
    case .stageBefore: anchor.writeFailures[1] = .before
    case .stageReadback: anchor.readFailures[2] = .unavailable
    case .databaseBefore: database.writeFailures[1] = .before
    case .databaseReadback: database.readFailures[2] = .failed
    case .promotionBefore: anchor.writeFailures[2] = .before
    case .promotionReadback: anchor.readFailures[3] = .unavailable
    }
    var acknowledged = false
    #expect(throws: (any Error).self) {
        try coordinator.transaction(mutation: { $0.allocations[0].issuedHighWater = 2 }, projection: { _, _ in acknowledged = true })
    }
    #expect(!acknowledged)
    let restarted = ContinuityCoordinator(database: database, anchor: anchor)
    switch fault {
    case .stageBefore, .promotionReadback:
        #expect(restarted.status() == .trusted(mode: .enabled, history: .complete, generation: 3))
    default:
        #expect(restarted.status() == .quarantined)
    }
}

@Test func ambiguousWritesProceedOnlyWhenActualReadbackProvesEachStage() throws {
    let (database, anchor, coordinator) = try stores()
    anchor.writeFailures = [1: .after, 2: .after]
    database.writeFailures = [1: .after]
    let result = try OpalDiagnostics.withConfiguration(continuityCapture) {
        let result = try coordinator.transaction(mutation: { $0.allocations[0].issuedHighWater = 2 }, projection: { state, _ in
        #expect(anchor.value?.pending == nil)
        let reference = try state.reference()
        #expect(anchor.value?.committed == reference)
        return "acknowledged"
        })
        #expect(OpalDiagnostics.recentRecords.map(\.event.rawValue) == ["barrier_verified"])
        #expect(OpalDiagnostics.configuration == continuityCapture)
        return result
    }
    #expect(result == "acknowledged")
    #expect(anchor.value?.committed == (try database.value?.reference()))
    #expect(anchor.trace.events == ["anchor.read", "database.read", "anchor.write", "anchor.read", "database.write", "database.read", "anchor.write", "anchor.read"])
}

@Test func pendingTargetAndExactParentBothRecoverWithoutLosingPossibleLiability() throws {
    for useTarget in [false, true] {
        let original = fixture()
        var target = original
        target.commitID = "pending-receive"
        target.allocations[0].issuedHighWater = 2
        target.allocations[0].issuedIndices.append(2)
        let database = MemoryDatabase(useTarget ? target : original)
        let anchor = MemoryAnchor(ContinuityAnchor(committed: try original.reference(),
            pending: PendingState(parent: try original.reference(), target: try target.reference(), classification: "receive")))
        let coordinator = ContinuityCoordinator(database: database, anchor: anchor)
        #expect(coordinator.status() == .quarantined)
        let reset = try coordinator.recover(ownerAuthorized: true, recoveryID: "recovery")
        #expect(reset.mode == .restricted && reset.history == .complete && reset.authorization.generation == 4)
        #expect(reset.historyProvenance.kind == (useTarget ? .stagedTarget : .committed))
        #expect(reset.historyProvenance.sourceCommitment == (try (useTarget ? target : original).reference()).commitment)
        #expect(reset.authorization.grants[0].revoked && !reset.approvals[0].active)
        #expect(reset.requests.contains { $0.id == "request" && $0.consumedAttemptID == "attempt" && $0.tombstone })
        #expect(reset.requests.contains { $0.id == "unsubmitted-request" && $0.disposition == .invalidated })
        #expect(reset.payments.first { $0.id == "possible" } == original.payments[0])
        #expect(reset.payments.contains { $0.id == "unsubmitted" && $0.disposition == .invalidated })
        #expect(reset.gates == original.gates)
        #expect(reset.allocations[0].issuedHighWater == (useTarget ? 2 : 1))
        #expect(anchor.value?.recovery == nil && anchor.value?.pending == nil)
        let enabled = try coordinator.enable(ownerAuthorized: true)
        #expect(enabled.mode == .enabled && enabled.gates == original.gates)
        #expect(enabled.authorization.grants.allSatisfy { $0.revoked } && enabled.approvals.allSatisfy { !$0.active })
    }
}

private enum RecoveryFault: CaseIterable {
    case latchBefore, latchReadback, baselineBefore, baselineReadback, stageBefore, stageReadback
    case databaseBefore, databaseReadback, promotionBefore, promotionReadback, finalDatabaseReadback, clearBefore, clearReadback
}

@Test(arguments: RecoveryFault.allCases)
private func recoveryFailurePrefixesRetainStableLatchAndNeverReviveCopiedAuthority(_ fault: RecoveryFault) throws {
    let original = fixture()
    var pendingTarget = original
    pendingTarget.commitID = "pending-target"
    pendingTarget.allocations[0].issuedHighWater = 2
    let database = MemoryDatabase(pendingTarget)
    let anchor = MemoryAnchor(ContinuityAnchor(committed: try original.reference(),
        pending: PendingState(parent: try original.reference(), target: try pendingTarget.reference(), classification: "receive")))
    let coordinator = ContinuityCoordinator(database: database, anchor: anchor)
    switch fault {
    case .latchBefore: anchor.writeFailures[1] = .before
    case .latchReadback: anchor.readFailures[2] = .unavailable
    case .baselineBefore: anchor.writeFailures[2] = .before
    case .baselineReadback: anchor.readFailures[3] = .unavailable
    case .stageBefore: anchor.writeFailures[3] = .before
    case .stageReadback: anchor.readFailures[4] = .unavailable
    case .databaseBefore: database.writeFailures[1] = .before
    case .databaseReadback: database.readFailures[2] = .failed
    case .promotionBefore: anchor.writeFailures[4] = .before
    case .promotionReadback: anchor.readFailures[5] = .unavailable
    case .finalDatabaseReadback: database.readFailures[3] = .failed
    case .clearBefore: anchor.writeFailures[5] = .before
    case .clearReadback: anchor.readFailures[7] = .unavailable
    }
    OpalDiagnostics.withConfiguration(continuityCapture) {
        #expect(throws: (any Error).self) { try coordinator.recover(ownerAuthorized: true, recoveryID: "stable") }
        #expect(!OpalDiagnostics.recentRecords.contains { $0.event.rawValue == "recovery_completed" })
    }
    let latchWasWritten = !anchor.history.isEmpty
    let oldLatch = anchor.history.first?.recovery
    if latchWasWritten {
        #expect(oldLatch?.id == "stable" && oldLatch?.targetGeneration == 4)
        #expect(oldLatch?.observedCommitted == (try original.reference()))
        #expect(oldLatch?.observedDatabase == (try pendingTarget.reference()))
        #expect(oldLatch?.reason == .interruptedUpdate)
        #expect(anchor.history.allSatisfy { $0.recovery == oldLatch || $0.recovery == nil })
    }
    let restarted = ContinuityCoordinator(database: database, anchor: anchor)
    if fault == .latchBefore {
        #expect(restarted.status() == .quarantined)
    } else if anchor.value?.recovery == nil {
        #expect(restarted.status() == .trusted(mode: .restricted, history: .complete, generation: 4))
    } else {
        #expect(restarted.status() == .quarantined)
    }
    // Clear faults; resuming a durable latch ignores a caller-supplied new recovery ID.
    anchor.readFailures = [:]; anchor.writeFailures = [:]
    database.readFailures = [:]; database.writeFailures = [:]
    let reset = try OpalDiagnostics.withConfiguration(continuityCapture) {
        let reset = try restarted.recover(ownerAuthorized: true, recoveryID: "different")
        let completed = OpalDiagnostics.recentRecords.filter { $0.event.rawValue == "recovery_completed" }
        #expect(completed.count == 1)
        #expect(completed.first?.fields.first { $0.name == "history" }?.value == "complete")
        #expect(anchor.value?.recovery == nil && anchor.value?.pending == nil)
        return reset
    }
    #expect(reset.mode == .restricted && reset.authorization.grants.allSatisfy { $0.revoked })
    #expect(reset.payments.first { $0.id == "possible" } == original.payments[0])
    #expect(reset.gates == original.gates)
    if latchWasWritten && fault != .clearReadback {
        #expect(reset.authorization.generation == 4 && reset.commitID == "stable")
    }
}

@Test func incompleteStoreNeverProvesCoverageButOriginalIndependentArchiveCanLaterQualify() throws {
    let original = fixture()
    var lostRows = original
    lostRows.requests.removeAll()
    lostRows.payments.removeAll()
    lostRows.gates.removeAll()
    let database = MemoryDatabase(lostRows)
    let anchor = MemoryAnchor(ContinuityAnchor(committed: try original.reference()))
    let coordinator = ContinuityCoordinator(database: database, anchor: anchor)
    #expect(coordinator.status() == .quarantined)
    let incomplete = try coordinator.recover(ownerAuthorized: true, recoveryID: "incomplete-episode")
    #expect(incomplete.history == .incomplete && incomplete.mode == .restricted)
    #expect(anchor.value?.originalProofs.contains { $0.reference == (try? original.reference()) } == true)
    #expect(throws: ContinuityError.incompleteHistory) { try coordinator.enable(ownerAuthorized: true) }
    let second = try coordinator.recover(ownerAuthorized: true, recoveryID: "current-root-only")
    #expect(second.history == .incomplete && second.authorization.generation == 5)
    #expect(!anchor.value!.originalProofs.isEmpty)
    let complete = try coordinator.recover(ownerAuthorized: true, source: original, recoveryID: "original-found")
    #expect(complete.history == .complete && complete.authorization.generation == 6)
    #expect(complete.payments[0] == original.payments[0] && complete.gates == original.gates)
    #expect(complete.authorization.grants.allSatisfy { $0.revoked })
    #expect(anchor.value?.originalProofs.isEmpty == true)
    #expect(try coordinator.enable(ownerAuthorized: true).mode == .enabled)
}

@Test func missingAnchorIsDistinctFromTemporaryInaccessibilityAndCannotProveHistory() throws {
    let state = fixture()
    let database = MemoryDatabase(state)
    let inaccessible = MemoryAnchor(ContinuityAnchor(committed: try state.reference()))
    inaccessible.readFailures[1] = .unavailable
    let blocked = ContinuityCoordinator(database: database, anchor: inaccessible)
    #expect(blocked.status() == .keyUnavailable)
    #expect(database.reads == 0)
    #expect(blocked.status() == .trusted(mode: .enabled, history: .complete, generation: 3))
    let missing = MemoryAnchor(nil)
    let coordinator = ContinuityCoordinator(database: database, anchor: missing)
    #expect(coordinator.status() == .quarantined)
    #expect(try coordinator.recover(ownerAuthorized: true, recoveryID: "missing").history == .incomplete)
}

@Test func malformedPendingAndUnsupportedSchemaFailClosed() throws {
    let state = fixture()
    var wrongParent = try state.reference()
    wrongParent.commitID = "wrong-parent"
    let pending = PendingState(parent: wrongParent, target: try state.reference(), classification: "receive")
    let database = MemoryDatabase(state)
    let anchor = MemoryAnchor(ContinuityAnchor(committed: try state.reference(), pending: pending))
    let coordinator = ContinuityCoordinator(database: database, anchor: anchor)
    #expect(coordinator.status() == .quarantined)
    #expect(throws: (any Error).self) { try coordinator.recover(ownerAuthorized: true) }
    #expect(anchor.writes == 0)
    let (otherDatabase, otherAnchor, _) = try stores()
    otherAnchor.value?.formatVersion = 99
    #expect(ContinuityCoordinator(database: otherDatabase, anchor: otherAnchor).status() == .incompatibleSchema)
    var futureState = state
    futureState.formatVersion = 99
    #expect(throws: ContinuityError.incompatibleSchema) { try futureState.reference() }
}

@Test func ordinaryMutationCannotEraseIdentityImmutableBytesOrIssuance() throws {
    let changes: [(inout CanonicalState) -> Void] = [
        { $0.requests.removeAll() }, { $0.payments[0].canonicalBytes = Data([99]) },
        { $0.payments[0].attempts.removeAll() }, { $0.payments[0].closures.removeAll() },
        { $0.allocations[0].issuedHighWater = 0; $0.allocations[0].issuedIndices = [0] },
        { $0.authorization.generation += 1 }, { $0.history = .incomplete },
        { $0.gates[0].liabilityIDs.removeAll() },
        { $0.payments[0].liabilityUnresolved = false; $0.payments[0].disposition = .closed; $0.gates.removeAll() },
        { $0.payments[0].evidence[0].contents.append(99) },
        { $0.payments[0].evidence[0].valid = true }
    ]
    for change in changes {
        let (_, anchor, coordinator) = try stores()
        #expect(throws: ContinuityError.invalidState) { try coordinator.transaction(mutation: change) }
        #expect(anchor.writes == 0)
    }
}

@Test func revokedGrantInvalidatesOnlyItsUnsubmittedRows() throws {
    var state = fixture()
    state.invalidateUnsubmitted(grantID: "grant")
    #expect(state.payments.first { $0.id == "possible" }?.disposition == .possiblyRelayed)
    #expect(state.requests.first { $0.id == "request" }?.consumedAttemptID == "attempt")
    #expect(state.payments.first { $0.id == "unsubmitted" }?.disposition == .invalidated)
    #expect(state.requests.first { $0.id == "unsubmitted-request" }?.disposition == .invalidated)
}

private enum ProjectionFailure: Error { case failed }

@Test func serializedPipelineRetainsLockThroughFailedProjectionBeforeNextMutation() throws {
    let (database, anchor, coordinator) = try stores()
    let projectionEntered = DispatchSemaphore(value: 0)
    let releaseProjection = DispatchSemaphore(value: 0)
    let nextCommandStarted = DispatchSemaphore(value: 0)
    let secondMutationEntered = DispatchSemaphore(value: 0)
    let allDone = DispatchGroup()
    let trace = Trace()
    allDone.enter()
    DispatchQueue.global().async {
        defer { allDone.leave() }
        do {
            try coordinator.transaction(mutation: { $0.allocations[0].issuedHighWater = 2 }, projection: { _, _ in
                trace.append("first.projection")
                #expect(anchor.value?.pending == nil)
                projectionEntered.signal()
                _ = releaseProjection.wait(timeout: .now() + 5)
                trace.append("first.projection.failed")
                throw ProjectionFailure.failed
            })
        } catch ProjectionFailure.failed {} catch { Issue.record("Unexpected error: \(error)") }
    }
    #expect(projectionEntered.wait(timeout: .now() + 5) == .success)
    allDone.enter()
    DispatchQueue.global().async {
        defer { allDone.leave() }
        nextCommandStarted.signal()
        do {
            try coordinator.transaction { state in
                trace.append("second.mutation")
                secondMutationEntered.signal()
                state.allocations[0].issuedHighWater = 3
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }
    #expect(nextCommandStarted.wait(timeout: .now() + 5) == .success)
    #expect(secondMutationEntered.wait(timeout: .now() + 0.1) == .timedOut)
    #expect(trace.events == ["first.projection"])
    releaseProjection.signal()
    #expect(allDone.wait(timeout: .now() + 5) == .success)
    #expect(trace.events == ["first.projection", "first.projection.failed", "second.mutation"])
    #expect(database.value?.allocations[0].issuedHighWater == 3)
    #expect(anchor.value?.committed == (try database.value?.reference()))
}

@Test func corruptStartupReadKeepsQuarantineUntilOwnerRecovery() throws {
    let (database, anchor, coordinator) = try stores()
    database.readFailures[1] = .failed
    #expect(coordinator.status() == .quarantined)
    #expect(throws: ContinuityError.recoveryRequired) { try coordinator.inspect { $0.mode } }
    #expect(anchor.writes == 0)
    let reset = try coordinator.recover(ownerAuthorized: true, recoveryID: "repair")
    #expect(reset.mode == .restricted && reset.history == .complete)
}

@Test func ordinaryRestartInvalidatesUnsubmittedBeforeReturningAndKeepsOriginalAuthorityAndLiabilities() throws {
    var original = fixture()
    original.approvals.append(ApprovalRecord(id: "unsubmitted-approval", paymentID: "unsubmitted", generation: 3,
                                              context: Data([61]), active: true))
    original.requests.append(RequestRecord(id: "standalone-request", principalID: "principal", method: "prepare", key: "standalone-key",
                                            binding: Data([62]), disposition: .unsubmitted, result: Data([63]),
                                            consumedAttemptID: nil, tombstone: false))
    let (database, anchor, restarted) = try stores(original)
    let ready = try restarted.startup()
    #expect(ready.authorization == original.authorization)
    #expect(ready.mode == .enabled && ready.history == .complete)
    #expect(ready.requests.allSatisfy { $0.disposition != .unsubmitted })
    #expect(ready.payments.allSatisfy { $0.disposition != .unsubmitted })
    #expect(ready.approvals.first { $0.id == "unsubmitted-approval" }?.active == false)
    #expect(ready.approvals.first { $0.id == "approval" } == original.approvals[0])
    #expect(ready.requests.first { $0.id == "request" } == original.requests[0])
    #expect(ready.requests.first { $0.id == "standalone-request" }?.key == "standalone-key")
    #expect(ready.requests.first { $0.id == "standalone-request" }?.result == Data([63]))
    #expect(ready.payments.first { $0.id == "possible" } == original.payments[0])
    #expect(ready.gates == original.gates && ready.allocations == original.allocations)
    #expect(anchor.value?.pending == nil)
    #expect(anchor.value?.committed == (try database.value?.reference()))
    #expect(anchor.writes == 2 && database.writes == 1)
    let unchanged = try restarted.startup()
    #expect(unchanged.commitID == ready.commitID)
    #expect(anchor.writes == 2 && database.writes == 1)
    #expect(try restarted.inspect { $0.requests.allSatisfy { $0.disposition != .unsubmitted } })
}

@Test func failedStartupBarrierNeverReturnsClientReadyStateAndCannotBeSkippedByRestart() throws {
    let (database, anchor, coordinator) = try stores()
    anchor.writeFailures[2] = .before
    var clientsExposed = false
    #expect(throws: ContinuityError.recoveryRequired) {
        try coordinator.startup()
        clientsExposed = true
    }
    #expect(!clientsExposed)
    #expect(anchor.value?.pending?.classification == "startupInvalidation")
    #expect(throws: ContinuityError.recoveryRequired) { try coordinator.inspect { $0.authorization } }
    let restarted = ContinuityCoordinator(database: database, anchor: anchor)
    #expect(throws: ContinuityError.recoveryRequired) { try restarted.startup() }
    #expect(database.value?.payments.first { $0.id == "possible" } == fixture().payments[0])
    #expect(database.value?.gates == fixture().gates)
}

@Test func newObservationMayBeAppendedWhileRetainedEvidenceAndLiabilityRemainIntact() throws {
    let (database, _, coordinator) = try stores()
    let observation = EvidenceRecord(id: "new-observation", source: "synthetic-source", chainTip: "new-tip", observedAt: 50,
                                     contents: Data([77]), valid: true)
    try coordinator.transaction { $0.payments[0].evidence.append(observation) }
    let possible = database.value?.payments.first { $0.id == "possible" }
    #expect(possible?.evidence.contains(fixture().payments[0].evidence[0]) == true)
    #expect(possible?.evidence.contains(observation) == true)
    #expect(possible?.liabilityUnresolved == true)
}

@Test func ordinaryMutationCannotClearDurablyObservedCredentialExpiry() throws {
    var original = fixture()
    original.authorization.grants[0].expiredObserved = true
    let (_, anchor, coordinator) = try stores(original)
    #expect(throws: ContinuityError.invalidState) {
        try coordinator.transaction { $0.authorization.grants[0].expiredObserved = false }
    }
    #expect(anchor.writes == 0)
}


private let continuityCapture = OpalDiagnostics.Configuration(
    subsystem: "com.58opals.agent.tests", categoryFilter: .enabled(["agent.journal", "agent.payment", "agent.recovery"]),
    bufferPolicy: .enabled(capacity: 40), routingPolicy: .disabled)

@Test(arguments: [false, true])
func diagnosticsReportVerifiedPaymentChangesEvenWhenProjectionThrows(enabled: Bool) throws {
    let configuration = enabled ? continuityCapture : OpalDiagnostics.Configuration()
    let (database, anchor, coordinator) = try stores()
    anchor.writeFailures = [1: .after, 2: .after]
    database.writeFailures = [1: .after]
    try OpalDiagnostics.withConfiguration(configuration) {
        #expect(throws: ProjectionFailure.failed) {
            try coordinator.transaction(mutation: { $0.invalidateUnsubmitted(grantID: "grant") }, projection: { _, _ in
                if enabled {
                    #expect(OpalDiagnostics.recentRecords.map(\.event.rawValue) == ["barrier_verified", "payment_transition"])
                }
                throw ProjectionFailure.failed
            })
        }
        #expect(database.value?.payments.first { $0.id == "unsubmitted" }?.disposition == .invalidated)
        #expect(database.value?.payments.first { $0.id == "possible" }?.liabilityUnresolved == true)
        let committed = try database.value?.reference()
        #expect(anchor.value?.pending == nil && anchor.value?.committed == committed)
        let records = OpalDiagnostics.recentRecords
        if enabled {
            let transition = try #require(records.last)
            #expect(transition.category.rawValue == "agent.payment")
            #expect(transition.fields == [.publicField("from_state", value: "unsubmitted"), .publicField("to_state", value: "invalidated")])
            #expect(transition.traceID == records.first?.traceID)
            #expect(UUID(uuidString: transition.traceID?.rawValue ?? "") != nil)
        } else { #expect(records.isEmpty) }
        // Retrying an unchanged mutation is not a new durable transition.
        try coordinator.transaction { $0.invalidateUnsubmitted(grantID: "grant") }
        #expect(OpalDiagnostics.recentRecords == records)
        #expect(OpalDiagnostics.configuration == configuration)
    }
    #expect(database.writes == 1 && anchor.writes == 2)
}
