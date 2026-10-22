import AgentValues
import Foundation
import OpalBaseCore

/// Constructed by a trusted connection adapter after peer validation and authentication.
/// None of these authority facts are decoded from a capability request.
struct CapabilityConnectionContext: Sendable {
    let session: AuthorizationSession
    let connectionID: String
    let peer: PeerEvidence
}

/// The integration endpoint owns dispatch and safe disclosure; engines own durable effects.
final class CapabilityService: Sendable {
    private let continuity: ContinuityCoordinator
    private let policy: AuthorityPolicy
    private let payments: PaymentEngine
    private let receives: ReceiveEngine
    private let clock: any PaymentClock
    private let availability: @Sendable (AccountScope) -> AccountReadiness

    /// Availability reads captured runtime facts only: no key access, refresh, or other effects.
    init(continuity: ContinuityCoordinator, policy: AuthorityPolicy, payments: PaymentEngine,
         receives: ReceiveEngine, clock: any PaymentClock = SystemPaymentClock(),
         availability: @escaping @Sendable (AccountScope) -> AccountReadiness = { _ in .unavailable }) {
        self.continuity = continuity; self.policy = policy; self.payments = payments
        self.receives = receives; self.clock = clock; self.availability = availability
    }

    func handle(_ request: CapabilityRequest, context: CapabilityConnectionContext) async throws -> CapabilityResponse {
        do {
            guard request.protocolVersion == ServiceStatus.currentProtocolVersion else { throw ServiceProblem(.invalidRequest) }
            return CapabilityResponse(result: try await dispatch(request.call, context: context))
        } catch { throw Self.problem(error) }
    }

    private func dispatch(_ call: CapabilityCall, context: CapabilityConnectionContext) async throws -> CapabilityResult {
        switch call {
        case .listWallets(let page):
            return .listWallets(try current { state in
                let accounts = try visibleAccounts(state, context: context)
                let items = accounts.isEmpty ? [] : [WalletSummary(scope: accounts[0].wallet, availability: .enabled)]
                return try paginate(items, page: page, category: "wallets", account: nil, sequence: nil,
                                    state: state, context: context, identity: { $0.scope.walletID })
            })
        case .listAccounts(let request):
            return .listAccounts(try current { state in
                let accounts = try visibleAccounts(state, context: context)
                guard request.wallet.walletID == state.authorization.walletID,
                      request.wallet.network.rawValue == state.authorization.network else { throw ServiceProblem(.unavailable) }
                let items = accounts.map { AccountSummary(scope: $0, readiness: readiness(state, account: $0)) }
                return AccountList(wallet: request.wallet, page: try paginate(items, page: request.page,
                    category: "accounts", account: nil, sequence: nil, state: state, context: context,
                    identity: { $0.scope.accountID }))
            })
        case .getBalance(let account):
            return .getBalance(try read(account, context: context) { state in
                let record = try cached(state, account: account)
                guard let balance = record.balance else { throw ServiceProblem(.unavailable) }
                return BalanceProjection(account: account, totalSatoshis: balance,
                    observation: Self.observation(record, generation: state.authorization.generation),
                    readiness: readiness(state, account: account))
            })
        case .listTransactions(let request):
            return .listTransactions(try read(request.account, context: context) { state in
                let record = try cached(state, account: request.account)
                let snapshot = try JSONDecoder().decode(OpalBase.Account.Snapshot.self, from: record.snapshot)
                let items = try snapshot.addressBook.transactions.map {
                    TransactionSummary(transactionID: try Self.snapshotTransactionID($0.transactionHash), deltaSatoshis: nil, confirmations: nil,
                        height: $0.confirmationHeight.flatMap(UInt32.init(exactly:)),
                        status: TransactionStatus(rawValue: $0.status.rawValue) ?? .unknown)
                }.sorted { $0.transactionID < $1.transactionID }
                guard Set(items.map(\.transactionID)).count == items.count else { throw ServiceProblem(.unavailable) }
                return AccountPage(account: request.account,
                    observation: Self.observation(record, generation: state.authorization.generation),
                    page: try paginate(items, page: request.page, category: "transactions", account: request.account,
                        sequence: record.sequence, state: state, context: context, identity: \.transactionID),
                    readiness: readiness(state, account: request.account))
            })
        case .listUTXOs(let request):
            return .listUTXOs(try read(request.account, context: context) { state in
                let record = try cached(state, account: request.account)
                let snapshot = try JSONDecoder().decode(OpalBase.Account.Snapshot.self, from: record.snapshot)
                let items = try snapshot.addressBook.utxos.map { utxo -> UTXOSummary in
                    guard let amount = Int64(exactly: utxo.value) else { throw ServiceProblem(.unavailable) }
                    let point = Outpoint(transactionID: try Self.snapshotTransactionID(utxo.transactionHash), outputIndex: utxo.outputIndex)
                    let key = "\(point.transactionID):\(point.outputIndex)"
                    let holders = state.payments.filter { payment in
                        payment.accountID == request.account.accountID && payment.network == request.account.wallet.network.rawValue &&
                        payment.selectedInputs.contains(key) && state.gates.contains { $0.accountID == payment.accountID && $0.liabilityIDs.contains(payment.id) }
                    }
                    let reservation: UTXOReservation
                    let unknownLease = state.payments.contains { payment in
                        payment.accountID == request.account.accountID && payment.network == request.account.wallet.network.rawValue &&
                        payment.selectedInputs.isEmpty && state.gates.contains { $0.accountID == payment.accountID && $0.liabilityIDs.contains(payment.id) }
                    }
                    if unknownLease { reservation = .otherOperation }
                    else if holders.isEmpty { reservation = .unreserved }
                    else if holders.count == 1, let holder = holders.first,
                            holder.originGrantID == context.session.principal.grantID,
                            state.requests.contains(where: { $0.paymentID == holder.id &&
                                $0.principalID == context.session.principal.integrationID && $0.originGrantID == holder.originGrantID }) {
                        reservation = .visibleOperation(holder.id)
                    } else { reservation = .otherOperation }
                    return UTXOSummary(outpoint: point, amountSatoshis: amount, reservation: reservation)
                }.sorted { ($0.outpoint.transactionID, $0.outpoint.outputIndex) < ($1.outpoint.transactionID, $1.outpoint.outputIndex) }
                guard Set(items.map(\.outpoint)).count == items.count else { throw ServiceProblem(.unavailable) }
                return AccountPage(account: request.account,
                    observation: Self.observation(record, generation: state.authorization.generation),
                    page: try paginate(items, page: request.page, category: "utxos", account: request.account,
                        sequence: record.sequence, state: state, context: context,
                        identity: { "\($0.outpoint.transactionID):\($0.outpoint.outputIndex)" }),
                    readiness: readiness(state, account: request.account))
            })
        case .getSyncStatus(let account):
            return .getSyncStatus(try read(account, context: context) { state in
                let record = state.publicSnapshots.first { $0.accountID == account.accountID && $0.network == account.wallet.network.rawValue }
                return SyncStatusProjection(account: account,
                    observation: record.flatMap { Self.hasObservation($0) ? Self.observation($0, generation: state.authorization.generation) : nil },
                    readiness: readiness(state, account: account))
            })
        case .synchronizeAccount(let request):
            try check(request.account, scope: .sync, context: context)
            let result = try await receives.synchronize(.init(accountID: request.account.accountID,
                network: request.account.wallet.network.rawValue, requestKey: request.requestKey.value),
                session: context.session, connectionID: context.connectionID, peer: context.peer)
            let projection = try discloseAccountOperation(result.operationID, account: request.account, scope: .sync, context: context)
            guard case .synchronization(let value) = projection else { throw ServiceProblem(.unavailable) }
            return .synchronizeAccount(value)
        case .createReceiveRequest(let request):
            try check(request.account, scope: .receive, context: context)
            let result = try await receives.createOperation(.init(accountID: request.account.accountID,
                network: request.account.wallet.network.rawValue, requestKey: request.requestKey.value),
                session: context.session, connectionID: context.connectionID, peer: context.peer)
            let projection = try discloseAccountOperation(result.operationID, account: request.account, scope: .receive, context: context)
            guard case .receive(let value) = projection else { throw ServiceProblem(.unavailable) }
            return .createReceiveRequest(value)
        case .preparePayment(let request):
            try check(request.account, scope: .prepare, context: context)
            let normalized = try Self.normalize(request.destinationAddress, network: request.account.wallet.network)
            let result = try await payments.prepare(PaymentRequest(accountID: request.account.accountID,
                network: request.account.wallet.network.rawValue, requestKey: request.requestKey.value,
                destinationScript: normalized.script, amount: request.amountSatoshis,
                feeRate: request.feeRateSatoshisPerByte, expiresAt: request.expiresAt), session: context.session,
                connectionID: context.connectionID, peer: context.peer)
            return .preparePayment(try disclosePayment(result.payment.id, account: request.account, scope: .prepare, context: context))
        case .submitPayment(let selector):
            _ = try disclosePayment(selector.operationID, account: selector.account, scope: .submit, context: context)
            _ = try await payments.submit(operationID: selector.operationID, session: context.session,
                connectionID: context.connectionID, peer: context.peer)
            return .submitPayment(try disclosePayment(selector.operationID, account: selector.account, scope: .submit, context: context))
        case .getOperation(let lookup):
            return .getOperation(try await operation(lookup, context: context))
        case .cancelOperation(let selector):
            let payment = try current { state in
                try authorize(state, account: selector.account, scope: .cancel, context: context)
                return state.payments.contains { $0.id == selector.operationID }
            }
            if payment {
                _ = try disclosePayment(selector.operationID, account: selector.account, scope: .cancel, context: context)
                _ = try await payments.cancel(operationID: selector.operationID, session: context.session,
                    connectionID: context.connectionID, peer: context.peer)
                return .cancelOperation(.payment(try disclosePayment(selector.operationID, account: selector.account, scope: .cancel, context: context)))
            }
            _ = try discloseAccountOperation(selector.operationID, account: selector.account, scope: .cancel, context: context)
            _ = try await receives.cancel(id: selector.operationID, accountID: selector.account.accountID,
                network: selector.account.wallet.network.rawValue, session: context.session,
                connectionID: context.connectionID, peer: context.peer)
            return .cancelOperation(try discloseAccountOperation(selector.operationID, account: selector.account, scope: .cancel, context: context))
        }
    }

    private func operation(_ lookup: OperationLookup, context: CapabilityConnectionContext) async throws -> OperationProjection {
        do {
            switch lookup {
            case .operation(let selector):
                let payment = try read(selector.account, context: context) { state in state.payments.contains { $0.id == selector.operationID } }
                if payment {
                    _ = try disclosePayment(selector.operationID, account: selector.account, scope: .read, context: context)
                    _ = try await payments.get(operationID: selector.operationID, session: context.session,
                        connectionID: context.connectionID, peer: context.peer)
                    return .payment(try disclosePayment(selector.operationID, account: selector.account, scope: .read, context: context))
                }
                _ = try await receives.get(id: selector.operationID, accountID: selector.account.accountID,
                    network: selector.account.wallet.network.rawValue, session: context.session,
                    connectionID: context.connectionID, peer: context.peer)
                return try discloseAccountOperation(selector.operationID, account: selector.account, scope: .read, context: context)
            case .request(let account, let effect, let key):
                try check(account, scope: .read, context: context)
                if effect == .preparePayment {
                    let snapshot = try await payments.lookup(requestKey: key.value, session: context.session,
                        connectionID: context.connectionID, peer: context.peer)
                    return .payment(try disclosePayment(snapshot.payment.id, account: account, scope: .read, context: context))
                }
                let snapshot = try await receives.lookup(request: .init(accountID: account.accountID,
                    network: account.wallet.network.rawValue, requestKey: key.value),
                    effect: effect == .createReceiveRequest ? .receive : .synchronize, session: context.session,
                    connectionID: context.connectionID, peer: context.peer)
                return try discloseAccountOperation(snapshot.operationID, account: account, scope: .read, context: context)
            }
        } catch { throw ServiceProblem(.unavailable) }
    }

    private func disclosePayment(_ id: String, account: AccountScope, scope: IntegrationScope,
                                 context: CapabilityConnectionContext) throws -> PaymentOperation {
        try current { state in
            try authorize(state, account: account, scope: scope, context: context)
            guard let payment = state.payments.first(where: { $0.id == id && $0.accountID == account.accountID &&
                $0.network == account.wallet.network.rawValue && $0.originGrantID == context.session.principal.grantID }),
                state.requests.contains(where: { $0.paymentID == id && $0.principalID == context.session.principal.integrationID &&
                    $0.originGrantID == context.session.principal.grantID }) else { throw ServiceProblem(.unavailable) }
            return try Self.projectPayment(PaymentSnapshot(payment: payment,
                accountRestricted: Self.held(state, account: account), blocker: payment.blocker,
                currentWalletGeneration: state.authorization.generation), account: account)
        }
    }

    private func discloseAccountOperation(_ id: String, account: AccountScope, scope: IntegrationScope,
                                          context: CapabilityConnectionContext) throws -> OperationProjection {
        try current { state in
            try authorize(state, account: account, scope: scope, context: context)
            guard let row = state.requests.first(where: { $0.id == id && $0.paymentID == nil &&
                $0.principalID == context.session.principal.integrationID && $0.originGrantID == context.session.principal.grantID })
                else { throw ServiceProblem(.unavailable) }
            let snapshot = try accountOperationSnapshot(row, in: state)
            guard snapshot.request.accountID == account.accountID,
                  snapshot.request.network == account.wallet.network.rawValue else { throw ServiceProblem(.unavailable) }
            let identity = try Self.identity(id: id, key: row.key, account: account)
            let reason = snapshot.closeReason.flatMap { AgentValues.OperationCloseReason(rawValue: $0.rawValue) }
            let blocker = snapshot.blocker.map { OperationBlocker(rawValue: $0.rawValue) ?? .unavailable }
            switch snapshot.effect {
            case .receive:
                return .receive(ReceiveOperation(identity: identity,
                    state: ReceiveOperationState(rawValue: snapshot.state.rawValue) ?? .closed,
                    allocation: snapshot.allocation.map { ReceiveAllocationProjection(address: $0.address, index: $0.index) },
                    closeReason: reason, blocker: blocker))
            case .synchronize:
                return .synchronization(SyncOperation(identity: identity,
                    state: SyncOperationState(rawValue: snapshot.state.rawValue) ?? .closed,
                    observation: snapshot.observation.map { Self.observation($0, generation: state.authorization.generation) },
                    closeReason: reason, blocker: blocker))
            }
        }
    }

    // Security-ledger maintenance is sticky even when the disclosure is denied.
    // An unchanged ledger does not write; this never performs an account effect.
    private func current<T>(_ projection: (CanonicalState) throws -> T) throws -> T {
        let now = clock.read().wall
        return try continuity.transaction(classification: "capability.disclosure", mutation: { state -> Result<T, any Error> in
            if state.mode == .enabled {
                var authority = AuthorizationAuthority(ledger: state.authorization, expectedBridgeIdentity: policy.bridge,
                    trustedOwnerIdentity: policy.owner, maximumOwnerAuthenticationAge: policy.ownerAuthenticationAge, expectedAppleIntegrationIdentity: policy.appleIntegration)
                for grant in authority.observeExpirations(now: now) {
                    state.invalidateUnsubmitted(grantID: grant)
                    let payments = Set(state.payments.filter { $0.originGrantID == grant }.map(\.id))
                    for index in state.approvals.indices where payments.contains(state.approvals[index].paymentID) {
                        state.approvals[index].active = false
                    }
                }
                state.authorization = authority.ledger
            }
            return Result { try projection(state) }
        }, projection: { _, outcome in try outcome.get() })
    }

    private func check(_ account: AccountScope, scope: IntegrationScope, context: CapabilityConnectionContext) throws {
        try current { try authorize($0, account: account, scope: scope, context: context) }
    }
    private func read<T>(_ account: AccountScope, context: CapabilityConnectionContext,
                         projection: (CanonicalState) throws -> T) throws -> T {
        try current { state in
            try authorize(state, account: account, scope: .read, context: context)
            return try projection(state)
        }
    }
    private func authorize(_ state: CanonicalState, account: AccountScope, scope: IntegrationScope,
                           context: CapabilityConnectionContext) throws {
        guard state.mode == .enabled, state.history == .complete else { throw ServiceProblem(.recoveryRequired) }
        guard state.authorization.walletID == account.wallet.walletID,
              state.authorization.network == account.wallet.network.rawValue,
              state.custody?.accountID == account.accountID else { throw ServiceProblem(.unavailable) }
        try requireAccountCustody(state, accountID: account.accountID, network: account.wallet.network.rawValue)
        let authority = AuthorizationAuthority(ledger: state.authorization, expectedBridgeIdentity: policy.bridge,
            trustedOwnerIdentity: policy.owner, maximumOwnerAuthenticationAge: policy.ownerAuthenticationAge, expectedAppleIntegrationIdentity: policy.appleIntegration)
        _ = try authority.authorize(session: context.session, connectionID: context.connectionID, peer: context.peer,
            operation: .init(walletID: account.wallet.walletID, network: account.wallet.network.rawValue,
                accountID: account.accountID, capability: scope.rawValue), now: clock.read().wall)
    }
    private func visibleAccounts(_ state: CanonicalState, context: CapabilityConnectionContext) throws -> [AccountScope] {
        guard let network = WalletNetwork(rawValue: state.authorization.network), let custody = state.custody else {
            throw ServiceProblem(.unavailable)
        }
        let account = try AccountScope(wallet: WalletScope(walletID: state.authorization.walletID, network: network), accountID: custody.accountID)
        try authorize(state, account: account, scope: .read, context: context)
        return [account]
    }
    private func cached(_ state: CanonicalState, account: AccountScope) throws -> AccountSyncRecord {
        guard let value = state.publicSnapshots.first(where: { $0.accountID == account.accountID && $0.network == account.wallet.network.rawValue }),
              !value.snapshot.isEmpty, Self.hasObservation(value) else { throw ServiceProblem(.unavailable) }
        return value
    }
    private func readiness(_ state: CanonicalState, account: AccountScope) -> AccountReadiness {
        let known = Self.durableReadiness(state, account: account)
        guard known.blockers.isEmpty else { return known }
        return availability(account)
    }
    private static func durableReadiness(_ state: CanonicalState, account: AccountScope) -> AccountReadiness {
        var blockers: [OperationBlocker] = []
        if state.mode != .enabled { blockers.append(.authorizationUnavailable) }
        if state.history != .complete { blockers.append(.historyIncomplete) }
        if state.custody?.accountID != account.accountID { blockers.append(.custodyUnavailable) }
        if held(state, account: account) { blockers.append(.accountRestricted) }
        if let snapshot = state.publicSnapshots.first(where: { $0.accountID == account.accountID && $0.network == account.wallet.network.rawValue }) {
            if !snapshot.fresh || snapshot.generation != state.authorization.generation { blockers.append(.staleSnapshot) }
            if !snapshot.complete { blockers.append(.incompleteSnapshot) }
        } else { blockers.append(.staleSnapshot) }
        return AccountReadiness(state: blockers.isEmpty ? .unavailable : .blocked, blockers: blockers)
    }
    private static func held(_ state: CanonicalState, account: AccountScope) -> Bool {
        state.gates.contains { $0.accountID == account.accountID && (!$0.liabilityIDs.isEmpty || !$0.restrictions.isEmpty) }
    }
    static func projectSyncStatus(record: AccountSyncRecord?, account: AccountScope, state: CanonicalState) -> SyncStatusProjection {
        SyncStatusProjection(account: account, observation: record.flatMap { hasObservation($0) ? observation($0, generation: state.authorization.generation) : nil },
            readiness: durableReadiness(state, account: account))
    }
    private static func hasObservation(_ record: AccountSyncRecord) -> Bool {
        !record.providerID.isEmpty && !record.viewID.isEmpty && !record.chainTip.isEmpty && !record.snapshot.isEmpty
    }
    private static func observation(_ record: AccountSyncRecord, generation: UInt64) -> SnapshotObservation {
        SnapshotObservation(providerID: record.providerID, viewID: record.viewID, chainTip: record.chainTip,
            sequence: record.sequence, observedAt: record.observedAt, generation: record.generation,
            fresh: record.fresh && record.generation == generation, complete: record.complete)
    }

    /// Safe projection only. The caller must authorize the current origin and disclosure.
    static func projectPayment(_ snapshot: PaymentSnapshot, account: AccountScope) throws -> PaymentOperation {
        let payment = snapshot.payment
        guard let request = payment.request, request.accountID == account.accountID,
              request.network == account.wallet.network.rawValue else { throw ServiceProblem(.unavailable) }
        let address = try canonicalAddress(script: request.destinationScript, network: account.wallet.network)
        let publicRequest = try PreparePaymentRequest(account: account, requestKey: RequestKey(request.requestKey),
            destinationAddress: address, amountSatoshis: request.amount, feeRateSatoshisPerByte: request.feeRate, expiresAt: request.expiresAt)
        let preview = try payment.preview.map { value -> PaymentPreviewProjection in
            guard value.destinationScript == request.destinationScript, value.amount == request.amount,
                  value.operationID == payment.id, value.accountID == request.accountID, value.network == request.network else {
                throw ServiceProblem(.unavailable)
            }
            let change: [ChangeOutput]
            if value.change.isEmpty { change = [] }
            else {
                let decoded = try JSONDecoder().decode(ChangePayload.self, from: value.change)
                guard let amount = Int64(exactly: decoded.amount) else { throw ServiceProblem(.unavailable) }
                change = [ChangeOutput(lockingScriptHex: hex(decoded.script), amountSatoshis: amount)]
            }
            return PaymentPreviewProjection(canonicalDestinationAddress: address, destinationScriptHex: hex(value.destinationScript),
                amountSatoshis: value.amount, feeSatoshis: value.fee, selectedInputs: try value.selectedInputs.map(outpoint),
                change: change, templateDigest: hex(value.templateDigest), leaseDeadline: value.leaseDeadline)
        }
        let disposition: PaymentOperationState
        switch payment.disposition {
        case .unsubmitted: disposition = .preparing
        case .invalidated, .closed: disposition = .closed
        case .possiblyRelayed: disposition = .uncertain
        default: disposition = PaymentOperationState(rawValue: payment.disposition.rawValue) ?? .recoveryRequired
        }
        let latest = payment.attempts.max { ($0.number, $0.id) < ($1.number, $1.id) }
        let attempt = latest.map { RelayAttemptProjection(attemptID: $0.id, number: $0.number,
            route: RelayRoute(rawValue: $0.route) ?? .ordinary, outcome: RelayAttemptOutcome(rawValue: $0.outcome) ?? .unknown,
            admittedAt: $0.admittedAt, nextEligibleAt: $0.nextEligibleAt) }
        let evidence = payment.evidence.filter(\.valid).max { ($0.sequence, $0.id) < ($1.sequence, $1.id) }
        let observed = evidence?.observation.map { value in
            SnapshotObservation(providerID: value.source, viewID: value.view, chainTip: value.chainTip,
                sequence: evidence?.sequence ?? 0, observedAt: value.observedAt, generation: payment.walletGeneration,
                fresh: value.fresh && (snapshot.currentWalletGeneration == 0 || snapshot.currentWalletGeneration == payment.walletGeneration), complete: value.complete)
        }
        return PaymentOperation(identity: try identity(id: payment.id, key: request.requestKey, account: account),
            request: publicRequest, state: disposition, preview: preview,
            terminalReason: payment.terminalReason.flatMap { AgentValues.OperationCloseReason(rawValue: $0) } ??
                (payment.disposition == .invalidated ? .invalidated : nil),
            closures: payment.closures.map { PaymentClosureProjection(reason: AgentValues.OperationCloseReason(rawValue: $0.reason) ?? .failed,
                evidenceRevision: $0.revision, support: $0.evidenceIDs.isEmpty ? .notApplicable :
                    (payment.evidenceSupported && $0.revision == payment.evidenceRevision ? .supported : .unsupported)) },
            accountRestriction: snapshot.accountRestricted ? .held : .clear, liabilityUnresolved: payment.liabilityUnresolved,
            blocker: snapshot.blocker.map { OperationBlocker(rawValue: $0) ?? ($0.hasPrefix("evidenceDefect:") ? .evidenceDefect : .unavailable) },
            evidence: PaymentEvidenceProjection(revision: payment.evidenceRevision,
                support: payment.evidenceSupported ? .supported : (payment.evidence.isEmpty ? .unknown : .unsupported), observation: observed),
            ordinaryAdmissions: payment.ordinaryAdmissions, latestAttempt: attempt, lastReconciliationAt: payment.lastReconciliationAt,
            observationSequence: payment.observationSequence, transactionID: payment.transactionID.isEmpty ? nil : payment.transactionID)
    }
    private struct ChangePayload: Decodable { var index: UInt32; var amount: UInt64; var script: Data }
    private static func identity(id: String, key: String, account: AccountScope) throws -> OperationIdentity {
        OperationIdentity(selector: try OperationSelector(account: account, operationID: id), requestKey: try RequestKey(key))
    }
    private static func normalize(_ spelling: String, network: WalletNetwork) throws -> (script: Data, address: String) {
        guard let environment = OpalBase.Network.Environment(rawValue: network.rawValue) else { throw ServiceProblem(.invalidRequest) }
        do {
            let parsed = try OpalBase.Address(spelling, network: environment)
            let canonical = try OpalBase.Address(script: parsed.lockingScript, network: environment)
            return (OpalBase.Transaction.Output(value: 0, address: canonical).lockingScript, canonical.string)
        } catch { throw ServiceProblem(.invalidRequest) }
    }
    private static func canonicalAddress(script: Data, network: WalletNetwork) throws -> String {
        guard let environment = OpalBase.Network.Environment(rawValue: network.rawValue) else { throw ServiceProblem(.invalidRequest) }
        return try OpalBase.Address(script: .decode(lockingScript: script), network: environment).string
    }
    private static func snapshotTransactionID(_ naturalHex: String) throws -> String {
        guard naturalHex.utf8.count == 64, naturalHex.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw ServiceProblem(.unavailable) }
        var bytes = Data(); var offset = naturalHex.startIndex
        while offset < naturalHex.endIndex {
            let next = naturalHex.index(offset, offsetBy: 2)
            guard let byte = UInt8(naturalHex[offset..<next], radix: 16) else { throw ServiceProblem(.unavailable) }
            bytes.append(byte); offset = next
        }
        return hex(Data(bytes.reversed()))
    }
    private static func outpoint(_ value: String) throws -> Outpoint {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count == 64, parts[0].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let index = UInt32(parts[1]), String(index) == parts[1] else { throw ServiceProblem(.unavailable) }
        return Outpoint(transactionID: String(parts[0]), outputIndex: index)
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private struct CursorContext: Codable {
        var grant: String; var integration: String; var credentialGeneration: UInt64; var generation: UInt64
        var category: String; var wallet: String; var network: String; var account: String?; var sequence: UInt64?
    }
    private struct Cursor: Codable {
        var version: Int = 1
        var context: Data
        var last: String
    }
    private func paginate<Item: Codable & Sendable & Equatable>(_ items: [Item], page: PageRequest, category: String, account: AccountScope?, sequence: UInt64?,
        state: CanonicalState, context: CapabilityConnectionContext, identity: (Item) -> String) throws -> CapabilityPage<Item> {
        let binding = CursorContext(grant: context.session.principal.grantID, integration: context.session.principal.integrationID,
            credentialGeneration: context.session.credentialGeneration, generation: state.authorization.generation,
            category: category, wallet: state.authorization.walletID, network: state.authorization.network,
            account: account?.accountID, sequence: sequence)
        let commitment = paymentDigest(try paymentEncoding(binding))
        let offset: Int
        if let encoded = page.cursor {
            guard let data = Data(base64Encoded: encoded), let supplied = try? JSONDecoder().decode(Cursor.self, from: data) else {
                throw ServiceProblem(.invalidRequest)
            }
            guard supplied.version == 1, supplied.context == commitment,
                  let last = items.firstIndex(where: { identity($0) == supplied.last }) else { throw ServiceProblem(.staleContext) }
            offset = last + 1
        } else { offset = 0 }
        let selected = Array(items.dropFirst(offset).prefix(page.limit))
        let next: String?
        if offset + selected.count < items.count, let last = selected.last {
            next = try paymentEncoding(Cursor(context: commitment, last: identity(last))).base64EncodedString()
        } else { next = nil }
        return CapabilityPage(items: selected, nextCursor: next)
    }
    private static func problem(_ error: any Error) -> ServiceProblem {
        if let problem = error as? ServiceProblem { return problem }
        if let failure = error as? PaymentFailure {
            return ServiceProblem(ServiceProblemCode(rawValue: String(describing: failure)) ?? .unavailable)
        }
        if error is CapabilityFailure { return ServiceProblem(.invalidRequest) }
        if let failure = error as? ContinuityError {
            if failure == .keyUnavailable { return ServiceProblem(.keyUnavailable) }
            if failure == .recoveryRequired { return ServiceProblem(.recoveryRequired) }
        }
        return ServiceProblem(.unavailable)
    }
}
