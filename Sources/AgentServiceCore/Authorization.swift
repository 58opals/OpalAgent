import CryptoKit
import Foundation
import Security

struct GrantRecord: Codable, Equatable, Sendable {
    var id: String
    var integrationID: String
    var accountIDs: [String]
    var capabilities: [String]
    var credentialDigest: Data
    var credentialGeneration: UInt64
    var expiresAt: Int64?
    var revoked: Bool
    var expiredObserved: Bool = false

    func canonicalized() -> Self {
        var result = self
        result.accountIDs = Array(Set(accountIDs)).sorted()
        result.capabilities = Array(Set(capabilities)).sorted()
        return result
    }
}

struct AuthorizationLedger: Codable, Equatable, Sendable {
    var walletID: String
    var network: String
    var generation: UInt64
    var grants: [GrantRecord]

    func canonicalized() -> Self {
        var result = self
        result.grants = grants.map { $0.canonicalized() }.sorted { $0.id < $1.id }
        return result
    }

    func disablingAllGrants() -> Self {
        var result = self
        for index in result.grants.indices {
            result.grants[index].revoked = true
        }
        return result.canonicalized()
    }
}

struct SignedPeerIdentity: Equatable, Sendable {
    let teamIdentifier: String
    let signingIdentifier: String
}

// Evidence comes from the hosting transport's trust boundary, never request metadata.
struct PeerEvidence: Equatable, Sendable {
    let identity: SignedPeerIdentity?
    let signatureValidated: Bool
}

struct OwnerAuthenticationEvidence: Sendable {
    let peer: PeerEvidence
    let authenticationSucceeded: Bool
    let authenticatedAt: Int64
    let authorizationCheck: @Sendable () throws -> Void
    init(peer: PeerEvidence, authenticationSucceeded: Bool, authenticatedAt: Int64,
         authorizationCheck: @escaping @Sendable () throws -> Void = {}) {
        self.peer = peer; self.authenticationSucceeded = authenticationSucceeded
        self.authenticatedAt = authenticatedAt; self.authorizationCheck = authorizationCheck
    }
}

struct IntegrationPrincipal: Codable, Equatable, Sendable {
    let grantID: String
    let integrationID: String
}

struct IssuedCredential: Sendable {
    let principal: IntegrationPrincipal
    let rawValue: Data
}

struct AuthorizationSession: Sendable {
    let principal: IntegrationPrincipal
    let connectionID: String
    let credentialGeneration: UInt64
    let walletGeneration: UInt64
    fileprivate let credentialDigest: Data
}

struct AuthorizationOperation: Sendable {
    let walletID: String
    let network: String
    let accountID: String
    let capability: String
}

enum AuthorizationFailure: Error, Equatable {
    case untrustedPeer
    case ownerAuthenticationRequired
    case invalidRequest
    case invalidCredential
    case revoked
    case expired
    case staleSession
    case scopeDenied
    case unavailable
    case randomnessUnavailable
}

struct AuthorizationAuthority: Sendable {
    private(set) var ledger: AuthorizationLedger
    let expectedBridgeIdentity: SignedPeerIdentity
    let trustedOwnerIdentity: SignedPeerIdentity
    let maximumOwnerAuthenticationAge: Int64

    init(
        ledger: AuthorizationLedger,
        expectedBridgeIdentity: SignedPeerIdentity,
        trustedOwnerIdentity: SignedPeerIdentity,
        maximumOwnerAuthenticationAge: Int64
    ) {
        self.ledger = ledger.canonicalized()
        self.expectedBridgeIdentity = expectedBridgeIdentity
        self.trustedOwnerIdentity = trustedOwnerIdentity
        self.maximumOwnerAuthenticationAge = maximumOwnerAuthenticationAge
    }

    func requireOwner(owner: OwnerAuthenticationEvidence, now: Int64) throws {
        try owner.authorizationCheck()
        try requirePeer(owner.peer, identity: trustedOwnerIdentity)
        let age = now.subtractingReportingOverflow(owner.authenticatedAt)
        guard owner.authenticationSucceeded,
              maximumOwnerAuthenticationAge >= 0,
              !age.overflow,
              age.partialValue >= 0,
              age.partialValue <= maximumOwnerAuthenticationAge else {
            throw AuthorizationFailure.ownerAuthenticationRequired
        }
    }

    mutating func issueGrant(
        id: String,
        integrationID: String,
        accountIDs: [String],
        capabilities: [String],
        expiresAt: Int64?,
        owner: OwnerAuthenticationEvidence,
        now: Int64
    ) throws -> IssuedCredential {
        try requireOwner(owner: owner, now: now)
        guard !id.isEmpty, !integrationID.isEmpty,
              !accountIDs.isEmpty, accountIDs.allSatisfy({ !$0.isEmpty }),
              !capabilities.isEmpty, capabilities.allSatisfy({ !$0.isEmpty }),
              !ledger.walletID.isEmpty, !ledger.network.isEmpty,
              !ledger.grants.contains(where: { $0.id == id }),
              !ledger.grants.contains(where: {
                  $0.integrationID == integrationID && !$0.revoked && !$0.expiredObserved &&
                      ($0.expiresAt.map { now < $0 } ?? true)
              }),
              expiresAt.map({ $0 > now }) ?? true else {
            throw AuthorizationFailure.invalidRequest
        }
        let credential = try Self.makeCredential()
        let grant = GrantRecord(
            id: id, integrationID: integrationID, accountIDs: accountIDs,
            capabilities: capabilities, credentialDigest: Self.digest(credential),
            credentialGeneration: 1, expiresAt: expiresAt, revoked: false
        ).canonicalized()
        ledger.grants.append(grant)
        ledger = ledger.canonicalized()
        return IssuedCredential(principal: grant.principal, rawValue: credential)
    }

    @discardableResult
    mutating func observeExpirations(now: Int64) -> [String] {
        var newlyExpired: [String] = []
        for index in ledger.grants.indices where !ledger.grants[index].expiredObserved &&
            ledger.grants[index].expiresAt.map({ now >= $0 }) == true {
            ledger.grants[index].expiredObserved = true
            newlyExpired.append(ledger.grants[index].id)
        }
        return newlyExpired
    }

    mutating func rotateGrant(
        id: String,
        owner: OwnerAuthenticationEvidence,
        now: Int64
    ) throws -> IssuedCredential {
        try requireOwner(owner: owner, now: now)
        let index = try grantIndex(id: id)
        try validateGrant(ledger.grants[index], now: now)
        guard ledger.grants[index].credentialGeneration < UInt64.max else {
            throw AuthorizationFailure.invalidRequest
        }
        let credential = try Self.makeCredential()
        ledger.grants[index].credentialDigest = Self.digest(credential)
        ledger.grants[index].credentialGeneration += 1
        return IssuedCredential(principal: ledger.grants[index].principal, rawValue: credential)
    }

    mutating func revokeGrant(id: String, owner: OwnerAuthenticationEvidence, now: Int64) throws {
        try requireOwner(owner: owner, now: now)
        let index = try grantIndex(id: id)
        ledger.grants[index].revoked = true
    }

    func authenticate(
        connectionID: String,
        peer: PeerEvidence,
        credential: Data,
        now: Int64
    ) throws -> AuthorizationSession {
        try requirePeer(peer, identity: expectedBridgeIdentity)
        guard !connectionID.isEmpty else { throw AuthorizationFailure.invalidRequest }
        guard credential.count == 32 else { throw AuthorizationFailure.invalidCredential }
        let credentialDigest = Self.digest(credential)
        let matches = ledger.grants.filter { Self.equalDigest($0.credentialDigest, credentialDigest) }
        guard matches.count == 1, let grant = matches.first else {
            throw AuthorizationFailure.invalidCredential
        }
        try validateGrant(grant, now: now)
        return AuthorizationSession(
            principal: grant.principal, connectionID: connectionID,
            credentialGeneration: grant.credentialGeneration,
            walletGeneration: ledger.generation, credentialDigest: credentialDigest
        )
    }

    @discardableResult
    func authorize(
        session: AuthorizationSession,
        connectionID: String,
        peer: PeerEvidence,
        operation: AuthorizationOperation,
        now: Int64
    ) throws -> IntegrationPrincipal {
        try requirePeer(peer, identity: expectedBridgeIdentity)
        guard session.connectionID == connectionID,
              session.walletGeneration == ledger.generation else {
            throw AuthorizationFailure.staleSession
        }
        let index = try grantIndex(id: session.principal.grantID)
        let grant = ledger.grants[index]
        guard grant.principal == session.principal,
              grant.credentialGeneration == session.credentialGeneration,
              Self.equalDigest(grant.credentialDigest, session.credentialDigest) else {
            throw AuthorizationFailure.staleSession
        }
        try validateGrant(grant, now: now)
        guard operation.walletID == ledger.walletID,
              operation.network == ledger.network,
              grant.accountIDs.contains(operation.accountID),
              grant.capabilities.contains(operation.capability) else {
            throw AuthorizationFailure.scopeDenied
        }
        return grant.principal
    }

    @discardableResult
    func authorizeResult(
        session: AuthorizationSession,
        connectionID: String,
        peer: PeerEvidence,
        resultOwner: IntegrationPrincipal?,
        operation: AuthorizationOperation,
        now: Int64
    ) throws -> IntegrationPrincipal {
        guard resultOwner == session.principal else { throw AuthorizationFailure.unavailable }
        return try authorize(
            session: session, connectionID: connectionID, peer: peer,
            operation: operation, now: now
        )
    }

    private func requirePeer(_ peer: PeerEvidence, identity: SignedPeerIdentity) throws {
        guard peer.signatureValidated, peer.identity == identity else {
            throw AuthorizationFailure.untrustedPeer
        }
    }

    private func grantIndex(id: String) throws -> Int {
        let indices = ledger.grants.indices.filter { ledger.grants[$0].id == id }
        guard indices.count == 1, let index = indices.first else {
            throw AuthorizationFailure.unavailable
        }
        return index
    }

    private func validateGrant(_ grant: GrantRecord, now: Int64) throws {
        guard !grant.id.isEmpty, !grant.integrationID.isEmpty,
              grant.credentialDigest.count == 32, grant.credentialGeneration > 0,
              !grant.accountIDs.isEmpty, grant.accountIDs.allSatisfy({ !$0.isEmpty }),
              !grant.capabilities.isEmpty, grant.capabilities.allSatisfy({ !$0.isEmpty }) else {
            throw AuthorizationFailure.unavailable
        }
        guard !grant.revoked else { throw AuthorizationFailure.revoked }
        if grant.expiredObserved || grant.expiresAt.map({ now >= $0 }) == true {
            throw AuthorizationFailure.expired
        }
    }

    private static func makeCredential() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw AuthorizationFailure.randomnessUnavailable }
        return Data(bytes)
    }

    private static func digest(_ credential: Data) -> Data {
        Data(SHA256.hash(data: credential))
    }

    private static func equalDigest(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == 32, rhs.count == 32 else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private extension GrantRecord {
    var principal: IntegrationPrincipal { IntegrationPrincipal(grantID: id, integrationID: integrationID) }
}
