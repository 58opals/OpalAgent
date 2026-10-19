// AgentAutomationReader.swift

import AgentClient
import AgentValues
import Foundation

/// Bounded, observational mapping over the authenticated capability client. No preparation or owner fallback.
public struct AgentAutomationReader: Sendable {
    private let access: any AgentAutomationAccess
    public init(access: any AgentAutomationAccess = UnavailableAgentAutomationAccess()) { self.access = access }

    /// Resolves one service page of at most forty accounts. A cursor is never followed implicitly.
    public func accounts(identifiers: [String]? = nil) async throws -> [AgentAccountEntity] {
        if let identifiers {
            guard identifiers.count <= 40, Set(identifiers).count == identifiers.count,
                  identifiers.allSatisfy(automationIdentifier) else { throw AgentAutomationFailure.invalidReference }
        }
        let session = try await begin()
        let values = try await accountReferences(session)
        try await finish(session.binding)
        guard let identifiers else { return values.map(\.entity) }
        let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.entity.id, $0.entity) })
        return identifiers.compactMap { byID[$0] }
    }

    public func inspect(accountID: String) async throws -> AgentAccountSnapshot {
        guard automationIdentifier(accountID) else { throw AgentAutomationFailure.invalidReference }
        let session = try await begin()
        guard let reference = try await accountReferences(session).first(where: { $0.entity.id == accountID }) else {
            throw AgentAutomationFailure.invalidReference
        }
        guard case .getSyncStatus(let before) = try await session.client.call(.getSyncStatus(reference.scope)) else {
            throw AgentAutomationFailure.invalidResponse
        }
        var balance: BalanceProjection?
        if before.observation != nil {
            guard case .getBalance(let value) = try await session.client.call(.getBalance(reference.scope)),
                  case .getSyncStatus(let after) = try await session.client.call(.getSyncStatus(reference.scope)) else {
                throw AgentAutomationFailure.invalidResponse
            }
            guard before == after, value.observation == after.observation, value.readiness == after.readiness else {
                throw AgentAutomationFailure.staleContext
            }
            balance = value
        }
        try await finish(session.binding)
        let snapshotID = try automationIdentity([accountID, "snapshot"], encoded: before.observation)
        return try AgentAccountSnapshot(id: snapshotID, account: reference.entity, balance: balance, status: before)
    }

    private func begin() async throws -> AgentAutomationSession {
        guard await access.isKnownUnlocked() else { throw AgentAutomationFailure.locked }
        let session = try await access.openSession()
        guard session.binding.scopes.contains(.read) else { throw AgentAutomationFailure.scopeDenied }
        try await finish(session.binding)
        return session
    }
    private func finish(_ binding: AgentAutomationBinding) async throws {
        try Task.checkCancellation()
        guard await access.isKnownUnlocked() else { throw AgentAutomationFailure.locked }
        try await access.validate(binding: binding)
    }
    private func accountReferences(_ session: AgentAutomationSession) async throws -> [(entity: AgentAccountEntity, scope: AccountScope)] {
        let request = WalletPageRequest(wallet: session.binding.wallet, page: try PageRequest(limit: 40))
        guard case .listAccounts(let accounts) = try await session.client.call(.listAccounts(request)) else {
            throw AgentAutomationFailure.invalidResponse
        }
        guard accounts.wallet == session.binding.wallet, accounts.page.items.count <= 40,
              Set(accounts.page.items.map(\.scope)).count == accounts.page.items.count else {
            throw AgentAutomationFailure.invalidResponse
        }
        return try accounts.page.items.map { summary in
            guard summary.scope.wallet == session.binding.wallet,
                  session.binding.accountIDs.contains(summary.scope.accountID) else { throw AgentAutomationFailure.invalidResponse }
            return (AgentAccountEntity(id: try automationAccountID(binding: session.binding, account: summary.scope),
                                       network: summary.scope.wallet.network.rawValue), summary.scope)
        }
    }
}
