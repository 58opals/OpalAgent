import Foundation
import Testing
import AgentValues
import AgentClient

private struct ProjectionTransport: CapabilityTransport {
    let result: CapabilityResult
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse { CapabilityResponse(result: result) }
}
private func projectionClient(_ result: CapabilityResult) -> CapabilityClient { CapabilityClient(transport: ProjectionTransport(result: result)) }
private func projectionIdentity() throws -> OperationIdentity {
    OperationIdentity(selector: try OperationSelector(account: capabilityAccount(), operationID: "projection-operation"), requestKey: try RequestKey(String(repeating: "01", count: 16)))
}

@Test(arguments: [ReceiveOperationState.pending, .allocated, .closed])
func capabilityReceiveProjectionRepresentsDurablePendingAllocationAndClosure(_ state: ReceiveOperationState) async throws {
    let identity = try projectionIdentity()
    let value = ReceiveOperation(identity: identity, state: state,
        allocation: state == .allocated ? ReceiveAllocationProjection(address: "bitcoincash:qsynthetic", index: 19) : nil,
        closeReason: state == .closed ? .cancelled : nil, blocker: state == .pending ? .networkUnavailable : nil)
    let call = CapabilityCall.getOperation(.operation(identity.selector))
    guard case .getOperation(.receive(let response)) = try await projectionClient(.getOperation(.receive(value))).call(call) else { throw CapabilityFailure.invalidResponse }
    #expect(response.state == state)
    #expect((response.allocation != nil) == (state == .allocated))
    #expect((response.closeReason != nil) == (state == .closed))
}

@Test func capabilityReceiveAndSyncRejectSuccessWithoutRequiredFacts() async throws {
    let identity = try projectionIdentity()
    let call = CapabilityCall.getOperation(.operation(identity.selector))
    let allocatedWithoutAddress = ReceiveOperation(identity: identity, state: .allocated, allocation: nil)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await projectionClient(.getOperation(.receive(allocatedWithoutAddress))).call(call) }
    let closedWithoutReason = ReceiveOperation(identity: identity, state: .closed, allocation: nil)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await projectionClient(.getOperation(.receive(closedWithoutReason))).call(call) }
    let pendingWithAddress = ReceiveOperation(identity: identity, state: .pending, allocation: ReceiveAllocationProjection(address: "address", index: 0))
    await #expect(throws: CapabilityFailure.invalidResponse) { try await projectionClient(.getOperation(.receive(pendingWithAddress))).call(call) }
    let completedWithoutObservation = SyncOperation(identity: identity, state: .completed, observation: nil)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await projectionClient(.getOperation(.synchronization(completedWithoutObservation))).call(call) }
    let pending = SyncOperation(identity: identity, state: .pending, observation: nil, blocker: .networkUnavailable)
    #expect(try await projectionClient(.getOperation(.synchronization(pending))).call(call) == .getOperation(.synchronization(pending)))
}

@Test func capabilityHistoricalClosureAndCurrentRestrictionRemainIndependentAfterOwnerReopen() async throws {
    let (_, result) = try capabilityFixture(.preparePayment)
    guard case .preparePayment(let base) = result else { throw CapabilityFailure.invalidResponse }
    let closure = PaymentClosureProjection(reason: .reconciledAccepted, evidenceRevision: 1, support: .unsupported)
    let evidence = PaymentEvidenceProjection(revision: 2, support: .unsupported)
    let ownerAttempt = RelayAttemptProjection(attemptID: "owner-attempt-4", number: 4, route: .owner, outcome: .admitted, admittedAt: 100)
    let reopened = PaymentOperation(identity: base.identity, request: base.request, state: .submitting, preview: base.preview,
        terminalReason: .reconciledAccepted, closures: [closure], accountRestriction: .held, liabilityUnresolved: true,
        blocker: .inconclusiveEvidence, evidence: evidence, ordinaryAdmissions: 3, latestAttempt: ownerAttempt, lastReconciliationAt: 99, observationSequence: 5)
    let call = CapabilityCall.getOperation(.operation(base.identity.selector))
    guard case .getOperation(.payment(let response)) = try await projectionClient(.getOperation(.payment(reopened))).call(call) else { throw CapabilityFailure.invalidResponse }
    #expect(response.state == .submitting && response.terminalReason == .reconciledAccepted)
    #expect(response.accountRestriction == .held && response.liabilityUnresolved && response.evidence.support == .unsupported)
    #expect(response.ordinaryAdmissions == 3 && response.latestAttempt?.route == .owner)
}

@Test func capabilityAdmissionCountAndMissingClosureReasonCannotMislead() async throws {
    let (_, result) = try capabilityFixture(.preparePayment)
    guard case .preparePayment(let base) = result else { throw CapabilityFailure.invalidResponse }
    let call = CapabilityCall.getOperation(.operation(base.identity.selector))
    let impossible = PaymentOperation(identity: base.identity, request: base.request, state: .uncertain, preview: base.preview,
        accountRestriction: .held, liabilityUnresolved: true, ordinaryAdmissions: 4)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await projectionClient(.getOperation(.payment(impossible))).call(call) }
    let unexplainedClosure = PaymentOperation(identity: base.identity, request: base.request, state: .closed, preview: base.preview)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await projectionClient(.getOperation(.payment(unexplainedClosure))).call(call) }
}

@Test func capabilityProvenanceFreshnessAndReadinessAreSeparateAndMissingTransactionFactsStayNil() async throws {
    let account = try capabilityAccount()
    let observation = SnapshotObservation(providerID: "provider-a", viewID: "view-a", chainTip: "opaque-tip", sequence: 4,
        observedAt: 100, generation: 2, fresh: true, complete: true)
    let blocked = AccountReadiness(state: .blocked, blockers: [.accountRestricted])
    let status = SyncStatusProjection(account: account, observation: observation, readiness: blocked)
    #expect(try await projectionClient(.getSyncStatus(status)).call(.getSyncStatus(account)) == .getSyncStatus(status))
    let contradictory = SyncStatusProjection(account: account, observation: observation, readiness: AccountReadiness(state: .ready, blockers: [.keyUnavailable]))
    await #expect(throws: CapabilityFailure.invalidResponse) { try await projectionClient(.getSyncStatus(contradictory)).call(.getSyncStatus(account)) }
    let transaction = TransactionSummary(transactionID: String(repeating: "ab", count: 32), deltaSatoshis: nil, confirmations: nil, height: 10, status: .confirmed)
    let decoded = try JSONDecoder().decode(TransactionSummary.self, from: JSONEncoder().encode(transaction))
    #expect(decoded.deltaSatoshis == nil && decoded.confirmations == nil && decoded.height == 10)
    let malformed = SnapshotObservation(providerID: "", viewID: "view-a", chainTip: "tip", sequence: 1, observedAt: 100, generation: 2, fresh: false, complete: false)
    await #expect(throws: CapabilityFailure.invalidResponse) {
        try await projectionClient(.getSyncStatus(SyncStatusProjection(account: account, observation: malformed))).call(.getSyncStatus(account))
    }
}

@Test func capabilityUTXOReservationDoesNotContainForeignOperationIdentity() throws {
    let summary = UTXOSummary(outpoint: Outpoint(transactionID: String(repeating: "ab", count: 32), outputIndex: 0), amountSatoshis: 1000, reservation: .otherOperation)
    let object = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
    #expect(object.contains("otherOperation") && !object.contains("operationID"))
    #expect(try JSONDecoder().decode(UTXOSummary.self, from: JSONEncoder().encode(summary)).reservation == .otherOperation)
}

@Test func capabilityMethodsRetainExactlyTwelveMethodsAndSixScopePredicates() {
    #expect(CapabilityMethod.allCases.count == 12)
    #expect(Set(IntegrationScope.allCases.map(\.rawValue)) == ["read", "sync", "receive", "prepare", "submit", "cancel"])
    #expect(CapabilityMethod.allCases.filter { $0.requiredScope == .read }.count == 7)
    #expect(CapabilityMethod.synchronizeAccount.requiredScope == .sync)
    #expect(CapabilityMethod.createReceiveRequest.requiredScope == .receive)
    #expect(CapabilityMethod.preparePayment.requiredScope == .prepare)
    #expect(CapabilityMethod.submitPayment.requiredScope == .submit)
    #expect(CapabilityMethod.cancelOperation.requiredScope == .cancel)
}
