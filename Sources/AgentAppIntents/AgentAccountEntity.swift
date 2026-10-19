// AgentAccountEntity.swift

import AppIntents
import Foundation

/// A neutral reference. It carries no balance, private alias, credential, or serialized authority.
public struct AgentAccountEntity: AppEntity, Sendable, Hashable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Account")
    public static let defaultQuery = AgentAccountQuery()
    public let id: String
    @Property(title: "Network") public var network: String

    init(id: String, network: String) { self.id = id; self.network = network }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Agent Account", subtitle: "\(network) · \(String(id.suffix(8)))")
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct AgentAccountQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public init() {}
    public func entities(for identifiers: [AgentAccountEntity.ID]) async throws -> [AgentAccountEntity] {
        try await AgentAutomationReader(access: dependency.access).accounts(identifiers: identifiers)
    }
    public func suggestedEntities() async throws -> [AgentAccountEntity] {
        try await AgentAutomationReader(access: dependency.access).accounts()
    }
}
