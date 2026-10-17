import Foundation
import Testing
@testable import AgentServiceCore

private final class AuthorityDatabase: ContinuityDatabase, @unchecked Sendable {
    var value: CanonicalState?
    private(set) var writes = 0
    init(_ value: CanonicalState) { self.value = value }
    func read() throws -> CanonicalState? { value }
    func write(_ state: CanonicalState) throws { writes += 1; value = state }
}
private final class AuthorityAnchor: ContinuityAnchorStore, @unchecked Sendable {
    var value: ContinuityAnchor?
    var dropWrites = false
    private(set) var writes = 0
    init(_ state: CanonicalState) throws { value = ContinuityAnchor(committed: try state.reference()) }
    func read() throws -> ContinuityAnchor? { value }
    func write(_ anchor: ContinuityAnchor) throws { writes += 1; if !dropWrites { value = anchor } }
}
private func authorityFixture() throws -> (ServiceAuthority, ContinuityCoordinator, AuthorityDatabase, AuthorityAnchor, OwnerAuthenticationEvidence, PeerEvidence) {
    let ownerID = SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "owner")
    let bridgeID = SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "bridge")
    let state = CanonicalState(installationID: "installation",
        authorization: AuthorizationLedger(walletID: "wallet", network: "test", generation: 1, grants: []),
        mode: .enabled, history: .complete)
    let db = AuthorityDatabase(state); let anchor = try AuthorityAnchor(state)
    let continuity = ContinuityCoordinator(database: db, anchor: anchor)
    let policy = AuthorityPolicy(bridge: bridgeID, owner: ownerID, accountIDs: ["account"],
                                capabilities: ["read", "prepare"], ownerAuthenticationAge: 20)
    return (try ServiceAuthority(continuity: continuity, policy: policy), continuity, db, anchor,
        OwnerAuthenticationEvidence(peer: PeerEvidence(identity: ownerID, signatureValidated: true),
                                    authenticationSucceeded: true, authenticatedAt: 10),
        PeerEvidence(identity: bridgeID, signatureValidated: true))
}

@Test func credentialDeliveryRequiresCompletedContinuity() throws {
    let (service, continuity, db, anchor, owner, _) = try authorityFixture()
    anchor.dropWrites = true
    #expect(throws: ContinuityError.recoveryRequired) {
        try service.enroll(id: "g", integrationID: "i", accounts: ["account"], capabilities: ["read"],
                           expiry: nil, owner: owner, now: 10)
    }
    #expect(db.value?.authorization.grants.isEmpty == true)
    #expect(continuity.status() == .quarantined)
}

@Test func registeredInventoryConstrainsEnrollment() throws {
    let (service, _, _, _, owner, _) = try authorityFixture()
    for (accounts, capabilities) in [(["foreign"], ["read"]), (["account"], ["owner"])] {
        #expect(throws: AuthorizationFailure.scopeDenied) {
            try service.enroll(id: "g", integrationID: "i", accounts: accounts, capabilities: capabilities,
                               expiry: nil, owner: owner, now: 10)
        }
    }
}

@Test func rotationInvalidatesConsentAndPersistsAgainstRestart() throws {
    let (service, continuity, db, anchor, owner, peer) = try authorityFixture()
    let first = try service.enroll(id: "g", integrationID: "i", accounts: ["account"],
        capabilities: ["read"], expiry: nil, owner: owner, now: 10)
    let session = try service.authenticate(connectionID: "c", peer: peer, credential: first.rawValue, now: 10)
    try continuity.transaction { state in
        for (id, disposition) in [("u", PaymentDisposition.unsubmitted), ("p", .possiblyRelayed)] {
            state.payments.append(PaymentRecord(id: id, accountID: "account", network: "test", originGrantID: "g",
                canonicalBytes: Data([1]), transactionDigest: Data([2]), selectedInputs: [], change: Data(),
                disposition: disposition, liabilityUnresolved: id == "p", attempts: [], evidence: [], closures: []))
            state.approvals.append(ApprovalRecord(id: id, paymentID: id, generation: 1, context: Data([3]), active: true))
        }
        state.gates = [SpendingGate(accountID: "account", liabilityIDs: ["p"], restrictions: [])]
        state.requests = [RequestRecord(id: "r", principalID: "g", paymentID: "p", method: "read",
            key: "retained-key", binding: Data([4]), disposition: .consumed, result: Data([8]),
            consumedAttemptID: nil, tombstone: true)]
    }
    let next = try service.rotate(id: "g", owner: owner, now: 11)
    #expect(next.principal == first.principal)
    #expect(throws: AuthorizationFailure.unavailable) {
        try service.result(requestID: "r", session: session, connectionID: "c", peer: peer, now: 11)
    }
    let restored = ContinuityCoordinator(database: db, anchor: anchor)
    #expect(restored.status() == .trusted(mode: .enabled, history: .complete, generation: 1))
    try restored.inspect { state in
        #expect(state.approvals.allSatisfy { !$0.active })
        #expect(state.payments.first { $0.id == "u" }?.disposition == .invalidated)
        #expect(state.payments.first { $0.id == "p" }?.disposition == .possiblyRelayed)
        #expect(state.gates.first?.liabilityIDs == ["p"])
        #expect(state.requests.first?.key == "retained-key")
    }
    let newSession = try service.authenticate(connectionID: "new", peer: peer, credential: next.rawValue, now: 11)
    #expect(try service.result(requestID: "r", session: newSession, connectionID: "new", peer: peer, now: 11) == Data([8]))
    try service.revoke(id: "g", owner: owner, now: 12)
    #expect(throws: AuthorizationFailure.unavailable) {
        try service.result(requestID: "r", session: newSession, connectionID: "new", peer: peer, now: 12)
    }
    #expect(throws: AuthorizationFailure.revoked) {
        try service.authenticate(connectionID: "later", peer: peer, credential: next.rawValue, now: 12)
    }
}

@Test func unknownForeignAndExpiredResultsRemainUnavailable() throws {
    let (service, _, _, _, owner, peer) = try authorityFixture()
    let issued = try service.enroll(id: "g", integrationID: "i", accounts: ["account"],
        capabilities: ["read"], expiry: 12, owner: owner, now: 10)
    let session = try service.authenticate(connectionID: "c", peer: peer, credential: issued.rawValue, now: 10)
    for id in ["missing", "foreign"] {
        #expect(throws: AuthorizationFailure.unavailable) {
            try service.result(requestID: id, session: session, connectionID: "c", peer: peer, now: 12)
        }
    }
    #expect(throws: AuthorizationFailure.expired) {
        try service.authenticate(connectionID: "reconnect", peer: peer, credential: issued.rawValue, now: 12)
    }
}

private enum ExpirationObservation: CaseIterable, Sendable {
    case authentication, resultDisclosure, ownerRotation, explicitObservation
}

@Test(arguments: ExpirationObservation.allCases)
private func observedExpirationSurvivesRestartAndAnEarlierClock(_ observation: ExpirationObservation) throws {
    let (service, continuity, database, anchor, owner, peer) = try authorityFixture()
    let issued = try service.enroll(id: "g", integrationID: "i", accounts: ["account"],
        capabilities: ["read"], expiry: 12, owner: owner, now: 10)
    let session = try service.authenticate(connectionID: "c", peer: peer, credential: issued.rawValue, now: 10)
    try continuity.transaction { state in
        state.payments = [PaymentRecord(id: "p", accountID: "account", network: "test", originGrantID: "g",
            canonicalBytes: Data([1]), transactionDigest: Data([2]), selectedInputs: [], change: Data(),
            disposition: .possiblyRelayed, liabilityUnresolved: true, attempts: [], evidence: [], closures: [])]
        state.requests = [RequestRecord(id: "r", principalID: "g", paymentID: "p", method: "read",
            key: "key", binding: Data([3]), disposition: .consumed, result: Data([4]),
            consumedAttemptID: nil, tombstone: true)]
        state.gates = [SpendingGate(accountID: "account", liabilityIDs: ["p"], restrictions: [])]
        state.approvals = [ApprovalRecord(id: "approval", paymentID: "p", generation: 1,
                                         context: Data([5]), active: true)]
    }
    switch observation {
    case .authentication:
        #expect(throws: AuthorizationFailure.expired) {
            try service.authenticate(connectionID: "expired", peer: peer, credential: issued.rawValue, now: 12)
        }
    case .resultDisclosure:
        #expect(throws: AuthorizationFailure.unavailable) {
            try service.result(requestID: "r", session: session, connectionID: "c", peer: peer, now: 12)
        }
    case .ownerRotation:
        #expect(throws: AuthorizationFailure.expired) { try service.rotate(id: "g", owner: owner, now: 12) }
    case .explicitObservation:
        try service.expire(now: 12)
    }
    let restarted = ContinuityCoordinator(database: database, anchor: anchor)
    let policy = AuthorityPolicy(bridge: peer.identity!, owner: owner.peer.identity!, accountIDs: ["account"],
                                capabilities: ["read", "prepare"], ownerAuthenticationAge: 20)
    let restored = try ServiceAuthority(continuity: restarted, policy: policy)
    try restored.expire(now: 10)
    #expect(database.value?.authorization.grants.first?.expiredObserved == true)
    #expect(throws: AuthorizationFailure.expired) {
        try restored.authenticate(connectionID: "earlier", peer: peer, credential: issued.rawValue, now: 10)
    }
    #expect(throws: AuthorizationFailure.unavailable) {
        try restored.result(requestID: "r", session: session, connectionID: "c", peer: peer, now: 10)
    }
    #expect(throws: AuthorizationFailure.expired) { try restored.rotate(id: "g", owner: owner, now: 10) }
    #expect(database.value?.approvals.allSatisfy { !$0.active } == true)
    #expect(database.value?.payments.first?.liabilityUnresolved == true)
    #expect(database.value?.gates.first?.liabilityIDs == ["p"])
}

@Test func anExpirationDenialRequiresCompletedContinuity() throws {
    let (service, continuity, database, anchor, owner, peer) = try authorityFixture()
    let issued = try service.enroll(id: "g", integrationID: "i", accounts: ["account"],
        capabilities: ["read"], expiry: 12, owner: owner, now: 10)
    anchor.dropWrites = true
    #expect(throws: ContinuityError.recoveryRequired) {
        try service.authenticate(connectionID: "expired", peer: peer, credential: issued.rawValue, now: 12)
    }
    #expect(database.value?.authorization.grants.first?.expiredObserved == false)
    #expect(continuity.status() == .quarantined)
}

@Test func restrictedServiceCannotObserveExpiryOrMintAuthority() throws {
    let (service, continuity, _, _, owner, peer) = try authorityFixture()
    let issued = try service.enroll(id: "g", integrationID: "i", accounts: ["account"],
        capabilities: ["read"], expiry: 12, owner: owner, now: 10)
    _ = try continuity.recover(ownerAuthorized: true, recoveryID: "restricted")
    #expect(throws: ContinuityError.recoveryRequired) { try service.expire(now: 12) }
    #expect(throws: ContinuityError.recoveryRequired) {
        try service.authenticate(connectionID: "restricted", peer: peer, credential: issued.rawValue, now: 10)
    }
    #expect(throws: ContinuityError.recoveryRequired) { try service.rotate(id: "g", owner: owner, now: 10) }
    #expect(throws: ContinuityError.recoveryRequired) {
        try service.enroll(id: "new", integrationID: "new", accounts: ["account"],
            capabilities: ["read"], expiry: nil, owner: owner, now: 10)
    }
}

@Test func observationalAuthenticationAndResultsNeverWriteUnchangedState() throws {
    let (service, continuity, db, anchor, owner, peer) = try authorityFixture()
    let issued = try service.enroll(id: "g", integrationID: "i", accounts: ["account"],
        capabilities: ["read"], expiry: nil, owner: owner, now: 10)
    try continuity.transaction { state in
        state.payments = [PaymentRecord(id: "p", accountID: "account", network: "test", originGrantID: "g",
            canonicalBytes: Data([1]), transactionDigest: Data([2]), selectedInputs: [], change: Data(),
            disposition: .closed, liabilityUnresolved: false, attempts: [], evidence: [], closures: [])]
        state.requests = [RequestRecord(id: "r", principalID: "g", paymentID: "p", method: "read",
            key: "key", binding: Data([3]), disposition: .closed, result: Data([8]),
            consumedAttemptID: nil, tombstone: true)]
    }
    let beforeDatabase = db.writes; let beforeAnchor = anchor.writes
    let beforeCommit = db.value?.commitID
    let session = try service.authenticate(connectionID: "c", peer: peer, credential: issued.rawValue, now: 11)
    #expect(try service.result(requestID: "r", session: session, connectionID: "c", peer: peer, now: 11) == Data([8]))
    #expect(throws: AuthorizationFailure.invalidCredential) {
        try service.authenticate(connectionID: "other", peer: peer, credential: Data(repeating: 0, count: 32), now: 11)
    }
    #expect(db.writes == beforeDatabase)
    #expect(anchor.writes == beforeAnchor)
    #expect(db.value?.commitID == beforeCommit)
}
