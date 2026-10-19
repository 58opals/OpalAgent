// AgentAutomationAdapter.swift

import AgentClient
import AgentValues
import Foundation

/// Explicit one-call mappings. The host retains identity; the service owns operation state and every effect.
public struct AgentAutomationAdapter: Sendable {
    private let access: any AgentAutomationAccess
    private let requests: any AgentAutomationRequestStore
    private let navigator: any AgentAutomationReviewNavigator
    public init(access: any AgentAutomationAccess = UnavailableAgentAutomationAccess(),
                requests: any AgentAutomationRequestStore = UnavailableAgentAutomationRequestStore(),
                reviewNavigator: any AgentAutomationReviewNavigator = UnavailableAgentAutomationReviewNavigator()) {
        self.access = access; self.requests = requests; self.navigator = reviewNavigator
    }
    public init(dependency: AgentAutomationDependency) {
        self.init(access: dependency.access, requests: dependency.requests, reviewNavigator: dependency.reviewNavigator)
    }

    /// Local persistence only. This never calls the capability service.
    public func newRequest(_ payload: AgentAutomationRequestPayload) async throws -> RetainedAgentAutomationRequest {
        let session = try await begin()
        try check(account: payload.account, binding: session.binding)
        let value = try await requests.create(binding: session.binding, payload: payload)
        try check(value, binding: session.binding)
        guard value.payload == payload, value.operation == nil else { throw AgentAutomationFailure.invalidResponse }
        try await finish(session.binding)
        return value
    }
    public func newRequest(accountID: String, effect: EffectKind) async throws -> RetainedAgentAutomationRequest {
        let session = try await begin()
        let account = try account(accountID, binding: session.binding)
        let payload: AgentAutomationRequestPayload
        switch effect {
        case .synchronizeAccount: payload = .synchronizeAccount(account)
        case .createReceiveRequest: payload = .createReceiveRequest(account)
        case .preparePayment: throw AgentAutomationFailure.invalidReference
        }
        let value = try await requests.create(binding: session.binding, payload: payload)
        try check(value, binding: session.binding)
        guard value.payload == payload, value.operation == nil else { throw AgentAutomationFailure.invalidResponse }
        try await finish(session.binding)
        return value
    }
    public func newPaymentRequest(accountID: String, destinationAddress: String, amountSatoshis: Int64,
                                  feeRateSatoshisPerByte: Int64 = 1, expiresAt: Int64? = nil) async throws -> RetainedAgentAutomationRequest {
        let session = try await begin()
        let draft = try AgentAutomationPaymentDraft(account: account(accountID, binding: session.binding),
            destinationAddress: destinationAddress, amountSatoshis: amountSatoshis,
            feeRateSatoshisPerByte: feeRateSatoshisPerByte, expiresAt: expiresAt)
        let value = try await requests.create(binding: session.binding, payload: .preparePayment(draft))
        try check(value, binding: session.binding)
        guard value.payload == .preparePayment(draft), value.operation == nil else { throw AgentAutomationFailure.invalidResponse }
        try await finish(session.binding)
        return value
    }

    /// Deliberately repeats the original command under its own command scope, with the original key and typed payload.
    public func execute(handleID: String, effect: EffectKind) async throws -> OperationProjection {
        let session = try await begin()
        let retained = try await load(handleID, binding: session.binding)
        guard retained.payload.effect == effect else { throw AgentAutomationFailure.invalidReference }
        let call: CapabilityCall
        switch retained.payload {
        case .synchronizeAccount(let account): call = .synchronizeAccount(.init(account: account, requestKey: retained.requestKey))
        case .createReceiveRequest(let account): call = .createReceiveRequest(.init(account: account, requestKey: retained.requestKey))
        case .preparePayment(let draft):
            call = .preparePayment(try PreparePaymentRequest(account: draft.account, requestKey: retained.requestKey,
                destinationAddress: draft.destinationAddress, amountSatoshis: draft.amountSatoshis,
                feeRateSatoshisPerByte: draft.feeRateSatoshisPerByte, expiresAt: draft.expiresAt))
        }
        try require(call.method.requiredScope, session.binding)
        try await finish(session.binding)
        let result = try await session.client.call(call)
        let operation: OperationProjection
        switch result {
        case .synchronizeAccount(let value): operation = .synchronization(value)
        case .createReceiveRequest(let value): operation = .receive(value)
        case .preparePayment(let value): operation = .payment(value)
        default: throw AgentAutomationFailure.invalidResponse
        }
        try await accept(operation, retained: retained, binding: session.binding)
        return operation
    }
    /// Observation only. A terminal synchronization result remains the original result, not a fresh synchronization.
    public func resume(handleID: String) async throws -> OperationProjection {
        let session = try await begin(required: .read)
        let retained = try await load(handleID, binding: session.binding)
        guard case .getOperation(let value) = try await session.client.call(.getOperation(.request(
            account: retained.payload.account, effect: retained.payload.effect, key: retained.requestKey))) else {
            throw AgentAutomationFailure.invalidResponse
        }
        try await accept(value, retained: retained, binding: session.binding)
        return value
    }
    public func submit(handleID: String) async throws -> PaymentOperation {
        let session = try await begin(required: .submit)
        let retained = try await load(handleID, binding: session.binding)
        guard retained.payload.effect == .preparePayment, let operation = retained.operation else {
            throw AgentAutomationFailure.requestUnavailable
        }
        try await finish(session.binding)
        guard case .submitPayment(let value) = try await session.client.call(.submitPayment(operation.selector)) else {
            throw AgentAutomationFailure.invalidResponse
        }
        try await accept(.payment(value), retained: retained, binding: session.binding)
        return value
    }
    public func cancel(handleID: String) async throws -> OperationProjection {
        let session = try await begin(required: .cancel)
        let retained = try await load(handleID, binding: session.binding)
        guard let operation = retained.operation else { throw AgentAutomationFailure.requestUnavailable }
        try await finish(session.binding)
        guard case .cancelOperation(let value) = try await session.client.call(.cancelOperation(operation.selector)) else {
            throw AgentAutomationFailure.invalidResponse
        }
        try await accept(value, retained: retained, binding: session.binding)
        return value
    }
    /// Navigates only to this integration's retained selector. It returns no owner observation, approval or reusable proof.
    public func openReview(handleID: String) async throws -> AgentAutomationReviewAcknowledgment {
        let session = try await begin(required: .read)
        let retained = try await load(handleID, binding: session.binding)
        guard let operation = retained.operation else { throw AgentAutomationFailure.requestUnavailable }
        guard retained.payload.effect == .preparePayment else { throw AgentAutomationFailure.invalidReference }
        let request = try AgentAutomationReviewRequest(owner: retained.owner, operation: operation.selector)
        try await finish(session.binding)
        let result = try await navigator.openReview(request)
        guard result.routeAccepted, result.request == request else { throw AgentAutomationFailure.invalidResponse }
        try await finish(session.binding)
        return result
    }

    /// Neutral local references only. No service operation lookup or financial projection is performed.
    public func retainedRequests(identifiers: [String]? = nil, effect: EffectKind? = nil) async throws -> [RetainedAgentAutomationRequest] {
        let session = try await begin(required: .read)
        let values: [RetainedAgentAutomationRequest]
        if let identifiers {
            guard identifiers.count <= 40, Set(identifiers).count == identifiers.count,
                  identifiers.allSatisfy(automationHandleID) else { throw AgentAutomationFailure.invalidReference }
            var result: [RetainedAgentAutomationRequest] = []
            for id in identifiers {
                do { result.append(try await load(id, binding: session.binding)) }
                catch AgentAutomationFailure.requestUnavailable { continue }
            }
            values = result
        } else {
            values = try await requests.recent(binding: session.binding, limit: 40)
            guard values.count <= 40, Set(values.map(\.handleID)).count == values.count else { throw AgentAutomationFailure.invalidResponse }
            for value in values { try check(value, binding: session.binding) }
        }
        try await finish(session.binding)
        return values.filter { effect == nil || $0.payload.effect == effect }
    }

    public func wallets(page: PageRequest) async throws -> CapabilityPage<WalletSummary> {
        let session = try await begin(required: .read)
        guard case .listWallets(let value) = try await session.client.call(.listWallets(page)),
              value.items.allSatisfy({ $0.scope == session.binding.wallet }) else { throw AgentAutomationFailure.invalidResponse }
        try await finish(session.binding); return value
    }
    public func accountPage(page: PageRequest) async throws -> AccountList {
        let session = try await begin(required: .read)
        guard case .listAccounts(let value) = try await session.client.call(.listAccounts(.init(wallet: session.binding.wallet, page: page))) else {
            throw AgentAutomationFailure.invalidResponse
        }
        for item in value.page.items { try check(account: item.scope, binding: session.binding) }
        try await finish(session.binding); return value
    }
    public func accountDirectory(page: PageRequest) async throws -> AgentAccountDirectorySnapshot {
        let session = try await begin(required: .read)
        guard case .listAccounts(let value) = try await session.client.call(.listAccounts(.init(wallet: session.binding.wallet, page: page))) else {
            throw AgentAutomationFailure.invalidResponse
        }
        let accounts = try value.page.items.map { item in
            try check(account: item.scope, binding: session.binding)
            return AgentAccountEntity(id: try automationAccountID(binding: session.binding, account: item.scope), network: item.scope.wallet.network.rawValue)
        }
        let result = AgentAccountDirectorySnapshot(accounts: accounts, nextCursor: value.page.nextCursor)
        try await finish(session.binding); return result
    }
    public func balance(accountID: String) async throws -> BalanceProjection {
        let session = try await begin(required: .read)
        guard case .getBalance(let value) = try await session.client.call(.getBalance(account(accountID, binding: session.binding))) else {
            throw AgentAutomationFailure.invalidResponse
        }
        try await finish(session.binding); return value
    }
    public func syncStatus(accountID: String) async throws -> SyncStatusProjection {
        let session = try await begin(required: .read)
        guard case .getSyncStatus(let value) = try await session.client.call(.getSyncStatus(account(accountID, binding: session.binding))) else {
            throw AgentAutomationFailure.invalidResponse
        }
        try await finish(session.binding); return value
    }
    public func transactions(accountID: String, page: PageRequest) async throws -> AccountPage<TransactionSummary> {
        let session = try await begin(required: .read)
        guard case .listTransactions(let value) = try await session.client.call(.listTransactions(.init(account: account(accountID, binding: session.binding), page: page))) else {
            throw AgentAutomationFailure.invalidResponse
        }
        try await finish(session.binding); return value
    }
    public func utxos(accountID: String, page: PageRequest) async throws -> AccountPage<UTXOSummary> {
        let session = try await begin(required: .read)
        guard case .listUTXOs(let value) = try await session.client.call(.listUTXOs(.init(account: account(accountID, binding: session.binding), page: page))) else {
            throw AgentAutomationFailure.invalidResponse
        }
        try await finish(session.binding); return value
    }

    private func begin(required scope: IntegrationScope? = nil) async throws -> AgentAutomationSession {
        guard await access.isKnownUnlocked() else { throw AgentAutomationFailure.locked }
        let session = try await access.openSession()
        if let scope { try require(scope, session.binding) }
        try await finish(session.binding); return session
    }
    private func finish(_ binding: AgentAutomationBinding) async throws {
        try Task.checkCancellation()
        guard await access.isKnownUnlocked() else { throw AgentAutomationFailure.locked }
        try await access.validate(binding: binding)
    }
    private func require(_ scope: IntegrationScope, _ binding: AgentAutomationBinding) throws {
        guard binding.scopes.contains(scope) else { throw AgentAutomationFailure.scopeDenied }
    }
    private func check(account: AccountScope, binding: AgentAutomationBinding) throws {
        guard account.wallet == binding.wallet, binding.accountIDs.contains(account.accountID) else { throw AgentAutomationFailure.invalidReference }
    }
    private func account(_ identifier: String, binding: AgentAutomationBinding) throws -> AccountScope {
        guard automationIdentifier(identifier) else { throw AgentAutomationFailure.invalidReference }
        for id in binding.accountIDs {
            let scope = try AccountScope(wallet: binding.wallet, accountID: id)
            if try automationAccountID(binding: binding, account: scope) == identifier { return scope }
        }
        throw AgentAutomationFailure.invalidReference
    }
    private func check(_ retained: RetainedAgentAutomationRequest, binding: AgentAutomationBinding) throws {
        guard retained.owner == AgentAutomationRequestOwner(binding: binding) else { throw AgentAutomationFailure.staleContext }
        try check(account: retained.payload.account, binding: binding)
    }
    private func load(_ id: String, binding: AgentAutomationBinding) async throws -> RetainedAgentAutomationRequest {
        guard automationHandleID(id) else { throw AgentAutomationFailure.invalidReference }
        let result = try await requests.load(handleID: id, binding: binding)
        guard result.handleID == id else { throw AgentAutomationFailure.invalidResponse }
        try check(result, binding: binding); return result
    }
    private func accept(_ operation: OperationProjection, retained: RetainedAgentAutomationRequest, binding: AgentAutomationBinding) async throws {
        guard operation.effect == retained.payload.effect, operation.identity.requestKey == retained.requestKey,
              operation.identity.selector.account == retained.payload.account,
              retained.operation.map({ $0 == operation.identity }) ?? true else { throw AgentAutomationFailure.invalidResponse }
        if case .preparePayment(let draft) = retained.payload {
            guard case .payment(let payment) = operation, payment.request.amountSatoshis == draft.amountSatoshis,
                  payment.request.feeRateSatoshisPerByte == draft.feeRateSatoshisPerByte,
                  payment.request.expiresAt == draft.expiresAt else { throw AgentAutomationFailure.invalidResponse }
        }
        try await finish(binding)
        let enriched: RetainedAgentAutomationRequest
        do { enriched = try await requests.recordOperation(handleID: retained.handleID, binding: binding, identity: operation.identity) }
        catch { throw AgentAutomationFailure.localRetentionUnavailable }
        guard enriched.handleID == retained.handleID, enriched.owner == retained.owner, enriched.payload == retained.payload,
              enriched.requestKey == retained.requestKey, enriched.operation == operation.identity else { throw AgentAutomationFailure.invalidResponse }
        try await finish(binding)
    }
}
