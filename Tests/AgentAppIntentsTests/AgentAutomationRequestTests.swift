// AgentAutomationRequestTests.swift

@testable import AgentAppIntents
import AgentClient
import AgentValues
import Foundation
import Testing

private let requestWallet = try! WalletScope(walletID: "request-wallet", network: .chipnet)
private let requestAccount = try! AccountScope(wallet: requestWallet, accountID: "request-account")
private let requestObservation = SnapshotObservation(providerID: "provider", viewID: "view", chainTip: "tip", sequence: 3,
    observedAt: 100, generation: 1, fresh: false, complete: false)
private func requestBinding(scopes: [IntegrationScope] = IntegrationScope.allCases, grant: String = "grant", generation: UInt64 = 1,
                            credentialGeneration: UInt64 = 1) throws -> AgentAutomationBinding {
    try AgentAutomationBinding(wallet: requestWallet, integrationID: "apple-integration", grantID: grant,
        walletGeneration: generation, credentialGeneration: credentialGeneration, accountIDs: [requestAccount.accountID], scopes: scopes)
}
private func paymentDraft() throws -> AgentAutomationPaymentDraft {
    try AgentAutomationPaymentDraft(account: requestAccount, destinationAddress: "original-caller-spelling", amountSatoshis: 191,
        feeRateSatoshisPerByte: 2, expiresAt: 12_345)
}

private actor RequestAccess: AgentAutomationAccess {
    var current: AgentAutomationBinding
    let transport: RequestTransport
    var active = true
    var unlocked = true
    init(_ transport: RequestTransport, binding: AgentAutomationBinding) { self.transport = transport; self.current = binding }
    func isKnownUnlocked() async -> Bool { unlocked }
    func openSession() async throws -> AgentAutomationSession {
        AgentAutomationSession(binding: current, client: CapabilityClient(transport: transport))
    }
    func validate(binding: AgentAutomationBinding) async throws {
        guard unlocked else { throw AgentAutomationFailure.locked }
        guard active, binding == current else { throw AgentAutomationFailure.staleContext }
    }
    func change(_ value: AgentAutomationBinding) { current = value }
    func revoke() { active = false }
}

/// Storage double proves adapter ordering/correlation only; durable host storage has separate owning tests.
private actor RequestStore: AgentAutomationRequestStore {
    private var next: UInt64 = 1
    private var rows: [String: RetainedAgentAutomationRequest] = [:]
    private var failCreate = false
    private var failEnrichment = false
    private(set) var enrichments = 0
    func failNextCreate() { failCreate = true }
    func failNextEnrichment() { failEnrichment = true }
    func create(binding: AgentAutomationBinding, payload: AgentAutomationRequestPayload) async throws -> RetainedAgentAutomationRequest {
        if failCreate { failCreate = false; throw AgentAutomationFailure.requestUnavailable }
        let suffix = String(next, radix: 16)
        let handle = String(repeating: "0", count: 32 - suffix.count) + suffix
        let keySuffix = String(next + 4096, radix: 16)
        let key = try RequestKey(String(repeating: "0", count: 32 - keySuffix.count) + keySuffix)
        next += 1
        let value = try RetainedAgentAutomationRequest(handleID: handle, owner: .init(binding: binding), payload: payload, requestKey: key)
        rows[handle] = value; return value
    }
    func load(handleID: String, binding: AgentAutomationBinding) async throws -> RetainedAgentAutomationRequest {
        guard let value = rows[handleID] else { throw AgentAutomationFailure.requestUnavailable }; return value
    }
    func recordOperation(handleID: String, binding: AgentAutomationBinding, identity: OperationIdentity) async throws -> RetainedAgentAutomationRequest {
        if failEnrichment { failEnrichment = false; throw AgentAutomationFailure.localRetentionUnavailable }
        guard let old = rows[handleID], old.operation.map({ $0 == identity }) ?? true else { throw AgentAutomationFailure.invalidReference }
        let value = try RetainedAgentAutomationRequest(handleID: old.handleID, owner: old.owner, payload: old.payload,
            requestKey: old.requestKey, operation: identity)
        rows[handleID] = value; enrichments += 1; return value
    }
    func recent(binding: AgentAutomationBinding, limit: Int) async throws -> [RetainedAgentAutomationRequest] {
        Array(rows.values.sorted { $0.handleID < $1.handleID }.prefix(limit))
    }
    var count: Int { rows.count }
}

/// Service-shaped replies exercise the public client and adapter. They do not prove engine idempotency or payment policy.
private actor RequestTransport: CapabilityTransport {
    private(set) var calls: [CapabilityCall] = []
    private var operations: [String: OperationProjection] = [:]
    private var loseReply = false
    private var wrongSubmitKey = false
    private var holdReply = false
    private var replyHeld = false
    private var replyContinuation: CheckedContinuation<Void, Never>?
    func loseNextProducedReply() { loseReply = true }
    func mismatchNextSubmitKey() { wrongSubmitKey = true }
    func holdNextProducedReply() { holdReply = true }
    func waitUntilReplyHeld() async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
        while !replyHeld && clock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(replyHeld)
    }
    func releaseReply() { holdReply = false; replyContinuation?.resume(); replyContinuation = nil }
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        calls.append(request.call)
        let result: CapabilityResult
        switch request.call {
        case .listWallets:
            result = .listWallets(.init(items: [.init(scope: requestWallet)]))
        case .listAccounts:
            result = .listAccounts(.init(wallet: requestWallet, page: .init(items: [.init(scope: requestAccount)], nextCursor: "next-account-page")))
        case .getBalance(let account):
            result = .getBalance(.init(account: account, totalSatoshis: 191, observation: requestObservation,
                readiness: .init(state: .blocked, blockers: [.staleSnapshot])))
        case .getSyncStatus(let account):
            result = .getSyncStatus(.init(account: account, observation: requestObservation,
                readiness: .init(state: .blocked, blockers: [.staleSnapshot])))
        case .listTransactions(let page):
            result = .listTransactions(.init(account: page.account, observation: requestObservation,
                page: .init(items: [.init(transactionID: String(repeating: "a", count: 64), deltaSatoshis: nil, confirmations: nil)], nextCursor: "next-transaction-page")))
        case .listUTXOs(let page):
            result = .listUTXOs(.init(account: page.account, observation: requestObservation, page: .init(items: [
                .init(outpoint: .init(transactionID: String(repeating: "b", count: 64), outputIndex: 7), amountSatoshis: 191, reservation: .otherOperation)])))
        case .synchronizeAccount(let value):
            let identity = try identity(account: value.account, key: value.requestKey)
            let operation = SyncOperation(identity: identity, state: .completed, observation: requestObservation)
            operations[value.requestKey.value] = .synchronization(operation); result = .synchronizeAccount(operation)
        case .createReceiveRequest(let value):
            let identity = try identity(account: value.account, key: value.requestKey)
            let operation = ReceiveOperation(identity: identity, state: .allocated, allocation: .init(address: "service-allocation", index: 3))
            operations[value.requestKey.value] = .receive(operation); result = .createReceiveRequest(operation)
        case .preparePayment(let value):
            let operation: PaymentOperation
            if let cached = operations[value.requestKey.value], case .payment(let old) = cached { operation = old }
            else {
                let normalized = try PreparePaymentRequest(account: value.account, requestKey: value.requestKey,
                    destinationAddress: "service-normalized-spelling", amountSatoshis: value.amountSatoshis,
                    feeRateSatoshisPerByte: value.feeRateSatoshisPerByte, expiresAt: value.expiresAt)
                operation = PaymentOperation(identity: try identity(account: value.account, key: value.requestKey), request: normalized,
                    state: .prepared, preview: preview(amount: value.amountSatoshis))
                operations[value.requestKey.value] = .payment(operation)
            }
            result = .preparePayment(operation)
        case .submitPayment(let selector):
            guard let cached = operations.values.first(where: { $0.identity.selector == selector }), case .payment(let old) = cached else { throw ServiceProblem(.unavailable) }
            let key = wrongSubmitKey ? try RequestKey(String(repeating: "f", count: 32)) : old.identity.requestKey
            wrongSubmitKey = false
            let identity = OperationIdentity(selector: selector, requestKey: key)
            let draft = try PreparePaymentRequest(account: old.request.account, requestKey: key, destinationAddress: old.request.destinationAddress,
                amountSatoshis: old.request.amountSatoshis, feeRateSatoshisPerByte: old.request.feeRateSatoshisPerByte, expiresAt: old.request.expiresAt)
            result = .submitPayment(.init(identity: identity, request: draft, state: .uncertain, preview: old.preview,
                accountRestriction: .held, liabilityUnresolved: true, blocker: .relayNotEligible, ordinaryAdmissions: 1,
                latestAttempt: .init(attemptID: "attempt", number: 1, route: .ordinary, outcome: .unknown, admittedAt: 100, nextEligibleAt: 130)))
        case .getOperation(let lookup):
            let operation: OperationProjection?
            switch lookup {
            case .request(_, _, let key): operation = operations[key.value]
            case .operation(let selector): operation = operations.values.first { $0.identity.selector == selector }
            }
            guard let operation else { throw ServiceProblem(.unavailable) }; result = .getOperation(operation)
        case .cancelOperation(let selector):
            guard let cached = operations.values.first(where: { $0.identity.selector == selector }), case .payment(let old) = cached else { throw ServiceProblem(.unavailable) }
            result = .cancelOperation(.payment(.init(identity: old.identity, request: old.request, state: .closed,
                preview: old.preview, terminalReason: .cancelled)))
        }
        if holdReply { replyHeld = true; await withCheckedContinuation { replyContinuation = $0 } }
        if loseReply { loseReply = false; throw ClientFailure.unavailable }
        return CapabilityResponse(result: result)
    }
    private func identity(account: AccountScope, key: RequestKey) throws -> OperationIdentity {
        OperationIdentity(selector: try OperationSelector(account: account, operationID: "operation-" + key.value), requestKey: key)
    }
    private func preview(amount: Int64) -> PaymentPreviewProjection {
        .init(canonicalDestinationAddress: "canonical-service-address", destinationScriptHex: "76", amountSatoshis: amount, feeSatoshis: 9,
            selectedInputs: [.init(transactionID: String(repeating: "c", count: 64), outputIndex: 0)], change: [],
            templateDigest: String(repeating: "d", count: 64), leaseDeadline: 500)
    }
}

private actor RequestNavigator: AgentAutomationReviewNavigator {
    private(set) var requests: [AgentAutomationReviewRequest] = []
    var mismatch = false
    func setMismatch() { mismatch = true }
    func openReview(_ request: AgentAutomationReviewRequest) async throws -> AgentAutomationReviewAcknowledgment {
        requests.append(request)
        if mismatch {
            let foreign = try OperationSelector(account: request.operation.account, operationID: "other-operation")
            return .init(request: try .init(owner: request.owner, operation: foreign), routeAccepted: true)
        }
        return .init(request: request, routeAccepted: true)
    }
}

@Test func localNewMustPersistBeforeAnEffectAndConcurrentNewKeepsDistinctIntentions() async throws {
    let transport = RequestTransport(); let store = RequestStore()
    let access = RequestAccess(transport, binding: try requestBinding(scopes: [.prepare]))
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let payload = AgentAutomationRequestPayload.preparePayment(try paymentDraft())
    await store.failNextCreate()
    await #expect(throws: AgentAutomationFailure.requestUnavailable) { try await adapter.newRequest(payload) }
    #expect(await transport.calls.isEmpty)
    async let first = adapter.newRequest(payload)
    async let second = adapter.newRequest(payload)
    let values = try await [first, second]
    #expect(values[0].handleID != values[1].handleID && values[0].requestKey != values[1].requestKey)
    #expect(await transport.calls.isEmpty)
    _ = try await adapter.execute(handleID: values[0].handleID, effect: .preparePayment)
    _ = try await adapter.execute(handleID: values[0].handleID, effect: .preparePayment)
    let calls = await transport.calls
    #expect(calls.count == 2 && calls.allSatisfy { $0.method == .preparePayment })
    let storedCount = await store.count
    #expect(calls[0] == calls[1] && storedCount == 2)
}

@Test func producedReplyLossUsesTheRetainedKeyForExplicitObservationWithoutAutomaticRetry() async throws {
    let transport = RequestTransport(); let store = RequestStore()
    let access = RequestAccess(transport, binding: try requestBinding())
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let retained = try await adapter.newRequest(.preparePayment(paymentDraft()))
    await transport.loseNextProducedReply()
    await #expect(throws: ClientFailure.unavailable) { try await adapter.execute(handleID: retained.handleID, effect: .preparePayment) }
    #expect(await transport.calls.count == 1)
    let old = try await store.load(handleID: retained.handleID, binding: requestBinding())
    #expect(old.operation == nil && old.requestKey == retained.requestKey)
    let result = try await adapter.resume(handleID: retained.handleID)
    #expect(result.identity.requestKey == retained.requestKey)
    let calls = await transport.calls
    #expect(calls.count == 2 && calls[1] == .getOperation(.request(account: requestAccount, effect: .preparePayment, key: retained.requestKey)))
    #expect(await store.count == 1)
}

@Test func enrichmentLossReplaysOriginalTypedPayloadUnderCommandScopeWithoutRead() async throws {
    let transport = RequestTransport(); let store = RequestStore()
    let binding = try requestBinding(scopes: [.prepare]); let access = RequestAccess(transport, binding: binding)
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let retained = try await adapter.newRequest(.preparePayment(paymentDraft()))
    await store.failNextEnrichment()
    await #expect(throws: AgentAutomationFailure.localRetentionUnavailable) { try await adapter.execute(handleID: retained.handleID, effect: .preparePayment) }
    let result = try await adapter.execute(handleID: retained.handleID, effect: .preparePayment)
    let row = try await store.load(handleID: retained.handleID, binding: binding)
    #expect(row.payload == retained.payload && row.requestKey == retained.requestKey && row.operation == result.identity)
    let calls = await transport.calls
    #expect(calls.count == 2 && calls[0] == calls[1] && calls.allSatisfy { $0.method == .preparePayment })
    if case .preparePayment(let request) = calls[0] {
        #expect(request.destinationAddress == "original-caller-spelling" && request.amountSatoshis == 191)
        #expect(request.feeRateSatoshisPerByte == 2 && request.expiresAt == 12_345)
    } else { Issue.record("Expected the retained preparation command.") }
    await #expect(throws: AgentAutomationFailure.scopeDenied) { try await adapter.retainedRequests() }
    #expect(await transport.calls.count == 2)
}

@Test(arguments: [EffectKind.synchronizeAccount, .createReceiveRequest])
private func eachInitialCommandUsesOnlyItsOwnScopeAndTerminalSyncDoesNotBecomeARefresh(_ effect: EffectKind) async throws {
    let transport = RequestTransport(); let store = RequestStore()
    let scope: IntegrationScope = effect == .synchronizeAccount ? .sync : .receive
    let access = RequestAccess(transport, binding: try requestBinding(scopes: [scope]))
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let payload: AgentAutomationRequestPayload = effect == .synchronizeAccount ? .synchronizeAccount(requestAccount) : .createReceiveRequest(requestAccount)
    let retained = try await adapter.newRequest(payload)
    let first = try await adapter.execute(handleID: retained.handleID, effect: effect)
    let replay = try await adapter.execute(handleID: retained.handleID, effect: effect)
    #expect(first == replay)
    let calls = await transport.calls
    #expect(calls.count == 2 && calls[0] == calls[1])
    #expect(calls.allSatisfy { $0.method == (effect == .synchronizeAccount ? .synchronizeAccount : .createReceiveRequest) })
}

@Test func submitAndCancelUseRetainedSelectorsWithIndependentScopesAndRejectChangedKeys() async throws {
    let transport = RequestTransport(); let store = RequestStore(); let access = RequestAccess(transport, binding: try requestBinding())
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let cancellation = try await adapter.newRequest(.preparePayment(paymentDraft()))
    _ = try await adapter.execute(handleID: cancellation.handleID, effect: .preparePayment)
    await access.change(try requestBinding(scopes: [.cancel]))
    let cancelled = try await adapter.cancel(handleID: cancellation.handleID)
    if case .payment(let value) = cancelled { #expect(value.state == .closed && value.terminalReason == .cancelled) }
    else { Issue.record("Expected the cancellation command's direct payment result.") }
    await access.change(try requestBinding(scopes: [.prepare]))
    let submission = try await adapter.newRequest(.preparePayment(paymentDraft()))
    _ = try await adapter.execute(handleID: submission.handleID, effect: .preparePayment)
    await access.change(try requestBinding(scopes: [.submit]))
    await transport.mismatchNextSubmitKey()
    await #expect(throws: AgentAutomationFailure.invalidResponse) { try await adapter.submit(handleID: submission.handleID) }
    let result = try await adapter.submit(handleID: submission.handleID)
    #expect(result.state == .uncertain && result.identity.requestKey == submission.requestKey)
    let calls = await transport.calls
    #expect(calls.map(\.method) == [.preparePayment, .cancelOperation, .preparePayment, .submitPayment, .submitPayment])
}

private enum OwnerChange: Sendable { case rotation, replacement, recovery }
@Test(arguments: [OwnerChange.rotation, .replacement, .recovery])
private func persistentHandleOwnerSeparatesRotationFromReplacementAndRecovery(_ change: OwnerChange) async throws {
    let transport = RequestTransport(); let store = RequestStore(); let access = RequestAccess(transport, binding: try requestBinding())
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let retained = try await adapter.newRequest(.preparePayment(paymentDraft()))
    _ = try await adapter.execute(handleID: retained.handleID, effect: .preparePayment)
    switch change {
    case .rotation: await access.change(try requestBinding(credentialGeneration: 2))
    case .replacement: await access.change(try requestBinding(grant: "replacement-grant"))
    case .recovery: await access.change(try requestBinding(generation: 2))
    }
    if case .rotation = change {
        let observed = try await adapter.resume(handleID: retained.handleID)
        #expect(observed.identity.requestKey == retained.requestKey)
        #expect(await transport.calls.count == 2)
    } else {
        await #expect(throws: AgentAutomationFailure.staleContext) { try await adapter.resume(handleID: retained.handleID) }
        #expect(await transport.calls.count == 1)
    }
}

@Test func exactReviewHandoffReturnsOnlyMatchingNavigationAcknowledgment() async throws {
    let transport = RequestTransport(); let store = RequestStore(); let navigator = RequestNavigator()
    let access = RequestAccess(transport, binding: try requestBinding())
    let adapter = AgentAutomationAdapter(access: access, requests: store, reviewNavigator: navigator)
    let retained = try await adapter.newRequest(.preparePayment(paymentDraft()))
    let operation = try await adapter.execute(handleID: retained.handleID, effect: .preparePayment)
    let result = try await adapter.openReview(handleID: retained.handleID)
    #expect(result.routeAccepted && result.request.operation == operation.identity.selector)
    #expect(result.request.owner == retained.owner)
    #expect(await transport.calls.count == 1)
    await navigator.setMismatch()
    await #expect(throws: AgentAutomationFailure.invalidResponse) { try await adapter.openReview(handleID: retained.handleID) }
    #expect(await transport.calls.count == 1)
}

@Test func boundedAdvancedReadsPreserveUnknownFactsAndRedactedReservations() async throws {
    let transport = RequestTransport(); let store = RequestStore(); let access = RequestAccess(transport, binding: try requestBinding(scopes: [.read]))
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let directory = try await adapter.accountDirectory(page: PageRequest(limit: 1))
    let account = try #require(directory.accounts.first)
    #expect(directory.nextCursor == "next-account-page")
    _ = try await adapter.wallets(page: PageRequest(limit: 1))
    let balance = try await adapter.balance(accountID: account.id)
    #expect(balance.totalSatoshis == 191 && !balance.observation.fresh && !balance.observation.complete)
    _ = try await adapter.syncStatus(accountID: account.id)
    let transactions = try await adapter.transactions(accountID: account.id, page: PageRequest(limit: 1))
    let activity = try AgentActivityPageSnapshot(accountID: account.id, value: transactions)
    #expect(activity.nextCursor == "next-transaction-page" && activity.transactions.first?.deltaSatoshis == nil)
    #expect(activity.transactions.first?.confirmations == nil && activity.transactions.first?.status == "unknown")
    let utxos = try await adapter.utxos(accountID: account.id, page: PageRequest(limit: 1))
    let output = try AgentUTXOPageSnapshot(accountID: account.id, value: utxos)
    #expect(output.utxos.first?.amountSatoshis == 191 && output.utxos.first?.outputIndex == 7)
    #expect(output.utxos.first?.reservation == "otherOperation" && output.utxos.first?.visibleOperationID == nil)
    let beforeRender = await transport.calls.count
    _ = activity.displayRepresentation; _ = output.displayRepresentation
    #expect(await transport.calls.count == beforeRender)
    let calls = await transport.calls
    #expect(calls.map(\.method) == [.listAccounts, .listWallets, .getBalance, .getSyncStatus, .listTransactions, .listUTXOs])
}

@Test func strictLocalRecordDecodingCannotIntroduceAnotherEffectOrForeignIdentity() throws {
    let binding = try requestBinding()
    let value = try RetainedAgentAutomationRequest(handleID: String(repeating: "1", count: 32), owner: .init(binding: binding),
        payload: .preparePayment(paymentDraft()), requestKey: RequestKey(String(repeating: "2", count: 32)))
    var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    fields["ownerAuthority"] = true
    let extra = try JSONSerialization.data(withJSONObject: fields)
    #expect(throws: AgentAutomationFailure.invalidReference) { try JSONDecoder().decode(RetainedAgentAutomationRequest.self, from: extra) }
    var mixed = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentAutomationRequestPayload.synchronizeAccount(requestAccount))) as? [String: Any])
    mixed["payment"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(paymentDraft()))
    let mixedBytes = try JSONSerialization.data(withJSONObject: mixed)
    #expect(throws: AgentAutomationFailure.invalidReference) { try JSONDecoder().decode(AgentAutomationRequestPayload.self, from: mixedBytes) }
    let other = try AccountScope(wallet: requestWallet, accountID: "foreign-account")
    let identity = OperationIdentity(selector: try OperationSelector(account: other, operationID: "operation"), requestKey: value.requestKey)
    #expect(throws: AgentAutomationFailure.invalidReference) {
        try RetainedAgentAutomationRequest(handleID: value.handleID, owner: value.owner, payload: value.payload, requestKey: value.requestKey, operation: identity)
    }
}

@Test func missingRetainedMetadataNeverCreatesAReplacementOrCallsTheService() async throws {
    let transport = RequestTransport(); let store = RequestStore(); let access = RequestAccess(transport, binding: try requestBinding())
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let missing = String(repeating: "e", count: 32)
    await #expect(throws: AgentAutomationFailure.requestUnavailable) { try await adapter.execute(handleID: missing, effect: .preparePayment) }
    await #expect(throws: AgentAutomationFailure.requestUnavailable) { try await adapter.resume(handleID: missing) }
    await #expect(throws: AgentAutomationFailure.requestUnavailable) { try await adapter.submit(handleID: missing) }
    await #expect(throws: AgentAutomationFailure.requestUnavailable) { try await adapter.cancel(handleID: missing) }
    #expect(await store.count == 0)
    #expect(await transport.calls.isEmpty)
}

@Test func revocationDuringAProducedCommandReplyPreventsEnrichmentAndDisclosure() async throws {
    let transport = RequestTransport(); let store = RequestStore(); let access = RequestAccess(transport, binding: try requestBinding())
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let retained = try await adapter.newRequest(.preparePayment(paymentDraft()))
    await transport.holdNextProducedReply()
    let operation = Task { try await adapter.execute(handleID: retained.handleID, effect: .preparePayment) }
    do {
        try await transport.waitUntilReplyHeld()
        await access.revoke(); await transport.releaseReply()
        await #expect(throws: AgentAutomationFailure.staleContext) { try await operation.value }
        #expect(await store.enrichments == 0)
        #expect(await transport.calls.count == 1)
    } catch {
        await transport.releaseReply(); _ = await operation.result; throw error
    }
}

@Test func typedPaymentOutputPreservesUncertaintyAndUnknownEvidenceWithoutAReadOrRenderEffect() async throws {
    let transport = RequestTransport(); let store = RequestStore(); let access = RequestAccess(transport, binding: try requestBinding())
    let adapter = AgentAutomationAdapter(access: access, requests: store)
    let retained = try await adapter.newRequest(.preparePayment(paymentDraft()))
    _ = try await adapter.execute(handleID: retained.handleID, effect: .preparePayment)
    let result = try await adapter.submit(handleID: retained.handleID)
    let output = try AgentOperationSnapshot(handleID: retained.handleID, operation: .payment(result))
    #expect(output.payment?.id == retained.handleID && output.request?.id == retained.handleID)
    #expect(output.state == "uncertain" && output.accountRestriction == "held" && output.liabilityUnresolved == true)
    #expect(output.amountSatoshis == 191 && output.feeSatoshis == 9 && output.feeRateSatoshisPerByte == 2)
    #expect(output.canonicalDestinationAddress == "canonical-service-address" && output.expiresAt == 12_345)
    #expect(output.ordinaryAdmissions == 1 && output.latestAttemptOutcome == "unknown" && output.nextEligibleAt == 130)
    #expect(output.evidenceSupport == "unknown" && output.fresh == nil && output.observedAt == nil && output.transactionID == nil)
    _ = output.displayRepresentation
    #expect(await transport.calls.map(\.method) == [.preparePayment, .submitPayment])
}
