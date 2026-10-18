import Foundation

public enum CapabilityFailure: Error, Sendable, Equatable {
    case invalidRequest
    case invalidResponse
}

public enum IntegrationScope: String, Codable, Sendable, CaseIterable { case read, sync, receive, prepare, submit, cancel }

public enum ServiceProblemCode: String, Codable, Sendable {
    case unavailable, invalidRequest, conflictingRequest, approvalNeeded, accountRestricted, staleContext
    case leaseExpired, transportBusy, networkUnavailable, keyUnavailable, recoveryRequired, invalidTransition, relayNotEligible
}
public struct ServiceProblem: Error, Codable, Sendable, Equatable {
    public let code: ServiceProblemCode
    public init(_ code: ServiceProblemCode) { self.code = code }
}
public enum OperationBlocker: String, Codable, Sendable {
    case unavailable, authorizationUnavailable, continuityUnavailable, historyIncomplete, custodyUnavailable
    case accountRestricted, keyUnavailable, networkUnavailable, staleSnapshot, incompleteSnapshot
    case approvalNeeded, leaseExpired, transportBusy, staleContext, staleEvidence, inconclusiveEvidence
    case automaticRelayBudgetExhausted, evidenceDefect, leaseCleanupFailed, relayNotEligible
}
public enum AccountReadinessState: String, Codable, Sendable { case unavailable, blocked, ready }
/// A current service projection, never a reusable authorization or a consequence of observation freshness alone.
public struct AccountReadiness: Codable, Sendable, Equatable {
    public let state: AccountReadinessState
    public let blockers: [OperationBlocker]
    public init(state: AccountReadinessState, blockers: [OperationBlocker] = []) { self.state = state; self.blockers = blockers }
    public static let unavailable = AccountReadiness(state: .unavailable)
}
public enum AccountRestriction: String, Codable, Sendable { case unavailable, clear, held }
public enum OperationCloseReason: String, Codable, Sendable {
    case cancelled, invalidated, failed, rejected, expired, authorizationInvalidated, failedUnsubmitted, reconciledAccepted, reconciledConflict
}
public enum EvidenceSupport: String, Codable, Sendable { case unknown, unsupported, supported, notApplicable }
public struct PaymentEvidenceProjection: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let support: EvidenceSupport
    public let observation: SnapshotObservation?
    public init(revision: UInt64, support: EvidenceSupport, observation: SnapshotObservation? = nil) {
        self.revision = revision; self.support = support; self.observation = observation
    }
}
public struct PaymentClosureProjection: Codable, Sendable, Equatable {
    public let reason: OperationCloseReason
    public let evidenceRevision: UInt64
    public let support: EvidenceSupport
    public init(reason: OperationCloseReason, evidenceRevision: UInt64, support: EvidenceSupport) {
        self.reason = reason; self.evidenceRevision = evidenceRevision; self.support = support
    }
}
public enum RelayRoute: String, Codable, Sendable { case ordinary, owner }
public enum RelayAttemptOutcome: String, Codable, Sendable { case admitted, unknown, accepted, rejected, noHandoff }
public struct RelayAttemptProjection: Codable, Sendable, Equatable {
    public let attemptID: String
    public let number: UInt64
    public let route: RelayRoute
    public let outcome: RelayAttemptOutcome
    public let admittedAt: Int64
    public let nextEligibleAt: Int64?
    public init(attemptID: String, number: UInt64, route: RelayRoute, outcome: RelayAttemptOutcome, admittedAt: Int64, nextEligibleAt: Int64? = nil) {
        self.attemptID = attemptID; self.number = number; self.route = route; self.outcome = outcome
        self.admittedAt = admittedAt; self.nextEligibleAt = nextEligibleAt
    }
}
public enum UTXOReservation: Codable, Sendable, Equatable {
    case unreserved
    case visibleOperation(String)
    case otherOperation
}

public enum WalletNetwork: String, Codable, Sendable, CaseIterable {
    case mainnet, testnet, chipnet
}

public enum CapabilityMethod: String, Codable, Sendable, CaseIterable {
    case listWallets = "list_wallets"
    case listAccounts = "list_accounts"
    case getBalance = "get_balance"
    case listTransactions = "list_transactions"
    case listUTXOs = "list_utxos"
    case getSyncStatus = "get_sync_status"
    case synchronizeAccount = "synchronize_account"
    case createReceiveRequest = "create_receive_request"
    case preparePayment = "prepare_payment"
    case submitPayment = "submit_payment"
    case getOperation = "get_operation"
    case cancelOperation = "cancel_operation"
}

public extension CapabilityMethod {
    var requiredScope: IntegrationScope {
        switch self {
        case .listWallets, .listAccounts, .getBalance, .listTransactions, .listUTXOs, .getSyncStatus, .getOperation: .read
        case .synchronizeAccount: .sync
        case .createReceiveRequest: .receive
        case .preparePayment: .prepare
        case .submitPayment: .submit
        case .cancelOperation: .cancel
        }
    }
}

/// Retain this random 128-bit key before sending an effect request. Keys are never normalized or recycled.
public struct RequestKey: Codable, Sendable, Equatable, Hashable {
    public let value: String
    public init(_ value: String) throws {
        guard isLowerHex(value, bytes: 16) else { throw CapabilityFailure.invalidRequest }
        self.value = value
    }
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct WalletScope: Codable, Sendable, Equatable, Hashable {
    public let walletID: String
    public let network: WalletNetwork
    public init(walletID: String, network: WalletNetwork) throws {
        guard isIdentifier(walletID) else { throw CapabilityFailure.invalidRequest }
        self.walletID = walletID
        self.network = network
    }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["walletID", "network"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(walletID: c.decode(String.self, forKey: .walletID), network: c.decode(WalletNetwork.self, forKey: .network))
    }
    private enum CodingKeys: String, CodingKey { case walletID, network }
}

public struct AccountScope: Codable, Sendable, Equatable, Hashable {
    public let wallet: WalletScope
    public let accountID: String
    public init(wallet: WalletScope, accountID: String) throws {
        guard isIdentifier(accountID) else { throw CapabilityFailure.invalidRequest }
        self.wallet = wallet
        self.accountID = accountID
    }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["wallet", "accountID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(wallet: c.decode(WalletScope.self, forKey: .wallet), accountID: c.decode(String.self, forKey: .accountID))
    }
    private enum CodingKeys: String, CodingKey { case wallet, accountID }
}

public struct PageRequest: Codable, Sendable, Equatable {
    public static let maximumCount = 40
    public let limit: Int
    public let cursor: String?
    public init(limit: Int = maximumCount, cursor: String? = nil) throws {
        guard (1...Self.maximumCount).contains(limit), cursor.map(isIdentifier) ?? true else { throw CapabilityFailure.invalidRequest }
        self.limit = limit
        self.cursor = cursor
    }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["limit", "cursor"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(limit: c.decode(Int.self, forKey: .limit), cursor: c.decodeIfPresent(String.self, forKey: .cursor))
    }
    private enum CodingKeys: String, CodingKey { case limit, cursor }
}

public struct WalletPageRequest: Codable, Sendable, Equatable {
    public let wallet: WalletScope
    public let page: PageRequest
    public init(wallet: WalletScope, page: PageRequest) { self.wallet = wallet; self.page = page }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["wallet", "page"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(wallet: try c.decode(WalletScope.self, forKey: .wallet), page: try c.decode(PageRequest.self, forKey: .page))
    }
    private enum CodingKeys: String, CodingKey { case wallet, page }
}

public struct AccountPageRequest: Codable, Sendable, Equatable {
    public let account: AccountScope
    public let page: PageRequest
    public init(account: AccountScope, page: PageRequest) { self.account = account; self.page = page }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["account", "page"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(account: try c.decode(AccountScope.self, forKey: .account), page: try c.decode(PageRequest.self, forKey: .page))
    }
    private enum CodingKeys: String, CodingKey { case account, page }
}

public struct KeyedAccountRequest: Codable, Sendable, Equatable {
    public let account: AccountScope
    public let requestKey: RequestKey
    public init(account: AccountScope, requestKey: RequestKey) { self.account = account; self.requestKey = requestKey }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["account", "requestKey"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(account: try c.decode(AccountScope.self, forKey: .account), requestKey: try c.decode(RequestKey.self, forKey: .requestKey))
    }
    private enum CodingKeys: String, CodingKey { case account, requestKey }
}

/// The service validates the address against the explicit network and normalizes it with its BCH dependency.
public struct PreparePaymentRequest: Codable, Sendable, Equatable {
    public let account: AccountScope
    public let requestKey: RequestKey
    public let destinationAddress: String
    public let amountSatoshis: Int64
    public let feeRateSatoshisPerByte: Int64
    public let expiresAt: Int64?
    public init(account: AccountScope, requestKey: RequestKey, destinationAddress: String,
                amountSatoshis: Int64, feeRateSatoshisPerByte: Int64 = 1, expiresAt: Int64? = nil) throws {
        guard !destinationAddress.isEmpty, destinationAddress.utf8.count <= 512,
              destinationAddress == destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines),
              amountSatoshis > 0, amountSatoshis <= 2_100_000_000_000_000,
              feeRateSatoshisPerByte > 0, expiresAt.map({ $0 > 0 }) ?? true else { throw CapabilityFailure.invalidRequest }
        self.account = account; self.requestKey = requestKey; self.destinationAddress = destinationAddress
        self.amountSatoshis = amountSatoshis; self.feeRateSatoshisPerByte = feeRateSatoshisPerByte; self.expiresAt = expiresAt
    }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["account", "requestKey", "destinationAddress", "amountSatoshis", "feeRateSatoshisPerByte", "expiresAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(AccountScope.self, forKey: .account), requestKey: c.decode(RequestKey.self, forKey: .requestKey),
            destinationAddress: c.decode(String.self, forKey: .destinationAddress), amountSatoshis: c.decode(Int64.self, forKey: .amountSatoshis),
            feeRateSatoshisPerByte: c.decode(Int64.self, forKey: .feeRateSatoshisPerByte), expiresAt: c.decodeIfPresent(Int64.self, forKey: .expiresAt))
    }
    private enum CodingKeys: String, CodingKey { case account, requestKey, destinationAddress, amountSatoshis, feeRateSatoshisPerByte, expiresAt }
}

public struct OperationSelector: Codable, Sendable, Equatable {
    public let account: AccountScope
    public let operationID: String
    public init(account: AccountScope, operationID: String) throws {
        guard isIdentifier(operationID) else { throw CapabilityFailure.invalidRequest }
        self.account = account; self.operationID = operationID
    }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["account", "operationID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(AccountScope.self, forKey: .account), operationID: c.decode(String.self, forKey: .operationID))
    }
    private enum CodingKeys: String, CodingKey { case account, operationID }
}

public enum EffectKind: String, Codable, Sendable, CaseIterable { case synchronizeAccount, createReceiveRequest, preparePayment }

/// Exactly one selector is encoded. A retained key is scoped by wallet, integration and effect kind at the service.
public enum OperationLookup: Sendable, Equatable, Codable {
    case operation(OperationSelector)
    case request(account: AccountScope, effect: EffectKind, key: RequestKey)
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["operation", "account", "effect", "requestKey"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.operation) {
            guard !c.contains(.account), !c.contains(.effect), !c.contains(.requestKey) else { throw CapabilityFailure.invalidRequest }
            self = .operation(try c.decode(OperationSelector.self, forKey: .operation))
        } else {
            self = .request(account: try c.decode(AccountScope.self, forKey: .account),
                effect: try c.decode(EffectKind.self, forKey: .effect), key: try c.decode(RequestKey.self, forKey: .requestKey))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .operation(let operation): try c.encode(operation, forKey: .operation)
        case .request(let account, let effect, let key):
            try c.encode(account, forKey: .account); try c.encode(effect, forKey: .effect); try c.encode(key, forKey: .requestKey)
        }
    }
    private enum CodingKeys: String, CodingKey { case operation, account, effect, requestKey }
}

public enum CapabilityCall: Sendable, Equatable {
    case listWallets(PageRequest)
    case listAccounts(WalletPageRequest)
    case getBalance(AccountScope)
    case listTransactions(AccountPageRequest)
    case listUTXOs(AccountPageRequest)
    case getSyncStatus(AccountScope)
    case synchronizeAccount(KeyedAccountRequest)
    case createReceiveRequest(KeyedAccountRequest)
    case preparePayment(PreparePaymentRequest)
    case submitPayment(OperationSelector)
    case getOperation(OperationLookup)
    case cancelOperation(OperationSelector)
    public var method: CapabilityMethod {
        switch self {
        case .listWallets: .listWallets
        case .listAccounts: .listAccounts
        case .getBalance: .getBalance
        case .listTransactions: .listTransactions
        case .listUTXOs: .listUTXOs
        case .getSyncStatus: .getSyncStatus
        case .synchronizeAccount: .synchronizeAccount
        case .createReceiveRequest: .createReceiveRequest
        case .preparePayment: .preparePayment
        case .submitPayment: .submitPayment
        case .getOperation: .getOperation
        case .cancelOperation: .cancelOperation
        }
    }
}

/// This service envelope is independent of the MCP protocol version. It carries no caller-asserted role or approval.
public struct CapabilityRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let call: CapabilityCall
    public init(call: CapabilityCall) { self.protocolVersion = ServiceStatus.currentProtocolVersion; self.call = call }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, ["protocolVersion", "method", "parameters"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == ServiceStatus.currentProtocolVersion else { throw ClientFailure.incompatibleProtocol }
        switch try c.decode(CapabilityMethod.self, forKey: .method) {
        case .listWallets: call = .listWallets(try c.decode(PageRequest.self, forKey: .parameters))
        case .listAccounts: call = .listAccounts(try c.decode(WalletPageRequest.self, forKey: .parameters))
        case .getBalance: call = .getBalance(try c.decode(AccountScope.self, forKey: .parameters))
        case .listTransactions: call = .listTransactions(try c.decode(AccountPageRequest.self, forKey: .parameters))
        case .listUTXOs: call = .listUTXOs(try c.decode(AccountPageRequest.self, forKey: .parameters))
        case .getSyncStatus: call = .getSyncStatus(try c.decode(AccountScope.self, forKey: .parameters))
        case .synchronizeAccount: call = .synchronizeAccount(try c.decode(KeyedAccountRequest.self, forKey: .parameters))
        case .createReceiveRequest: call = .createReceiveRequest(try c.decode(KeyedAccountRequest.self, forKey: .parameters))
        case .preparePayment: call = .preparePayment(try c.decode(PreparePaymentRequest.self, forKey: .parameters))
        case .submitPayment: call = .submitPayment(try c.decode(OperationSelector.self, forKey: .parameters))
        case .getOperation: call = .getOperation(try c.decode(OperationLookup.self, forKey: .parameters))
        case .cancelOperation: call = .cancelOperation(try c.decode(OperationSelector.self, forKey: .parameters))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protocolVersion, forKey: .protocolVersion); try c.encode(call.method, forKey: .method)
        switch call {
        case .listWallets(let v): try c.encode(v, forKey: .parameters)
        case .listAccounts(let v): try c.encode(v, forKey: .parameters)
        case .getBalance(let v), .getSyncStatus(let v): try c.encode(v, forKey: .parameters)
        case .listTransactions(let v), .listUTXOs(let v): try c.encode(v, forKey: .parameters)
        case .synchronizeAccount(let v), .createReceiveRequest(let v): try c.encode(v, forKey: .parameters)
        case .preparePayment(let v): try c.encode(v, forKey: .parameters)
        case .submitPayment(let v), .cancelOperation(let v): try c.encode(v, forKey: .parameters)
        case .getOperation(let v): try c.encode(v, forKey: .parameters)
        }
    }
    private enum CodingKeys: String, CodingKey { case protocolVersion, method, parameters }
}

public struct CapabilityPage<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let items: [Item]
    public let nextCursor: String?
    public init(items: [Item], nextCursor: String? = nil) { self.items = items; self.nextCursor = nextCursor }
}
public struct WalletSummary: Codable, Sendable, Equatable {
    public let scope: WalletScope
    public let availability: ServiceAvailability
    public init(scope: WalletScope, availability: ServiceAvailability = .unavailable) { self.scope = scope; self.availability = availability }
}
public struct AccountSummary: Codable, Sendable, Equatable {
    public let scope: AccountScope
    public let readiness: AccountReadiness
    public init(scope: AccountScope, readiness: AccountReadiness = .unavailable) { self.scope = scope; self.readiness = readiness }
}

/// Observation facts supplied by the authenticated service; they are not a local readiness or signing permission.
public struct SnapshotObservation: Codable, Sendable, Equatable {
    public let providerID: String
    public let viewID: String
    public let chainTip: String
    public let sequence: UInt64
    public let observedAt: Int64
    public let generation: UInt64
    public let fresh: Bool
    public let complete: Bool
    public init(providerID: String, viewID: String, chainTip: String, sequence: UInt64,
                observedAt: Int64, generation: UInt64, fresh: Bool, complete: Bool) {
        self.providerID = providerID; self.viewID = viewID; self.chainTip = chainTip; self.sequence = sequence
        self.observedAt = observedAt; self.generation = generation; self.fresh = fresh; self.complete = complete
    }
}
public struct BalanceProjection: Codable, Sendable, Equatable {
    public let account: AccountScope
    public let totalSatoshis: Int64
    public let observation: SnapshotObservation
    public let readiness: AccountReadiness
    public init(account: AccountScope, totalSatoshis: Int64, observation: SnapshotObservation, readiness: AccountReadiness = .unavailable) {
        self.account = account; self.totalSatoshis = totalSatoshis; self.observation = observation; self.readiness = readiness
    }
}
public enum TransactionStatus: String, Codable, Sendable { case unknown, discovered, pending, confirmed, failed }
public struct TransactionSummary: Codable, Sendable, Equatable {
    public let transactionID: String
    public let deltaSatoshis: Int64?
    public let confirmations: UInt32?
    public let height: UInt32?
    public let status: TransactionStatus
    public init(transactionID: String, deltaSatoshis: Int64?, confirmations: UInt32?, height: UInt32? = nil, status: TransactionStatus = .unknown) {
        self.transactionID = transactionID; self.deltaSatoshis = deltaSatoshis; self.confirmations = confirmations
        self.height = height; self.status = status
    }
}
public struct Outpoint: Codable, Sendable, Equatable, Hashable {
    public let transactionID: String
    public let outputIndex: UInt32
    public init(transactionID: String, outputIndex: UInt32) { self.transactionID = transactionID; self.outputIndex = outputIndex }
}
public struct UTXOSummary: Codable, Sendable, Equatable {
    public let outpoint: Outpoint
    public let amountSatoshis: Int64
    public let reservation: UTXOReservation
    public init(outpoint: Outpoint, amountSatoshis: Int64, reservation: UTXOReservation) {
        self.outpoint = outpoint; self.amountSatoshis = amountSatoshis; self.reservation = reservation
    }
}
public struct AccountPage<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let account: AccountScope
    public let observation: SnapshotObservation
    public let page: CapabilityPage<Item>
    public let readiness: AccountReadiness
    public init(account: AccountScope, observation: SnapshotObservation, page: CapabilityPage<Item>, readiness: AccountReadiness = .unavailable) {
        self.account = account; self.observation = observation; self.page = page; self.readiness = readiness
    }
}
public struct AccountList: Codable, Sendable, Equatable {
    public let wallet: WalletScope
    public let page: CapabilityPage<AccountSummary>
    public init(wallet: WalletScope, page: CapabilityPage<AccountSummary>) { self.wallet = wallet; self.page = page }
}
public struct SyncStatusProjection: Codable, Sendable, Equatable {
    public let account: AccountScope
    /// Nil means there is no cached observation, never an invented zero balance or fresh snapshot.
    public let observation: SnapshotObservation?
    public let readiness: AccountReadiness
    public init(account: AccountScope, observation: SnapshotObservation?, readiness: AccountReadiness = .unavailable) {
        self.account = account; self.observation = observation; self.readiness = readiness
    }
}
public struct OperationIdentity: Codable, Sendable, Equatable {
    public let selector: OperationSelector
    public let requestKey: RequestKey
    public init(selector: OperationSelector, requestKey: RequestKey) { self.selector = selector; self.requestKey = requestKey }
}
public enum SyncOperationState: String, Codable, Sendable { case pending, completed, closed }
public struct SyncOperation: Codable, Sendable, Equatable {
    public let identity: OperationIdentity
    public let state: SyncOperationState
    public let observation: SnapshotObservation?
    public let closeReason: OperationCloseReason?
    public let blocker: OperationBlocker?
    public init(identity: OperationIdentity, state: SyncOperationState, observation: SnapshotObservation?,
                closeReason: OperationCloseReason? = nil, blocker: OperationBlocker? = nil) {
        self.identity = identity; self.state = state; self.observation = observation
        self.closeReason = closeReason; self.blocker = blocker
    }
}
public enum ReceiveOperationState: String, Codable, Sendable { case pending, allocated, closed }
public struct ReceiveAllocationProjection: Codable, Sendable, Equatable {
    public let address: String
    public let index: UInt32
    public init(address: String, index: UInt32) { self.address = address; self.index = index }
}
public struct ReceiveOperation: Codable, Sendable, Equatable {
    public let identity: OperationIdentity
    public let state: ReceiveOperationState
    public let allocation: ReceiveAllocationProjection?
    public let closeReason: OperationCloseReason?
    public let blocker: OperationBlocker?
    public init(identity: OperationIdentity, state: ReceiveOperationState, allocation: ReceiveAllocationProjection?,
                closeReason: OperationCloseReason? = nil, blocker: OperationBlocker? = nil) {
        self.identity = identity; self.state = state; self.allocation = allocation; self.closeReason = closeReason; self.blocker = blocker
    }
}
public struct ChangeOutput: Codable, Sendable, Equatable {
    public let lockingScriptHex: String
    public let amountSatoshis: Int64
    public init(lockingScriptHex: String, amountSatoshis: Int64) { self.lockingScriptHex = lockingScriptHex; self.amountSatoshis = amountSatoshis }
}
public struct PaymentPreviewProjection: Codable, Sendable, Equatable {
    public let canonicalDestinationAddress: String
    public let destinationScriptHex: String
    public let amountSatoshis: Int64
    public let feeSatoshis: Int64
    public let selectedInputs: [Outpoint]
    public let change: [ChangeOutput]
    public let templateDigest: String
    public let leaseDeadline: Int64
    public init(canonicalDestinationAddress: String, destinationScriptHex: String, amountSatoshis: Int64, feeSatoshis: Int64,
                selectedInputs: [Outpoint], change: [ChangeOutput], templateDigest: String, leaseDeadline: Int64) {
        self.canonicalDestinationAddress = canonicalDestinationAddress; self.destinationScriptHex = destinationScriptHex
        self.amountSatoshis = amountSatoshis; self.feeSatoshis = feeSatoshis; self.selectedInputs = selectedInputs
        self.change = change; self.templateDigest = templateDigest; self.leaseDeadline = leaseDeadline
    }
}
public enum PaymentOperationState: String, Codable, Sendable {
    case preparing, prepared, pendingApproval, ready, submitting, uncertain, accepted, recoveryRequired, closed
}
public struct PaymentOperation: Codable, Sendable, Equatable {
    public let identity: OperationIdentity
    public let request: PreparePaymentRequest
    public let state: PaymentOperationState
    public let preview: PaymentPreviewProjection?
    public let terminalReason: OperationCloseReason?
    public let closures: [PaymentClosureProjection]
    public let accountRestriction: AccountRestriction
    public let liabilityUnresolved: Bool
    public let blocker: OperationBlocker?
    public let evidence: PaymentEvidenceProjection
    public let ordinaryAdmissions: UInt64
    public let latestAttempt: RelayAttemptProjection?
    public let lastReconciliationAt: Int64?
    public let observationSequence: UInt64
    public let transactionID: String?
    public init(identity: OperationIdentity, request: PreparePaymentRequest, state: PaymentOperationState, preview: PaymentPreviewProjection?,
                terminalReason: OperationCloseReason? = nil, closures: [PaymentClosureProjection] = [], accountRestriction: AccountRestriction = .unavailable,
                liabilityUnresolved: Bool = false, blocker: OperationBlocker? = nil,
                evidence: PaymentEvidenceProjection = PaymentEvidenceProjection(revision: 0, support: .unknown), ordinaryAdmissions: UInt64 = 0,
                latestAttempt: RelayAttemptProjection? = nil, lastReconciliationAt: Int64? = nil, observationSequence: UInt64 = 0, transactionID: String? = nil) {
        self.identity = identity; self.request = request; self.state = state; self.preview = preview
        self.terminalReason = terminalReason; self.closures = closures; self.accountRestriction = accountRestriction
        self.liabilityUnresolved = liabilityUnresolved; self.blocker = blocker; self.evidence = evidence
        self.ordinaryAdmissions = ordinaryAdmissions; self.latestAttempt = latestAttempt
        self.lastReconciliationAt = lastReconciliationAt; self.observationSequence = observationSequence; self.transactionID = transactionID
    }
}
public enum OperationProjection: Codable, Sendable, Equatable {
    case synchronization(SyncOperation)
    case receive(ReceiveOperation)
    case payment(PaymentOperation)
    public var identity: OperationIdentity {
        switch self { case .synchronization(let v): v.identity; case .receive(let v): v.identity; case .payment(let v): v.identity }
    }
    public var effect: EffectKind {
        switch self { case .synchronization: .synchronizeAccount; case .receive: .createReceiveRequest; case .payment: .preparePayment }
    }
}
public enum CapabilityResult: Codable, Sendable, Equatable {
    case listWallets(CapabilityPage<WalletSummary>)
    case listAccounts(AccountList)
    case getBalance(BalanceProjection)
    case listTransactions(AccountPage<TransactionSummary>)
    case listUTXOs(AccountPage<UTXOSummary>)
    case getSyncStatus(SyncStatusProjection)
    case synchronizeAccount(SyncOperation)
    case createReceiveRequest(ReceiveOperation)
    case preparePayment(PaymentOperation)
    case submitPayment(PaymentOperation)
    case getOperation(OperationProjection)
    case cancelOperation(OperationProjection)
    public var method: CapabilityMethod {
        switch self {
        case .listWallets: .listWallets; case .listAccounts: .listAccounts; case .getBalance: .getBalance
        case .listTransactions: .listTransactions; case .listUTXOs: .listUTXOs; case .getSyncStatus: .getSyncStatus
        case .synchronizeAccount: .synchronizeAccount; case .createReceiveRequest: .createReceiveRequest
        case .preparePayment: .preparePayment; case .submitPayment: .submitPayment; case .getOperation: .getOperation; case .cancelOperation: .cancelOperation
        }
    }
}
public struct CapabilityResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let result: CapabilityResult
    public init(protocolVersion: Int = ServiceStatus.currentProtocolVersion, result: CapabilityResult) {
        self.protocolVersion = protocolVersion; self.result = result
    }
}

private struct FieldKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    let intValue: Int? = nil
    init?(intValue: Int) { return nil }
}
private func rejectUnknownFields(_ decoder: any Decoder, _ allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: FieldKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw CapabilityFailure.invalidRequest }
}
private func isIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 2048 && !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
}
private func isLowerHex(_ value: String, bytes: Int) -> Bool {
    value.utf8.count == bytes * 2 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
