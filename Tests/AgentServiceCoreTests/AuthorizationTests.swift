import CryptoKit
import Foundation
import OpalDiagnostics
import Testing
@testable import AgentServiceCore

struct AuthorizationTests {
    @Test func issuedCredentialIsReturnedOnceAndOnlyItsDigestIsStored() throws {
        let fixture = try authorizationFixture()
        #expect(fixture.credential.rawValue.count == 32)
        #expect(fixture.authority.ledger.grants[0].credentialDigest == Data(SHA256.hash(data: fixture.credential.rawValue)))
        #expect(fixture.authority.ledger.grants[0].credentialDigest != fixture.credential.rawValue)
        #expect(try fixture.authority.authorize(
            session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
            operation: readOperation, now: 100
        ) == fixture.credential.principal)
        #expect(throws: AuthorizationFailure.invalidCredential) {
            try fixture.authority.authenticate(
                connectionID: "connection-b", peer: bridgePeer,
                credential: Data("grant-a".utf8), now: 100
            )
        }
    }

    @Test(arguments: InvalidPeer.allCases)
    private func exactBridgeSignatureAndCredentialPossessionAreRequired(failure: InvalidPeer) throws {
        let fixture = try authorizationFixture()
        #expect(throws: AuthorizationFailure.untrustedPeer) {
            try fixture.authority.authenticate(
                connectionID: "connection-a", peer: failure.peer,
                credential: fixture.credential.rawValue, now: 100
            )
        }
        #expect(throws: AuthorizationFailure.untrustedPeer) {
            try fixture.authority.authorize(
                session: fixture.session, connectionID: "connection-a", peer: failure.peer,
                operation: readOperation, now: 100
            )
        }
    }

    @Test func wrongCredentialCannotUseAnOtherwiseTrustedBridge() throws {
        let fixture = try authorizationFixture()
        var wrong = fixture.credential.rawValue
        wrong[0] ^= 1
        #expect(throws: AuthorizationFailure.invalidCredential) {
            try fixture.authority.authenticate(
                connectionID: "connection-a", peer: bridgePeer, credential: wrong, now: 100
            )
        }
    }

    @Test(arguments: InvalidOwnerAuthentication.allCases)
    private func ownerAuthenticationMustBeSuccessfulFreshAndFromTheOwner(failure: InvalidOwnerAuthentication) throws {
        var authority = authorizationAuthority()
        #expect(throws: failure.expectedFailure) {
            try authority.issueGrant(
                id: "grant-a", integrationID: "integration-a", accountIDs: ["account-a"],
                capabilities: ["read"], expiresAt: 200, owner: failure.evidence, now: 100
            )
        }
        #expect(authority.ledger.grants.isEmpty)
    }

    @Test func anActiveIntegrationCannotReceiveASecondGrant() throws {
        var fixture = try authorizationFixture()
        let originalLedger = fixture.authority.ledger
        #expect(throws: AuthorizationFailure.invalidRequest) {
            try fixture.authority.issueGrant(
                id: "grant-b", integrationID: "integration-a", accountIDs: ["account-a"],
                capabilities: ["read"], expiresAt: nil,
                owner: ownerAuthentication(at: 100), now: 100
            )
        }
        #expect(fixture.authority.ledger == originalLedger)
    }

    @Test func ownerAuthenticationAtTheFreshnessLimitIsAccepted() throws {
        var authority = authorizationAuthority()
        _ = try authority.issueGrant(
            id: "grant-a", integrationID: "integration-a", accountIDs: ["account-a"],
            capabilities: ["read"], expiresAt: nil,
            owner: ownerAuthentication(at: 40), now: 100
        )
        #expect(authority.ledger.grants.count == 1)
    }

    @Test(arguments: outOfScopeOperations)
    func everyOperationChecksWalletNetworkAccountAndCapability(operation: AuthorizationOperation) throws {
        let fixture = try authorizationFixture()
        #expect(throws: AuthorizationFailure.scopeDenied) {
            try fixture.authority.authorize(
                session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                operation: operation, now: 100
            )
        }
        #expect(throws: AuthorizationFailure.scopeDenied) {
            try fixture.authority.authorizeResult(
                session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                resultOwner: fixture.credential.principal, operation: operation, now: 100
            )
        }
    }

    @Test func reconnectRequiresCredentialPossessionOnTheNewConnection() throws {
        let fixture = try authorizationFixture()
        #expect(throws: AuthorizationFailure.staleSession) {
            try fixture.authority.authorize(
                session: fixture.session, connectionID: "connection-b", peer: bridgePeer,
                operation: readOperation, now: 100
            )
        }
        let reconnected = try fixture.authority.authenticate(
            connectionID: "connection-b", peer: bridgePeer,
            credential: fixture.credential.rawValue, now: 100
        )
        #expect(try fixture.authority.authorize(
            session: reconnected, connectionID: "connection-b", peer: bridgePeer,
            operation: readOperation, now: 100
        ) == fixture.credential.principal)
    }

    @Test func rotationPreservesThePrincipalAndRejectsOldCredentialsAndSessions() throws {
        var fixture = try authorizationFixture()
        let rotated = try fixture.authority.rotateGrant(id: "grant-a", owner: ownerAuthentication(at: 100), now: 100)
        #expect(rotated.principal == fixture.credential.principal)
        #expect(rotated.rawValue != fixture.credential.rawValue)
        #expect(fixture.authority.ledger.grants[0].credentialGeneration == 2)
        #expect(throws: AuthorizationFailure.invalidCredential) {
            try fixture.authority.authenticate(
                connectionID: "connection-b", peer: bridgePeer,
                credential: fixture.credential.rawValue, now: 100
            )
        }
        #expect(throws: AuthorizationFailure.staleSession) {
            try fixture.authority.authorize(
                session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                operation: readOperation, now: 100
            )
        }
        let session = try fixture.authority.authenticate(
            connectionID: "connection-b", peer: bridgePeer, credential: rotated.rawValue, now: 100
        )
        #expect(try fixture.authority.authorizeResult(
            session: session, connectionID: "connection-b", peer: bridgePeer,
            resultOwner: fixture.credential.principal, operation: readOperation, now: 100
        ) == fixture.credential.principal)
    }

    @Test func revocationRejectsReconnectOperationsAndResultDisclosure() throws {
        var fixture = try authorizationFixture()
        try fixture.authority.revokeGrant(id: "grant-a", owner: ownerAuthentication(at: 100), now: 100)
        #expect(fixture.authority.ledger.grants.count == 1)
        #expect(throws: AuthorizationFailure.revoked) {
            try fixture.authority.authenticate(
                connectionID: "connection-b", peer: bridgePeer,
                credential: fixture.credential.rawValue, now: 100
            )
        }
        #expect(throws: AuthorizationFailure.revoked) {
            try fixture.authority.authorize(
                session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                operation: readOperation, now: 100
            )
        }
        #expect(throws: AuthorizationFailure.revoked) {
            try fixture.authority.authorizeResult(
                session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                resultOwner: fixture.credential.principal, operation: readOperation, now: 100
            )
        }
    }

    @Test func expirationIsCheckedAtTheBoundaryOnEveryUse() throws {
        let fixture = try authorizationFixture()
        #expect(throws: AuthorizationFailure.expired) {
            try fixture.authority.authenticate(
                connectionID: "connection-b", peer: bridgePeer,
                credential: fixture.credential.rawValue, now: 200
            )
        }
        #expect(throws: AuthorizationFailure.expired) {
            try fixture.authority.authorize(
                session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                operation: readOperation, now: 200
            )
        }
        #expect(throws: AuthorizationFailure.expired) {
            try fixture.authority.authorizeResult(
                session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                resultOwner: fixture.credential.principal, operation: readOperation, now: 200
            )
        }
    }

    @Test func observedExpirationRemainsTerminalAcrossSerializationAndEarlierClocks() throws {
        var fixture = try authorizationFixture()
        #expect(fixture.authority.observeExpirations(now: 200) == ["grant-a"])
        #expect(fixture.authority.observeExpirations(now: 100).isEmpty)
        let ledger = try JSONDecoder().decode(AuthorizationLedger.self,
            from: JSONEncoder().encode(fixture.authority.ledger))
        #expect(ledger.grants[0].expiredObserved)
        var restored = authorizationAuthority(ledger: ledger)
        #expect(throws: AuthorizationFailure.expired) {
            try restored.authenticate(connectionID: "earlier", peer: bridgePeer,
                credential: fixture.credential.rawValue, now: 100)
        }
        #expect(throws: AuthorizationFailure.expired) {
            try restored.authorize(session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                operation: readOperation, now: 100)
        }
        #expect(throws: AuthorizationFailure.expired) {
            try restored.rotateGrant(id: "grant-a", owner: ownerAuthentication(at: 100), now: 100)
        }
        #expect(restored.ledger.grants[0].expiredObserved)
    }

    @Test func walletGenerationInvalidatesExistingSessions() throws {
        let fixture = try authorizationFixture()
        var ledger = fixture.authority.ledger
        ledger.generation += 1
        let authority = authorizationAuthority(ledger: ledger)
        #expect(throws: AuthorizationFailure.staleSession) {
            try authority.authorize(
                session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                operation: readOperation, now: 100
            )
        }
        let session = try authority.authenticate(
            connectionID: "connection-b", peer: bridgePeer,
            credential: fixture.credential.rawValue, now: 100
        )
        #expect(try authority.authorize(
            session: session, connectionID: "connection-b", peer: bridgePeer,
            operation: readOperation, now: 100
        ) == fixture.credential.principal)
    }

    @Test func resultAbsenceAndForeignOwnershipHaveTheSameUnavailableOutcome() throws {
        let fixture = try authorizationFixture()
        let owners: [IntegrationPrincipal?] = [
            nil,
            IntegrationPrincipal(grantID: "grant-b", integrationID: "integration-a"),
            IntegrationPrincipal(grantID: "grant-a", integrationID: "integration-b")
        ]
        for owner in owners {
            #expect(throws: AuthorizationFailure.unavailable) {
                try fixture.authority.authorizeResult(
                    session: fixture.session, connectionID: "connection-a", peer: bridgePeer,
                    resultOwner: owner, operation: readOperation, now: 100
                )
            }
        }
    }

    @Test func bridgeCredentialDoesNotAuthorizeOwnerMutations() throws {
        var fixture = try authorizationFixture()
        let bridgeOwner = OwnerAuthenticationEvidence(peer: bridgePeer, authenticationSucceeded: true, authenticatedAt: 100)
        #expect(throws: AuthorizationFailure.untrustedPeer) {
            try fixture.authority.rotateGrant(id: "grant-a", owner: bridgeOwner, now: 100)
        }
        #expect(throws: AuthorizationFailure.untrustedPeer) {
            try fixture.authority.revokeGrant(id: "grant-a", owner: bridgeOwner, now: 100)
        }
        #expect(!fixture.authority.ledger.grants[0].revoked)
        #expect(fixture.authority.ledger.grants[0].credentialGeneration == 1)
    }

    @Test func canonicalRecoveryRetainsGrantHistoryAndDisablesAllVerifiers() throws {
        var fixture = try authorizationFixture()
        _ = try fixture.authority.issueGrant(
            id: "grant-0", integrationID: "integration-b", accountIDs: ["z", "a", "z"],
            capabilities: ["write", "read", "write"], expiresAt: nil,
            owner: ownerAuthentication(at: 100), now: 100
        )
        let canonical = fixture.authority.ledger.canonicalized()
        #expect(canonical.grants.map(\.id) == ["grant-0", "grant-a"])
        #expect(canonical.grants[0].accountIDs == ["a", "z"])
        #expect(canonical.grants[0].capabilities == ["read", "write"])
        let recovered = canonical.disablingAllGrants()
        #expect(recovered.generation == canonical.generation)
        #expect(recovered.grants.map(\.id) == canonical.grants.map(\.id))
        #expect(recovered.grants.map(\.credentialDigest) == canonical.grants.map(\.credentialDigest))
        #expect(recovered.grants.allSatisfy { $0.revoked })
        #expect(try JSONDecoder().decode(AuthorizationLedger.self, from: JSONEncoder().encode(recovered)) == recovered)
        let authority = authorizationAuthority(ledger: recovered)
        #expect(throws: AuthorizationFailure.revoked) {
            try authority.authenticate(
                connectionID: "connection-b", peer: bridgePeer,
                credential: fixture.credential.rawValue, now: 100
            )
        }
    }
}

private let bridgeIdentity = SignedPeerIdentity(teamIdentifier: "team", signingIdentifier: "bridge")
private let ownerIdentity = SignedPeerIdentity(teamIdentifier: "team", signingIdentifier: "owner")
private let bridgePeer = PeerEvidence(identity: bridgeIdentity, signatureValidated: true)
private let ownerPeer = PeerEvidence(identity: ownerIdentity, signatureValidated: true)
private let readOperation = AuthorizationOperation(walletID: "wallet-a", network: "test-network", accountID: "account-a", capability: "read")
private let outOfScopeOperations = [
    AuthorizationOperation(walletID: "wallet-b", network: "test-network", accountID: "account-a", capability: "read"),
    AuthorizationOperation(walletID: "wallet-a", network: "other-network", accountID: "account-a", capability: "read"),
    AuthorizationOperation(walletID: "wallet-a", network: "test-network", accountID: "account-b", capability: "read"),
    AuthorizationOperation(walletID: "wallet-a", network: "test-network", accountID: "account-a", capability: "write")
]

private func ownerAuthentication(at time: Int64) -> OwnerAuthenticationEvidence {
    OwnerAuthenticationEvidence(peer: ownerPeer, authenticationSucceeded: true, authenticatedAt: time)
}

private func authorizationAuthority(ledger: AuthorizationLedger? = nil) -> AuthorizationAuthority {
    AuthorizationAuthority(
        ledger: ledger ?? AuthorizationLedger(walletID: "wallet-a", network: "test-network", generation: 1, grants: []),
        expectedBridgeIdentity: bridgeIdentity, trustedOwnerIdentity: ownerIdentity,
        maximumOwnerAuthenticationAge: 60
    )
}

private func authorizationFixture() throws -> (authority: AuthorizationAuthority, credential: IssuedCredential, session: AuthorizationSession) {
    var authority = authorizationAuthority()
    let credential = try authority.issueGrant(
        id: "grant-a", integrationID: "integration-a", accountIDs: ["account-a"],
        capabilities: ["read"], expiresAt: 200, owner: ownerAuthentication(at: 100), now: 100
    )
    let session = try authority.authenticate(
        connectionID: "connection-a", peer: bridgePeer, credential: credential.rawValue, now: 100
    )
    return (authority, credential, session)
}

private enum InvalidPeer: CaseIterable, Sendable {
    case unsigned, wrongTeam, wrongExecutable, missingIdentity

    var peer: PeerEvidence {
        switch self {
        case .unsigned: PeerEvidence(identity: bridgeIdentity, signatureValidated: false)
        case .wrongTeam: PeerEvidence(identity: SignedPeerIdentity(teamIdentifier: "other-team", signingIdentifier: "bridge"), signatureValidated: true)
        case .wrongExecutable: PeerEvidence(identity: ownerIdentity, signatureValidated: true)
        case .missingIdentity: PeerEvidence(identity: nil, signatureValidated: true)
        }
    }
}

private enum InvalidOwnerAuthentication: CaseIterable, Sendable {
    case wrongPeer, unsigned, failed, stale, future, overflow

    var evidence: OwnerAuthenticationEvidence {
        switch self {
        case .wrongPeer: OwnerAuthenticationEvidence(peer: bridgePeer, authenticationSucceeded: true, authenticatedAt: 100)
        case .unsigned: OwnerAuthenticationEvidence(peer: PeerEvidence(identity: ownerIdentity, signatureValidated: false), authenticationSucceeded: true, authenticatedAt: 100)
        case .failed: OwnerAuthenticationEvidence(peer: ownerPeer, authenticationSucceeded: false, authenticatedAt: 100)
        case .stale: ownerAuthentication(at: 39)
        case .future: ownerAuthentication(at: 101)
        case .overflow: ownerAuthentication(at: Int64.min)
        }
    }

    var expectedFailure: AuthorizationFailure {
        switch self {
        case .wrongPeer, .unsigned: .untrustedPeer
        case .failed, .stale, .future, .overflow: .ownerAuthenticationRequired
        }
    }
}


extension AuthorizationTests {
    @Test(arguments: [false, true])
    func diagnosticsObserveDenialsWithoutChangingAuthorizationOrHostConfiguration(enabled: Bool) throws {
        let configuration = enabled ? OpalDiagnostics.Configuration(
            subsystem: "com.58opals.agent.tests", categoryFilter: .enabled(["agent.authorization"]),
            bufferPolicy: .enabled(capacity: 4), routingPolicy: .disabled) : .init()
        try OpalDiagnostics.withConfiguration(configuration) {
            let fixture = try authorizationFixture()
            let ledger = fixture.authority.ledger
            #expect(throws: AuthorizationFailure.invalidCredential) {
                try fixture.authority.authenticate(connectionID: "connection-b", peer: bridgePeer,
                    credential: Data("private-credential-canary".utf8), now: 100)
            }
            #expect(fixture.authority.ledger == ledger)
            #expect(OpalDiagnostics.configuration == configuration)
            let records = OpalDiagnostics.recentRecords
            #expect(records.count == (enabled ? 1 : 0))
            if enabled {
                let record = try #require(records.first)
                #expect(record.category.rawValue == "agent.authorization" && record.event.rawValue == "authorization_denied")
                #expect(record.fields == [.publicField("reason", value: "invalid_credential")])
                #expect(UUID(uuidString: record.traceID?.rawValue ?? "") != nil)
            }
        }
    }
}
