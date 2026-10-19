// AgentRequestEntities.swift

import AgentValues
import AppIntents
import Foundation

public struct AgentRequestHandleEntity: AppEntity, Sendable, Hashable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Retained Agent Request")
    public static let defaultQuery = AgentRequestHandleQuery()
    public let id: String
    @Property(title: "Action") public var action: String
    @Property(title: "Network") public var network: String
    init(_ retained: RetainedAgentAutomationRequest) {
        self.id = retained.handleID; self.action = retained.payload.effect.rawValue; self.network = retained.owner.wallet.network.rawValue
    }
    init(id: String, effect: EffectKind, network: WalletNetwork) { self.id = id; self.action = effect.rawValue; self.network = network.rawValue }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Agent Request", subtitle: "\(network) · \(String(id.suffix(8)))")
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
public struct AgentRequestHandleQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentRequestHandleEntity] {
        try await AgentAutomationAdapter(dependency: dependency).retainedRequests(identifiers: identifiers).map(AgentRequestHandleEntity.init)
    }
    public func suggestedEntities() async throws -> [AgentRequestHandleEntity] {
        try await AgentAutomationAdapter(dependency: dependency).retainedRequests().map(AgentRequestHandleEntity.init)
    }
}

public struct AgentReceiveRequestEntity: AppEntity, Sendable, Hashable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Receive Request")
    public static let defaultQuery = AgentReceiveRequestQuery()
    public let id: String
    @Property(title: "Network") public var network: String
    init(id: String, network: WalletNetwork) { self.id = id; self.network = network.rawValue }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Agent Receive Request", subtitle: "\(network) · \(String(id.suffix(8)))")
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
public struct AgentReceiveRequestQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentReceiveRequestEntity] { try await values(identifiers) }
    public func suggestedEntities() async throws -> [AgentReceiveRequestEntity] { try await values(nil) }
    private func values(_ identifiers: [String]?) async throws -> [AgentReceiveRequestEntity] {
        try await AgentAutomationAdapter(dependency: dependency).retainedRequests(identifiers: identifiers, effect: .createReceiveRequest)
            .filter { $0.operation != nil }.map { AgentReceiveRequestEntity(id: $0.handleID, network: $0.owner.wallet.network) }
    }
}

public struct AgentPaymentOperationEntity: AppEntity, Sendable, Hashable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Payment")
    public static let defaultQuery = AgentPaymentOperationQuery()
    public let id: String
    @Property(title: "Network") public var network: String
    init(id: String, network: WalletNetwork) { self.id = id; self.network = network.rawValue }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Agent Payment", subtitle: "\(network) · \(String(id.suffix(8)))")
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
public struct AgentPaymentOperationQuery: EntityQuery {
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AgentPaymentOperationEntity] { try await values(identifiers) }
    public func suggestedEntities() async throws -> [AgentPaymentOperationEntity] { try await values(nil) }
    private func values(_ identifiers: [String]?) async throws -> [AgentPaymentOperationEntity] {
        try await AgentAutomationAdapter(dependency: dependency).retainedRequests(identifiers: identifiers, effect: .preparePayment)
            .filter { $0.operation != nil }.map { AgentPaymentOperationEntity(id: $0.handleID, network: $0.owner.wallet.network) }
    }
}
