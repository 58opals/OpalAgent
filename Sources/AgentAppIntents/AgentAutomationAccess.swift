// AgentAutomationAccess.swift

import AgentClient
import AgentValues
import AppIntents
import Foundation

/// Enrollment-bound context supplied by the host, never inferred from a picker or owner-wide query.
public struct AgentAutomationBinding: Codable, Sendable, Equatable {
    public let wallet: WalletScope
    public let integrationID: String
    public let grantID: String
    public let walletGeneration: UInt64
    public let credentialGeneration: UInt64
    public let accountIDs: [String]
    public let scopes: [IntegrationScope]

    public init(wallet: WalletScope, integrationID: String, grantID: String,
                walletGeneration: UInt64, credentialGeneration: UInt64,
                accountIDs: [String], scopes: [IntegrationScope]) throws {
        guard automationIdentifier(integrationID), automationIdentifier(grantID),
              walletGeneration > 0, credentialGeneration > 0,
              !accountIDs.isEmpty, accountIDs.count <= 40,
              accountIDs.allSatisfy(automationIdentifier), Set(accountIDs).count == accountIDs.count,
              !scopes.isEmpty, Set(scopes).count == scopes.count else { throw AgentAutomationFailure.invalidReference }
        self.wallet = wallet; self.integrationID = integrationID; self.grantID = grantID
        self.walletGeneration = walletGeneration; self.credentialGeneration = credentialGeneration
        self.accountIDs = accountIDs.sorted(); self.scopes = scopes.sorted { $0.rawValue < $1.rawValue }
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: AutomationFieldKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw AgentAutomationFailure.invalidReference }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(wallet: values.decode(WalletScope.self, forKey: .wallet),
                      integrationID: values.decode(String.self, forKey: .integrationID),
                      grantID: values.decode(String.self, forKey: .grantID),
                      walletGeneration: values.decode(UInt64.self, forKey: .walletGeneration),
                      credentialGeneration: values.decode(UInt64.self, forKey: .credentialGeneration),
                      accountIDs: values.decode([String].self, forKey: .accountIDs),
                      scopes: values.decode([IntegrationScope].self, forKey: .scopes))
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case wallet, integrationID, grantID, walletGeneration, credentialGeneration, accountIDs, scopes
    }
}

public struct AgentAutomationSession: Sendable {
    public let binding: AgentAutomationBinding
    public let client: CapabilityClient
    public init(binding: AgentAutomationBinding, client: CapabilityClient) {
        self.binding = binding; self.client = client
    }
}

/// The host owns credential access, current enrollment context and the known-unlocked privacy guard.
/// Implementations must return the dedicated integration channel, never an owner-control client.
public protocol AgentAutomationAccess: Sendable {
    func isKnownUnlocked() async -> Bool
    func openSession() async throws -> AgentAutomationSession
    /// Establish current authenticated service authority; allocating a client alone is not authentication.
    /// Then check current binding and known-unlocked host facts together in host-owned serialization.
    /// This is the final disclosure guard; do not suspend after reading those local facts.
    func validate(binding: AgentAutomationBinding) async throws
}

public struct UnavailableAgentAutomationAccess: AgentAutomationAccess {
    public init() {}
    public func isKnownUnlocked() async -> Bool { false }
    public func openSession() async throws -> AgentAutomationSession { throw AgentAutomationFailure.unavailable }
    public func validate(binding: AgentAutomationBinding) async throws { throw AgentAutomationFailure.unavailable }
}

/// Register this value in the main app before intent/query execution. The explicit default has no native fallback.
public struct AgentAutomationDependency: Sendable {
    public let access: any AgentAutomationAccess
    public let requests: any AgentAutomationRequestStore
    public let reviewNavigator: any AgentAutomationReviewNavigator
    public init(access: any AgentAutomationAccess = UnavailableAgentAutomationAccess(),
                requests: any AgentAutomationRequestStore = UnavailableAgentAutomationRequestStore(),
                reviewNavigator: any AgentAutomationReviewNavigator = UnavailableAgentAutomationReviewNavigator()) {
        self.access = access; self.requests = requests; self.reviewNavigator = reviewNavigator
    }
}

public enum AgentAutomationFailure: Error, Sendable, Equatable, CustomLocalizedStringResourceConvertible {
    case unavailable, locked, staleContext, invalidReference, scopeDenied, invalidResponse, requestUnavailable, localRetentionUnavailable
    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailable: "Agent automation is unavailable."
        case .locked: "Unlock this Mac to use Agent automation."
        case .staleContext: "Agent access changed. Resolve the reference again."
        case .invalidReference: "This Agent reference is unavailable."
        case .scopeDenied: "This Agent integration is not authorized for that action."
        case .invalidResponse: "The Agent response could not be verified."
        case .requestUnavailable: "The retained Agent request is unavailable. No replacement was created."
        case .localRetentionUnavailable: "The response reference could not be retained. The service may have acted; inspect or reuse the same retained request."
        }
    }
}

func automationIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 2048 && !value.unicodeScalars.contains {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
    }
}

private struct AutomationFieldKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    let intValue: Int? = nil
    init?(intValue: Int) { return nil }
}
