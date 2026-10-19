// AgentAutomationSnapshots.swift

import AgentValues
import AppIntents
import Foundation

public struct AgentWalletSnapshot: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Wallet Result")
    public static let defaultQuery = AgentWalletSnapshotQuery()
    public let id: String
    @Property(title: "Wallet ID") public var walletID: String?
    @Property(title: "Network") public var network: String?
    @Property(title: "Availability") public var availability: String
    public init() { self.id = UUID().uuidString; self.walletID = nil; self.network = nil; self.availability = "unavailable" }
    init(_ value: WalletSummary) {
        self.init(); self.walletID = value.scope.walletID; self.network = value.scope.network.rawValue; self.availability = value.availability.rawValue
    }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Agent Wallet Result") }
}
public struct AgentWalletSnapshotQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentWalletSnapshot] { [] }
    public func suggestedEntities() async throws -> [AgentWalletSnapshot] { [] }
}

public struct AgentWalletPageSnapshot: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Wallet Page")
    public static let defaultQuery = AgentWalletPageSnapshotQuery()
    public let id: String
    @Property(title: "Wallets") public var wallets: [AgentWalletSnapshot]
    @Property(title: "Next Cursor") public var nextCursor: String?
    public init() {
        self.id = UUID().uuidString
        self.wallets = []
        self.nextCursor = nil
    }
    init(_ page: CapabilityPage<WalletSummary>) throws {
        self.init(); self.wallets = page.items.map(AgentWalletSnapshot.init); self.nextCursor = page.nextCursor
    }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Agent Wallet Page") }
}
public struct AgentWalletPageSnapshotQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentWalletPageSnapshot] { [] }
    public func suggestedEntities() async throws -> [AgentWalletPageSnapshot] { [] }
}

public struct AgentAccountDirectorySnapshot: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Account Page")
    public static let defaultQuery = AgentAccountDirectorySnapshotQuery()
    public let id: String
    @Property(title: "Accounts") public var accounts: [AgentAccountEntity]
    @Property(title: "Next Cursor") public var nextCursor: String?
    public init() {
        self.id = UUID().uuidString
        self.accounts = []
        self.nextCursor = nil
    }
    init(accounts: [AgentAccountEntity], nextCursor: String?) { self.init(); self.accounts = accounts; self.nextCursor = nextCursor }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Agent Account Page") }
}
public struct AgentAccountDirectorySnapshotQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentAccountDirectorySnapshot] { [] }
    public func suggestedEntities() async throws -> [AgentAccountDirectorySnapshot] { [] }
}

public struct AgentTransactionSnapshot: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Transaction")
    public static let defaultQuery = AgentTransactionSnapshotQuery()
    public let id: String
    @Property(title: "Transaction ID") public var transactionID: String?
    @Property(title: "Change (Satoshi)") public var deltaSatoshis: Int?
    @Property(title: "Confirmations") public var confirmations: Int?
    @Property(title: "Height") public var height: Int?
    @Property(title: "State") public var status: String
    public init() {
        self.id = UUID().uuidString
        self.transactionID = nil
        self.deltaSatoshis = nil
        self.confirmations = nil
        self.height = nil
        self.status = "unknown"
    }
    init(_ value: TransactionSummary) throws {
        self.init(); self.transactionID = value.transactionID
        self.deltaSatoshis = try value.deltaSatoshis.map(automationExact)
        self.confirmations = try value.confirmations.map(automationExact); self.height = try value.height.map(automationExact)
        self.status = value.status.rawValue
    }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Agent Transaction") }
}
public struct AgentTransactionSnapshotQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentTransactionSnapshot] { [] }
    public func suggestedEntities() async throws -> [AgentTransactionSnapshot] { [] }
}

public struct AgentActivityPageSnapshot: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Activity Page")
    public static let defaultQuery = AgentActivityPageSnapshotQuery()
    public let id: String
    @Property(title: "Transactions") public var transactions: [AgentTransactionSnapshot]
    @Property(title: "Account") public var account: AgentAccountEntity?
    @Property(title: "Next Cursor") public var nextCursor: String?
    @Property(title: "Fresh") public var fresh: Bool?
    @Property(title: "Complete") public var complete: Bool?
    @Property(title: "Observed At") public var observedAt: Int?
    @Property(title: "Chain Tip") public var chainTip: String?
    @Property(title: "Readiness") public var readiness: String
    @Property(title: "Blockers") public var blockers: [String]
    public init() {
        self.id = UUID().uuidString
        self.transactions = []
        self.account = nil
        self.nextCursor = nil
        self.fresh = nil
        self.complete = nil
        self.observedAt = nil
        self.chainTip = nil
        self.readiness = "unavailable"
        self.blockers = []
    }
    init(accountID: String, value: AccountPage<TransactionSummary>) throws {
        self.init(); self.account = AgentAccountEntity(id: accountID, network: value.account.wallet.network.rawValue)
        self.transactions = try value.page.items.map(AgentTransactionSnapshot.init); self.nextCursor = value.page.nextCursor
        self.fresh = value.observation.fresh; self.complete = value.observation.complete
        self.observedAt = try automationExact(value.observation.observedAt); self.chainTip = value.observation.chainTip
        self.readiness = value.readiness.state.rawValue; self.blockers = value.readiness.blockers.map(\.rawValue)
    }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Agent Activity Page") }
}
public struct AgentActivityPageSnapshotQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentActivityPageSnapshot] { [] }
    public func suggestedEntities() async throws -> [AgentActivityPageSnapshot] { [] }
}

public struct AgentUTXOSnapshot: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Unspent Output")
    public static let defaultQuery = AgentUTXOSnapshotQuery()
    public let id: String
    @Property(title: "Transaction ID") public var transactionID: String?
    @Property(title: "Output Index") public var outputIndex: Int?
    @Property(title: "Amount (Satoshi)") public var amountSatoshis: Int?
    @Property(title: "Reservation") public var reservation: String
    @Property(title: "Visible Operation ID") public var visibleOperationID: String?
    public init() {
        self.id = UUID().uuidString
        self.transactionID = nil
        self.outputIndex = nil
        self.amountSatoshis = nil
        self.reservation = "unavailable"
        self.visibleOperationID = nil
    }
    init(_ value: UTXOSummary) throws {
        self.init(); self.transactionID = value.outpoint.transactionID; self.outputIndex = try automationExact(value.outpoint.outputIndex)
        self.amountSatoshis = try automationExact(value.amountSatoshis)
        switch value.reservation {
        case .unreserved: self.reservation = "unreserved"
        case .visibleOperation(let id): self.reservation = "visibleOperation"; self.visibleOperationID = id
        case .otherOperation: self.reservation = "otherOperation"
        }
    }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Agent Unspent Output") }
}
public struct AgentUTXOSnapshotQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentUTXOSnapshot] { [] }
    public func suggestedEntities() async throws -> [AgentUTXOSnapshot] { [] }
}

public struct AgentUTXOPageSnapshot: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Unspent Output Page")
    public static let defaultQuery = AgentUTXOPageSnapshotQuery()
    public let id: String
    @Property(title: "Unspent Outputs") public var utxos: [AgentUTXOSnapshot]
    @Property(title: "Account") public var account: AgentAccountEntity?
    @Property(title: "Next Cursor") public var nextCursor: String?
    @Property(title: "Fresh") public var fresh: Bool?
    @Property(title: "Complete") public var complete: Bool?
    @Property(title: "Observed At") public var observedAt: Int?
    @Property(title: "Chain Tip") public var chainTip: String?
    @Property(title: "Readiness") public var readiness: String
    @Property(title: "Blockers") public var blockers: [String]
    public init() {
        self.id = UUID().uuidString
        self.utxos = []
        self.account = nil
        self.nextCursor = nil
        self.fresh = nil
        self.complete = nil
        self.observedAt = nil
        self.chainTip = nil
        self.readiness = "unavailable"
        self.blockers = []
    }
    init(accountID: String, value: AccountPage<UTXOSummary>) throws {
        self.init(); self.account = AgentAccountEntity(id: accountID, network: value.account.wallet.network.rawValue)
        self.utxos = try value.page.items.map(AgentUTXOSnapshot.init); self.nextCursor = value.page.nextCursor
        self.fresh = value.observation.fresh; self.complete = value.observation.complete
        self.observedAt = try automationExact(value.observation.observedAt); self.chainTip = value.observation.chainTip
        self.readiness = value.readiness.state.rawValue; self.blockers = value.readiness.blockers.map(\.rawValue)
    }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Agent Unspent Output Page") }
}
public struct AgentUTXOPageSnapshotQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentUTXOPageSnapshot] { [] }
    public func suggestedEntities() async throws -> [AgentUTXOPageSnapshot] { [] }
}

public struct AgentOperationSnapshot: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Operation Result")
    public static let defaultQuery = AgentOperationSnapshotQuery()
    public let id: String
    @Property(title: "Retained Request") public var request: AgentRequestHandleEntity?
    @Property(title: "Receive Request") public var receiveRequest: AgentReceiveRequestEntity?
    @Property(title: "Payment") public var payment: AgentPaymentOperationEntity?
    @Property(title: "Operation ID") public var operationID: String?
    @Property(title: "Network") public var network: String?
    @Property(title: "Action") public var effect: String?
    @Property(title: "State") public var state: String
    @Property(title: "Close Reason") public var closeReason: String?
    @Property(title: "Blocker") public var blocker: String?
    @Property(title: "Allocated Address") public var address: String?
    @Property(title: "Request Destination") public var requestedDestinationAddress: String?
    @Property(title: "Canonical Destination") public var canonicalDestinationAddress: String?
    @Property(title: "Amount (Satoshi)") public var amountSatoshis: Int?
    @Property(title: "Fee (Satoshi)") public var feeSatoshis: Int?
    @Property(title: "Fee Rate (Satoshi Per Byte)") public var feeRateSatoshisPerByte: Int?
    @Property(title: "Fresh") public var fresh: Bool?
    @Property(title: "Complete") public var complete: Bool?
    @Property(title: "Observed At") public var observedAt: Int?
    @Property(title: "Chain Tip") public var chainTip: String?
    @Property(title: "Account Restriction") public var accountRestriction: String?
    @Property(title: "Unresolved Liability") public var liabilityUnresolved: Bool?
    @Property(title: "Ordinary Admissions") public var ordinaryAdmissions: Int?
    @Property(title: "Transaction ID") public var transactionID: String?
    @Property(title: "Evidence Support") public var evidenceSupport: String?
    @Property(title: "Evidence Revision") public var evidenceRevision: Int?
    @Property(title: "Latest Attempt Outcome") public var latestAttemptOutcome: String?
    @Property(title: "Latest Attempt Route") public var latestAttemptRoute: String?
    @Property(title: "Latest Attempt Number") public var latestAttemptNumber: Int?
    @Property(title: "Next Eligible At") public var nextEligibleAt: Int?
    @Property(title: "Lease Deadline") public var leaseDeadline: Int?
    @Property(title: "Request Expires At") public var expiresAt: Int?
    @Property(title: "Last Reconciled At") public var lastReconciliationAt: Int?
    @Property(title: "Preview Digest") public var previewDigest: String?
    public init() {
        self.id = UUID().uuidString
        self.request = nil
        self.receiveRequest = nil
        self.payment = nil
        self.operationID = nil
        self.network = nil
        self.effect = nil
        self.state = "unavailable"
        self.closeReason = nil
        self.blocker = nil
        self.address = nil
        self.requestedDestinationAddress = nil
        self.canonicalDestinationAddress = nil
        self.amountSatoshis = nil
        self.feeSatoshis = nil
        self.feeRateSatoshisPerByte = nil
        self.fresh = nil
        self.complete = nil
        self.observedAt = nil
        self.chainTip = nil
        self.accountRestriction = nil
        self.liabilityUnresolved = nil
        self.ordinaryAdmissions = nil
        self.transactionID = nil
        self.evidenceSupport = nil
        self.evidenceRevision = nil
        self.latestAttemptOutcome = nil
        self.latestAttemptRoute = nil
        self.latestAttemptNumber = nil
        self.nextEligibleAt = nil
        self.leaseDeadline = nil
        self.expiresAt = nil
        self.lastReconciliationAt = nil
        self.previewDigest = nil
    }
    init(handleID: String, operation: OperationProjection) throws {
        self.init()
        let network = operation.identity.selector.account.wallet.network
        self.request = AgentRequestHandleEntity(id: handleID, effect: operation.effect, network: network)
        self.operationID = operation.identity.selector.operationID; self.network = network.rawValue; self.effect = operation.effect.rawValue
        var observation: SnapshotObservation?
        switch operation {
        case .synchronization(let value):
            self.state = value.state.rawValue; self.closeReason = value.closeReason?.rawValue; self.blocker = value.blocker?.rawValue
            observation = value.observation
        case .receive(let value):
            self.receiveRequest = AgentReceiveRequestEntity(id: handleID, network: network)
            self.state = value.state.rawValue; self.closeReason = value.closeReason?.rawValue; self.blocker = value.blocker?.rawValue
            self.address = value.allocation?.address
        case .payment(let value):
            self.payment = AgentPaymentOperationEntity(id: handleID, network: network)
            self.state = value.state.rawValue; self.closeReason = value.terminalReason?.rawValue; self.blocker = value.blocker?.rawValue
            self.requestedDestinationAddress = value.request.destinationAddress
            self.canonicalDestinationAddress = value.preview?.canonicalDestinationAddress
            self.amountSatoshis = try automationExact(value.request.amountSatoshis)
            self.feeSatoshis = try value.preview.map { try automationExact($0.feeSatoshis) }
            self.feeRateSatoshisPerByte = try automationExact(value.request.feeRateSatoshisPerByte)
            self.expiresAt = try value.request.expiresAt.map(automationExact)
            self.accountRestriction = value.accountRestriction.rawValue; self.liabilityUnresolved = value.liabilityUnresolved
            self.ordinaryAdmissions = try automationExact(value.ordinaryAdmissions); self.transactionID = value.transactionID
            self.evidenceSupport = value.evidence.support.rawValue; self.evidenceRevision = try automationExact(value.evidence.revision)
            observation = value.evidence.observation
            self.latestAttemptOutcome = value.latestAttempt?.outcome.rawValue; self.latestAttemptRoute = value.latestAttempt?.route.rawValue
            self.latestAttemptNumber = try value.latestAttempt.map { try automationExact($0.number) }
            self.nextEligibleAt = try value.latestAttempt?.nextEligibleAt.map(automationExact)
            self.leaseDeadline = try value.preview.map { try automationExact($0.leaseDeadline) }
            self.lastReconciliationAt = try value.lastReconciliationAt.map(automationExact); self.previewDigest = value.preview?.templateDigest
        }
        self.fresh = observation?.fresh; self.complete = observation?.complete
        self.observedAt = try observation.map { try automationExact($0.observedAt) }; self.chainTip = observation?.chainTip
    }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Agent Operation Result") }
}
public struct AgentOperationSnapshotQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentOperationSnapshot] { [] }
    public func suggestedEntities() async throws -> [AgentOperationSnapshot] { [] }
}

public struct AgentReviewRouteReceipt: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Review Route Receipt")
    public static let defaultQuery = AgentReviewRouteReceiptQuery()
    public let id: String
    @Property(title: "Retained Request") public var request: AgentRequestHandleEntity?
    @Property(title: "Operation ID") public var operationID: String?
    @Property(title: "Route Accepted") public var routeAccepted: Bool
    public init() {
        self.id = UUID().uuidString
        self.request = nil
        self.operationID = nil
        self.routeAccepted = false
    }
    init(handleID: String, acknowledgment: AgentAutomationReviewAcknowledgment) {
        self.init(); self.operationID = acknowledgment.request.operation.operationID; self.routeAccepted = acknowledgment.routeAccepted
        self.request = AgentRequestHandleEntity(id: handleID, effect: .preparePayment, network: acknowledgment.request.owner.wallet.network)
    }
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Agent Review Route Receipt") }
}
public struct AgentReviewRouteReceiptQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentReviewRouteReceipt] { [] }
    public func suggestedEntities() async throws -> [AgentReviewRouteReceipt] { [] }
}
