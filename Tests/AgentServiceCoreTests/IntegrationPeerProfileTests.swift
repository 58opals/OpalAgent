import AgentNativeIPC
import AgentValues
import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

struct IntegrationPeerProfileTests {
    @Test(arguments: ["intact", "pending", "restricted"])
    func originalLegacyStoresKeepExactCanonicalCommitmentsAndAuthority(variant: String) throws {
        let original = try legacyURL(variant)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: original, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("journal.sqlite")
        let before = try Data(contentsOf: path)
        let expectedBytes = try Data(contentsOf: original.appendingPathComponent("state.json"))
        let expectedReference = try JSONDecoder().decode(StateReference.self, from: Data(contentsOf: original.appendingPathComponent("reference.json")))
        let anchorBytes = try Data(contentsOf: original.appendingPathComponent("anchor.json"))
        let anchor = ProfileTestAnchor(try JSONDecoder().decode(ContinuityAnchor.self, from: anchorBytes))
        let journal = try SQLiteJournal(path: path.path)
        let loadedState = try journal.read()
        let state = try #require(loadedState)
        #expect(try state.reference() == expectedReference)
        #expect(try profileEncoding(state.canonicalized()) == expectedBytes)
        #expect(state.authorization.grants.allSatisfy { $0.peerProfile == .mcp })
        #expect(state.requests.count == 1 && state.payments.count == 1 && state.payments[0].attempts.count == 1)
        #expect(state.payments[0].liabilityUnresolved && state.gates[0].liabilityIDs == ["possible"])
        #expect(state.allocations[0].issuedHighWater == (variant == "pending" ? 2 : 1))
        let coordinator = ContinuityCoordinator(database: journal, anchor: anchor)
        if variant == "pending" {
            #expect(throws: ContinuityError.recoveryRequired) { try coordinator.startup() }
            #expect(coordinator.status() == .quarantined)
        } else {
            let trusted = try coordinator.startup()
            #expect(trusted == state)
            #expect(trusted.mode == (variant == "restricted" ? .restricted : .enabled))
            if variant == "restricted" {
                #expect(trusted.authorization.grants.allSatisfy { $0.revoked })
                #expect(trusted.approvals.allSatisfy { !$0.active })
                #expect(try anchor.read()?.originalProofs.first?.reference == archiveState("archive-parent.json").reference())
            }
        }
        #expect(anchor.writeCount == 0)
        #expect(try profileEncoding(try anchor.read()) == anchorBytes)
        #expect(try Data(contentsOf: path) == before)
        let parent = try archiveState("archive-parent.json"), target = try archiveState("archive-target.json")
        let loadedAnchor = try anchor.read()
        let originalAnchor = try #require(loadedAnchor)
        if variant == "pending" {
            #expect(try originalAnchor.committed == parent.reference())
            #expect(try originalAnchor.pending?.parent == parent.reference())
            #expect(try originalAnchor.pending?.target == target.reference())
        }
    }

    @Test func originalOwnerWireFramesRetainExactMCPBytes() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let requestBytes = try Data(contentsOf: legacyURL("owner-enrollment-request.json"))
        let (decodedID, request) = try NativeWire.decodeOwnerRequest(NativeOwnerPacket(frame: requestBytes))
        guard case .enrollIntegration(let input) = request.call else { throw NativeIPCFailure.malformedFrame }
        #expect(input.peerProfile == .mcp && decodedID == id)
        #expect(try NativeWire.ownerRequest(request, requestID: id).frame == requestBytes)
        let responseBytes = try Data(contentsOf: legacyURL("owner-enrollment-response.json"))
        let packet = NativeOwnerPacket(frame: responseBytes, sensitive: Data(repeating: 0xd0, count: 32))
        let response = try NativeWire.decodeOwnerResponse(packet, requestID: id, method: .enrollIntegration)
        guard case .enrollIntegration(let issued) = response.result else { throw NativeIPCFailure.malformedFrame }
        #expect(issued.grant.peerProfile == .mcp && issued.grant.credentialGeneration == 3)
        #expect(try NativeWire.ownerResponse(response, requestID: id).frame == responseBytes)
    }

    @Test func legacyGrantBytesRemainIdenticalAndAppleVerifierIsNotLegacyShaped() throws {
        let bytes = try Data(contentsOf: legacyURL("grant.json"))
        let grant = try JSONDecoder().decode(GrantRecord.self, from: bytes)
        #expect(grant.peerProfile == .mcp)
        #expect(try profileEncoding(grant) == bytes)
        var apple = grant; apple.peerProfile = .appleAutomation
        let encoded = try profileEncoding(apple)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["credentialDigest"] == nil)
        #expect(object["profileCredentialDigest"] as? String == grant.credentialDigest.base64EncodedString())
        #expect(object["peerProfile"] as? String == "appleAutomation")
        #expect(try JSONDecoder().decode(GrantRecord.self, from: encoded) == apple)
    }

    @Test(arguments: ["null", "unknown", "number", "missingAppleVerifier", "bothVerifiers", "legacyWithProfileVerifier", "shortAppleVerifier"])
    func malformedOrConflictingExplicitProfilesAreRejected(variant: String) throws {
        let bytes = try Data(contentsOf: legacyURL("grant.json"))
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        switch variant {
        case "null": object["peerProfile"] = NSNull()
        case "unknown": object["peerProfile"] = "future"
        case "number": object["peerProfile"] = 1
        case "missingAppleVerifier": object["peerProfile"] = "appleAutomation"; object.removeValue(forKey: "credentialDigest")
        case "bothVerifiers": object["peerProfile"] = "appleAutomation"; object["profileCredentialDigest"] = object["credentialDigest"]
        case "legacyWithProfileVerifier": object["profileCredentialDigest"] = object["credentialDigest"]
        default:
            object["peerProfile"] = "appleAutomation"; object.removeValue(forKey: "credentialDigest")
            object["profileCredentialDigest"] = Data([1]).base64EncodedString()
        }
        let invalid = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(GrantRecord.self, from: invalid) }
    }

    @Test func credentialsAreBoundToProfilePeerConnectionAndCurrentGenerations() throws {
        let legacy = try JSONDecoder().decode(GrantRecord.self, from: Data(contentsOf: legacyURL("grant.json")))
        let mcpCredential = Data(repeating: 0xd0, count: 32), appleCredential = Data(repeating: 0xa1, count: 32)
        var apple = legacy; apple.id = "apple-grant"; apple.integrationID = "apple-integration"; apple.peerProfile = .appleAutomation
        apple.credentialDigest = Data(SHA256.hash(data: appleCredential))
        let bridge = SignedPeerIdentity(teamIdentifier: "SYNTHETIC1", signingIdentifier: "test.bridge")
        let wallet = SignedPeerIdentity(teamIdentifier: "SYNTHETIC1", signingIdentifier: "test.wallet")
        let bridgePeer = PeerEvidence(identity: bridge, signatureValidated: true), walletPeer = PeerEvidence(identity: wallet, signatureValidated: true)
        let ledger = AuthorizationLedger(walletID: "legacy-wallet", network: "mainnet", generation: 7, grants: [legacy, apple])
        var authority = AuthorizationAuthority(ledger: ledger, expectedBridgeIdentity: bridge, trustedOwnerIdentity: wallet,
            maximumOwnerAuthenticationAge: 30, expectedAppleIntegrationIdentity: wallet)
        let mcp = try authority.authenticate(connectionID: "mcp", peer: bridgePeer, credential: mcpCredential, now: 100)
        let session = try authority.authenticate(connectionID: "apple", peer: walletPeer, credential: appleCredential, now: 100)
        #expect(mcp.peerProfile == .mcp && session.peerProfile == .appleAutomation)
        #expect(throws: AuthorizationFailure.untrustedPeer) { try authority.authenticate(connectionID: "mcp", peer: bridgePeer, credential: appleCredential, now: 100) }
        #expect(throws: AuthorizationFailure.untrustedPeer) { try authority.authenticate(connectionID: "apple", peer: walletPeer, credential: mcpCredential, now: 100) }
        let operation = AuthorizationOperation(walletID: "legacy-wallet", network: "mainnet", accountID: "account", capability: "read")
        #expect(try authority.authorize(session: session, connectionID: "apple", peer: walletPeer, operation: operation, now: 100) == session.principal)
        #expect(throws: AuthorizationFailure.staleSession) { try authority.authorize(session: session, connectionID: "other", peer: walletPeer, operation: operation, now: 100) }
        let owner = OwnerAuthenticationEvidence(peer: walletPeer, authenticationSucceeded: true, authenticatedAt: 100)
        let replacement = try authority.rotateGrant(id: apple.id, owner: owner, now: 100)
        #expect(authority.ledger.grants.first { $0.id == apple.id }?.peerProfile == .appleAutomation)
        #expect(throws: AuthorizationFailure.staleSession) { try authority.authorize(session: session, connectionID: "apple", peer: walletPeer, operation: operation, now: 100) }
        let fresh = try authority.authenticate(connectionID: "new", peer: walletPeer, credential: replacement.rawValue, now: 100)
        var newer = authority.ledger
        newer.generation += 1
        let newGeneration = AuthorizationAuthority(ledger: newer, expectedBridgeIdentity: bridge,
            trustedOwnerIdentity: wallet, maximumOwnerAuthenticationAge: 30, expectedAppleIntegrationIdentity: wallet)
        #expect(throws: AuthorizationFailure.staleSession) { try newGeneration.authorize(session: fresh, connectionID: "new", peer: walletPeer, operation: operation, now: 100) }
        let reset = AuthorizationAuthority(ledger: authority.ledger.disablingAllGrants(), expectedBridgeIdentity: bridge,
            trustedOwnerIdentity: wallet, maximumOwnerAuthenticationAge: 30, expectedAppleIntegrationIdentity: wallet)
        #expect(throws: AuthorizationFailure.revoked) { try reset.authorize(session: fresh, connectionID: "new", peer: walletPeer, operation: operation, now: 100) }
        let unconfigured = AuthorizationAuthority(ledger: ledger, expectedBridgeIdentity: bridge, trustedOwnerIdentity: wallet, maximumOwnerAuthenticationAge: 30)
        #expect(throws: AuthorizationFailure.untrustedPeer) { try unconfigured.authenticate(connectionID: "apple", peer: walletPeer, credential: appleCredential, now: 100) }
        #expect(throws: AuthorizationFailure.untrustedPeer) { try authority.requireOwner(owner: OwnerAuthenticationEvidence(peer: bridgePeer, authenticationSucceeded: true, authenticatedAt: 100), now: 100) }
    }

    @Test func newAppleGrantCommitsNormallyAndRecoveryRetainsItsProfileWithoutAuthority() throws {
        let state = try archiveState("archive-parent.json"), original = try state.reference()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
        try journal.write(state)
        let anchor = ProfileTestAnchor(ContinuityAnchor(committed: original))
        let coordinator = ContinuityCoordinator(database: journal, anchor: anchor)
        let bridge = SignedPeerIdentity(teamIdentifier: "SYNTHETIC1", signingIdentifier: "test.bridge")
        let wallet = SignedPeerIdentity(teamIdentifier: "SYNTHETIC1", signingIdentifier: "test.wallet")
        let policy = AuthorityPolicy(bridge: bridge, owner: wallet, accountIDs: ["account"], capabilities: ["read"],
            ownerAuthenticationAge: 30, appleIntegration: wallet)
        let service = try ServiceAuthority(continuity: coordinator, policy: policy)
        let owner = OwnerAuthenticationEvidence(peer: PeerEvidence(identity: wallet, signatureValidated: true),
            authenticationSucceeded: true, authenticatedAt: 100)
        let issued = try service.enroll(id: "apple-grant", integrationID: "apple-integration", accounts: ["account"],
            capabilities: ["read"], expiry: nil, owner: owner, now: 100, peerProfile: .appleAutomation)
        let loadedEnrollment = try journal.read()
        let enrolled = try #require(loadedEnrollment)
        #expect(enrolled.authorization.grants.first { $0.id == "legacy-grant" } == state.authorization.grants[0])
        #expect(enrolled.authorization.grants.first { $0.id == issued.principal.grantID }?.peerProfile == .appleAutomation)
        #expect(enrolled.payments == state.payments && enrolled.requests == state.requests && enrolled.gates == state.gates)
        #expect(try anchor.read()?.committed == enrolled.reference())
        #expect(try enrolled.reference() != original)
        let replacement = try service.rotate(id: issued.principal.grantID, owner: owner, now: 100)
        let loadedRotation = try journal.read()
        let rotated = try #require(loadedRotation)
        let grant = try #require(rotated.authorization.grants.first { $0.id == issued.principal.grantID })
        #expect(grant.peerProfile == .appleAutomation && grant.credentialGeneration == 2)
        let session = try service.authenticate(connectionID: "apple", peer: owner.peer, credential: replacement.rawValue, now: 100)
        #expect(session.peerProfile == .appleAutomation && session.walletGeneration == 7)
        let restricted = try coordinator.recover(ownerAuthorized: true, recoveryID: "profile-recovery")
        #expect(restricted.mode == .restricted && restricted.history == .complete && restricted.authorization.generation == 8)
        #expect(restricted.authorization.grants.allSatisfy { $0.revoked })
        #expect(restricted.authorization.grants.first { $0.id == grant.id }?.peerProfile == .appleAutomation)
        #expect(restricted.payments == rotated.payments && restricted.requests == rotated.requests && restricted.gates == rotated.gates)
        let recoveredSource = try rotated.reference()
        #expect(restricted.historyProvenance.kind == .committed)
        #expect(restricted.historyProvenance.sourceCommitment == recoveredSource.commitment)
        #expect(restricted.historyProvenance.parentCommitment == nil)
        #expect(try anchor.read()?.originalProofs.isEmpty == true)
        #expect(try anchor.read()?.committed == restricted.reference())
        #expect(try journal.read() == restricted)
    }

    @Test func profileCannotBeChangedByAnOrdinaryJournalTransaction() throws {
        let state = try archiveState("archive-parent.json")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
        try database.write(state)
        let reference = try state.reference(), anchor = ProfileTestAnchor(ContinuityAnchor(committed: reference))
        let coordinator = ContinuityCoordinator(database: database, anchor: anchor)
        #expect(throws: ContinuityError.invalidState) {
            try coordinator.transaction { $0.authorization.grants[0].peerProfile = .appleAutomation }
        }
        #expect(try database.read()?.reference() == reference)
        #expect(try anchor.read()?.committed == reference)
        #expect(anchor.writeCount == 0)
    }
}

private func legacyURL(_ path: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "LegacyGrantV2", withExtension: nil)).appendingPathComponent(path)
}
private func archiveState(_ path: String) throws -> CanonicalState {
    try JSONDecoder().decode(CanonicalState.self, from: Data(contentsOf: legacyURL(path)))
}
private func profileEncoding<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
private final class ProfileTestAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuityAnchor
    private var writes = 0
    init(_ value: ContinuityAnchor) { self.value = value }
    var writeCount: Int { lock.withLock { writes } }
    func read() throws -> ContinuityAnchor? { lock.withLock { value } }
    func write(_ value: ContinuityAnchor) throws { lock.withLock { self.value = value; writes += 1 } }
}
