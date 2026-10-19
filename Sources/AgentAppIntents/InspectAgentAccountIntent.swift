// InspectAgentAccountIntent.swift

import AppIntents
import Foundation

/// Explicit cached disclosure; picker resolution and repeated inspection never synchronize the account.
public struct InspectAgentAccountIntent: AppIntent {
    public static let title: LocalizedStringResource = "Inspect Agent Account"
    public static let description = IntentDescription("Inspect cached Agent account funds and their actual freshness without starting synchronization or moving funds.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Agent Account") public var account: AgentAccountEntity
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("Inspect \(\.$account)") }
    public init() {}
    public init(account: AgentAccountEntity) { self.account = account }
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentAccountSnapshot> {
        let value = try await AgentAutomationReader(access: dependency.access).inspect(accountID: account.id)
        return .result(value: value)
    }
}
