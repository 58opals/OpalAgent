#if DEBUG
import AgentClient
import AgentValues
import Foundation
@testable import AgentServiceCore

/// Explicit owner-only recovery composition. This never qualifies assembly, MCP or native IPC.
/// Ordinary assembly reopen failures are propagated and never select this path automatically.
final class FixtureRecoveryRuntime: OwnerControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var store: DurableWalletStore?
    private var service: OwnerControlService?
    private let connection: OwnerConnectionContext
    init(directory: URL, group: String, keys: FixtureKeychainOperations, policy: AuthorityPolicy,
         manifest: FixtureStoreManifest, consent: any OwnerConsentProvider, clock: FixtureClock, inspection: FixtureInspection) throws {
        let scope = try WalletStoreScope.read(in: directory)
        // Nonsecret scope metadata only locates custody. An in-place replacement cannot
        // redirect this explicit recovery owner to another synthetic key/anchor namespace.
        guard scope.installationID.uuidString == manifest.installationID,
              scope.walletID.uuidString == manifest.walletID else { throw FixtureFailure.fixtureUnavailable }
        let anchor = try KeychainContinuityAnchorStore(accessGroup: group,
            installationID: scope.installationID.uuidString, walletID: scope.walletID.uuidString, operations: keys)
        let store = try DurableWalletStore(directory: directory, anchor: anchor, policy: policy)
        guard let state = try store.continuity.inspectRecoveryState(), let custody = state.custody,
              state.installationID == scope.installationID.uuidString,
              state.authorization.walletID == scope.walletID.uuidString,
              custody.walletID == scope.walletID.uuidString,
              custody.accountID == manifest.accountID, custody.profile == manifest.profile,
              custody.network == "mainnet" else { throw FixtureFailure.fixtureUnavailable }
        let vault = WalletSeedVault(keys: try KeychainWrappingKeySource(accessGroup: group,
            walletID: scope.walletID.uuidString, operations: keys), accounts: FixtureSeedAccountProvider())
        self.store = store
        self.connection = OwnerConnectionContext(connectionID: UUID().uuidString,
            peer: PeerEvidence(identity: policy.owner, signatureValidated: true))
        self.service = OwnerControlService(continuity: store.continuity, policy: policy,
            authority: { try store.integrationAuthority() }, vault: vault, accounts: FixtureUnavailableBoundary(),
            consent: consent, clock: clock)
        inspection.bind(store.continuity)
    }
    func rawState() throws -> CanonicalState {
        try lock.withLock {
            guard let value = try store?.continuity.inspectRecoveryState() else { throw FixtureFailure.fixtureUnavailable }
            return value
        }
    }
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        switch request.call {
        case .status, .listAccounts, .listPayments, .inspectRecovery, .recoverJournal, .enableWallet,
             .paymentStatus, .relayReceipt, .authorizeExactRelay, .rotateGrant, .revokeGrant, .enrollIntegration: break
        default: throw ServiceProblem(.unavailable)
        }
        let service = try lock.withLock { guard let service else { throw FixtureFailure.fixtureUnavailable }; return service }
        return try await service.send(request, connection: connection)
    }
    func shutdown() async { connection.invalidate(); lock.withLock { service = nil; store = nil } }
}
#endif
