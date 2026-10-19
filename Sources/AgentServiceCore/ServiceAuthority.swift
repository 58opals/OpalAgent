import AgentValues
import Foundation

/// Source-only service boundary. Peer evidence and inventories must come from trusted adapters.
struct AuthorityPolicy: Sendable {
    let bridge: SignedPeerIdentity
    let owner: SignedPeerIdentity
    let accountIDs: Set<String>
    let capabilities: Set<String>
    let ownerAuthenticationAge: Int64
    let appleIntegration: SignedPeerIdentity?
    init(bridge: SignedPeerIdentity, owner: SignedPeerIdentity, accountIDs: Set<String>, capabilities: Set<String>,
         ownerAuthenticationAge: Int64, appleIntegration: SignedPeerIdentity? = nil) {
        self.bridge = bridge; self.owner = owner; self.accountIDs = accountIDs; self.capabilities = capabilities
        self.ownerAuthenticationAge = ownerAuthenticationAge; self.appleIntegration = appleIntegration
    }
}

final class ServiceAuthority: Sendable {
    private let continuity: ContinuityCoordinator
    private let policy: AuthorityPolicy

    init(continuity: ContinuityCoordinator, policy: AuthorityPolicy) throws {
        _ = try continuity.startup()
        self.continuity = continuity
        self.policy = policy
    }

    func enroll(id: String, integrationID: String, accounts: [String], capabilities: [String],
                expiry: Int64?, owner: OwnerAuthenticationEvidence, now: Int64, peerProfile: IntegrationPeerProfile = .mcp) throws -> IssuedCredential {
        try withObservedExpirations(classification: "enrollment", now: now) { state, authority in
            let inventory = state.custody.map { Set([$0.accountID]) } ?? policy.accountIDs
            guard Set(accounts).isSubset(of: inventory),
                  Set(capabilities).isSubset(of: policy.capabilities) else {
                throw AuthorizationFailure.scopeDenied
            }
            return try authority.issueGrant(id: id, integrationID: integrationID,
                accountIDs: accounts, capabilities: capabilities, expiresAt: expiry, owner: owner, now: now, peerProfile: peerProfile)
        }
    }

    func rotate(id: String, owner: OwnerAuthenticationEvidence, now: Int64) throws -> IssuedCredential {
        try withObservedExpirations(classification: "rotation", now: now) { state, authority in
            let issued = try authority.rotateGrant(id: id, owner: owner, now: now)
            invalidateConsent(in: &state, grantID: id)
            return issued
        }
    }

    func revoke(id: String, owner: OwnerAuthenticationEvidence, now: Int64) throws {
        try withObservedExpirations(classification: "revocation", now: now) { state, authority in
            try authority.revokeGrant(id: id, owner: owner, now: now)
            invalidateConsent(in: &state, grantID: id)
        }
    }

    func expire(now: Int64) throws {
        try withObservedExpirations(classification: "expiry", now: now) { _, _ in }
    }

    func authenticate(connectionID: String, peer: PeerEvidence, credential: Data,
                      now: Int64) throws -> AuthorizationSession {
        try withObservedExpirations(classification: "authentication", now: now) { _, authority in
            try authority.authenticate(connectionID: connectionID, peer: peer, credential: credential, now: now)
        }
    }

    func result(requestID: String, session: AuthorizationSession, connectionID: String,
                peer: PeerEvidence, now: Int64) throws -> Data {
        try withObservedExpirations(classification: "resultDisclosure", now: now) { state, authority in
            // Unknown, foreign and unauthorized results have the same unavailable shape.
            do {
                guard let request = state.requests.first(where: { $0.id == requestID }),
                      request.principalID == session.principal.integrationID,
                      request.originGrantID == session.principal.grantID,
                      let paymentID = request.paymentID,
                      let payment = state.payments.first(where: { $0.id == paymentID }),
                      payment.originGrantID == session.principal.grantID else {
                    throw AuthorizationFailure.unavailable
                }
                try authority.authorizeResult(session: session, connectionID: connectionID,
                    peer: peer, resultOwner: session.principal,
                    operation: AuthorizationOperation(walletID: state.authorization.walletID,
                        network: payment.network, accountID: payment.accountID, capability: "read"), now: now)
                return request.result
            } catch {
                throw AuthorizationFailure.unavailable
            }
        }
    }

    private func withObservedExpirations<Output>(
        classification: String,
        now: Int64,
        operation: (inout CanonicalState, inout AuthorizationAuthority) throws -> Output
    ) throws -> Output {
        try continuity.transaction(classification: classification, mutation: { state -> Result<Output, any Error> in
            try requireEnabled(state)
            var authority = authority(for: state)
            for grantID in authority.observeExpirations(now: now) {
                invalidateConsent(in: &state, grantID: grantID)
            }
            let outcome = Result { try operation(&state, &authority) }
            state.authorization = authority.ledger
            return outcome
        }, projection: { _, outcome in
            try outcome.get()
        })
    }

    private func authority(for state: CanonicalState) -> AuthorizationAuthority {
        AuthorizationAuthority(ledger: state.authorization, expectedBridgeIdentity: policy.bridge,
            trustedOwnerIdentity: policy.owner, maximumOwnerAuthenticationAge: policy.ownerAuthenticationAge, expectedAppleIntegrationIdentity: policy.appleIntegration)
    }

    private func requireEnabled(_ state: CanonicalState) throws {
        guard state.mode == .enabled, state.history == .complete else {
            throw ContinuityError.recoveryRequired
        }
    }

    private func invalidateConsent(in state: inout CanonicalState, grantID: String) {
        state.invalidateUnsubmitted(grantID: grantID)
        let payments = Set(state.payments.filter { $0.originGrantID == grantID }.map(\.id))
        for index in state.approvals.indices where payments.contains(state.approvals[index].paymentID) {
            state.approvals[index].active = false
        }
    }
}
