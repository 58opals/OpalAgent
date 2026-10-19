// AgentAccountSnapshot.swift

import AgentValues
import AppIntents
import Foundation

/// Explicit action output only. This type has no discoverable or re-resolvable financial query.
public struct AgentAccountSnapshot: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Account Snapshot")
    public static let defaultQuery = AgentAccountSnapshotQuery()
    public let id: String
    @Property(title: "Account") public var account: AgentAccountEntity?
    @Property(title: "Balance Available") public var balanceAvailable: Bool
    @Property(title: "Amount (Satoshi)") public var amountSatoshis: Int?
    @Property(title: "Fresh") public var fresh: Bool?
    @Property(title: "Complete") public var complete: Bool?
    @Property(title: "Observed At") public var observedAt: Int?
    @Property(title: "Chain Tip") public var chainTip: String?
    @Property(title: "Readiness") public var readiness: String
    @Property(title: "Blockers") public var blockers: [String]

    public init() {
        self.id = UUID().uuidString
        self.account = nil; self.balanceAvailable = false; self.amountSatoshis = nil
        self.fresh = nil; self.complete = nil; self.observedAt = nil; self.chainTip = nil
        self.readiness = "unavailable"; self.blockers = []
    }

    init(id: String, account: AgentAccountEntity, balance: BalanceProjection?, status: SyncStatusProjection) throws {
        self.id = id; self.account = account; self.balanceAvailable = balance != nil
        if let amount = balance?.totalSatoshis {
            guard let exact = Int(exactly: amount) else { throw AgentAutomationFailure.invalidResponse }
            self.amountSatoshis = exact
        } else { self.amountSatoshis = nil }
        self.fresh = status.observation?.fresh; self.complete = status.observation?.complete
        if let observedAt = status.observation?.observedAt {
            guard let exact = Int(exactly: observedAt) else { throw AgentAutomationFailure.invalidResponse }
            self.observedAt = exact
        } else { self.observedAt = nil }
        self.chainTip = status.observation?.chainTip
        self.readiness = status.readiness.state.rawValue
        self.blockers = status.readiness.blockers.map(\.rawValue)
    }
    public var displayRepresentation: DisplayRepresentation {
        if let account {
            DisplayRepresentation(title: "Agent Account Snapshot", subtitle: "\(account.network)")
        } else {
            DisplayRepresentation(title: "Agent Account Snapshot", subtitle: "Unavailable")
        }
    }
}

public struct AgentAccountSnapshotQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public init() {}
    public func entities(for identifiers: [AgentAccountSnapshot.ID]) async throws -> [AgentAccountSnapshot] { [] }
    public func suggestedEntities() async throws -> [AgentAccountSnapshot] { [] }
}
