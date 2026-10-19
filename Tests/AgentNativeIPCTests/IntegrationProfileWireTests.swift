import AgentClient
import AgentNativeIPC
import AgentValues
import Foundation
import Testing

struct IntegrationProfileWireTests {
    @Test func appleChannelPinsWalletIdentityWithoutOwnerOrDefaultFactoryFallback() throws {
        let service = try NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "fixture.service")
        let bridge = try NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "fixture.bridge")
        let wallet = try NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "fixture.wallet")
        let legacy = try NativeDeploymentPolicy(service: service, bridge: bridge, wallet: wallet,
            integrationMachService: "fixture.integration", ownerMachService: "fixture.owner")
        #expect(legacy.appleIntegrationMachService == nil)
        let factory = NativeClientFactory(deployment: ProfileDeployment(policy: legacy))
        #expect(throws: ClientFailure.unavailable) { try factory.integrationTransport(credential: Data(repeating: 1, count: 32), peerProfile: .appleAutomation) }
        #expect(throws: ClientFailure.unavailable) { try NativeClientFactory().integrationTransport(credential: Data(repeating: 1, count: 32), peerProfile: .appleAutomation) }
        let configured = try NativeDeploymentPolicy(service: service, bridge: bridge, wallet: wallet,
            integrationMachService: "fixture.integration", ownerMachService: "fixture.owner", appleIntegrationMachService: "fixture.apple")
        #expect(configured.peer(for: .appleAutomation) == wallet)
        #expect(configured.peer(for: .integration) == bridge && configured.peer(for: .owner) == wallet)
        #expect(configured.machService(for: .appleAutomation) != configured.machService(for: .owner))
        #expect(configured.machService(for: .appleAutomation) != configured.machService(for: .integration))
        for name in ["fixture.integration", "fixture.owner", "", "*"] {
            #expect(throws: NativeIPCFailure.untrustedPeer) {
                try NativeDeploymentPolicy(service: service, bridge: bridge, wallet: wallet,
                    integrationMachService: "fixture.integration", ownerMachService: "fixture.owner", appleIntegrationMachService: name)
            }
        }
        // No configured factory sends a message here. Artifact qualification and signed NSXPC execution remain separate proof.
    }

    @Test func appleEnrollmentAndProjectionRoundTripWithoutCredentialMetadata() throws {
        let wallet = try WalletScope(walletID: "wallet", network: .mainnet)
        let input = try EnrollmentRequest(wallet: wallet, integrationID: "apple", accountIDs: ["account"], scopes: [.read], peerProfile: .appleAutomation)
        let id = UUID()
        let packet = try NativeWire.ownerRequest(OwnerControlRequest(call: .enrollIntegration(input)), requestID: id)
        #expect(packet.sensitive == nil)
        let (decodedID, request) = try NativeWire.decodeOwnerRequest(packet)
        guard case .enrollIntegration(let parsed) = request.call else { throw NativeIPCFailure.malformedFrame }
        #expect(parsed == input && decodedID == id)
        let grant = GrantProjection(selector: try GrantSelector(wallet: wallet, grantID: "grant"), integrationID: "apple",
            accountIDs: ["account"], scopes: [.read], expiresAt: nil, credentialGeneration: 1, state: .active, peerProfile: .appleAutomation)
        let marker = Data(repeating: 0xa5, count: 32)
        let response = try NativeWire.ownerResponse(OwnerControlResponse(result: .enrollIntegration(OwnerIssuedCredential(
            grant: grant, credential: SensitiveOwnerMaterial(bytes: marker)))), requestID: id)
        #expect(response.sensitive == marker && !String(decoding: response.frame, as: UTF8.self).contains(marker.base64EncodedString()))
        let decoded = try NativeWire.decodeOwnerResponse(response, requestID: id, method: .enrollIntegration)
        guard case .enrollIntegration(let issued) = decoded.result else { throw NativeIPCFailure.malformedFrame }
        #expect(issued.grant == grant && issued.credential.withBytes { $0 == marker })
        let legacy = try EnrollmentRequest(wallet: wallet, integrationID: "legacy", accountIDs: ["account"], scopes: [.read])
        #expect(legacy.peerProfile == .mcp)
        #expect(try NativeWire.reviewCommitment(.enrollIntegration(input)) != NativeWire.reviewCommitment(.enrollIntegration(EnrollmentRequest(
            wallet: wallet, integrationID: "apple", accountIDs: ["account"], scopes: [.read]))))
    }

    @Test(arguments: ["null", "unknown", "number", "ownerField"])
    func enrollmentRejectsMalformedExplicitProfilesAndOwnerFields(variant: String) throws {
        let wallet = try WalletScope(walletID: "wallet", network: .mainnet)
        let input = try EnrollmentRequest(wallet: wallet, integrationID: "apple", accountIDs: ["account"], scopes: [.read], peerProfile: .appleAutomation)
        let packet = try NativeWire.ownerRequest(OwnerControlRequest(call: .enrollIntegration(input)), requestID: UUID())
        var frame = try #require(JSONSerialization.jsonObject(with: packet.frame) as? [String: Any])
        let encodedBody = try #require(frame["payload"] as? String)
        let bodyBytes = try #require(Data(base64Encoded: encodedBody))
        var body = try #require(JSONSerialization.jsonObject(with: bodyBytes) as? [String: Any])
        let encodedInput = try #require(body["payload"] as? String)
        let inputBytes = try #require(Data(base64Encoded: encodedInput))
        var object = try #require(JSONSerialization.jsonObject(with: inputBytes) as? [String: Any])
        switch variant {
        case "null": object["peerProfile"] = NSNull()
        case "unknown": object["peerProfile"] = "owner"
        case "number": object["peerProfile"] = 1
        default: object["owner"] = true
        }
        body["payload"] = try JSONSerialization.data(withJSONObject: object).base64EncodedString()
        frame["payload"] = try JSONSerialization.data(withJSONObject: body).base64EncodedString()
        let malformed = NativeOwnerPacket(frame: try JSONSerialization.data(withJSONObject: frame))
        #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.decodeOwnerRequest(malformed) }
    }

    @Test func oldHelloBytesStayStableAndAppleHelloCannotBecomeOwner() throws {
        let original = Data("{\"channel\":\"integration\",\"connectionID\":\"connection\"}".utf8)
        #expect(try NativeWire.encode(NativeHello(channel: .integration, connectionID: "connection")) == original)
        let apple = NativeHello(channel: .appleAutomation, connectionID: "connection")
        #expect(try NativeWire.decode(NativeHello.self, from: NativeWire.encode(apple)) == apple)
        #expect(apple.channel != .owner)
        for value in ["{\"channel\":null,\"connectionID\":\"connection\"}", "{\"channel\":\"future\",\"connectionID\":\"connection\"}"] {
            #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.decode(NativeHello.self, from: Data(value.utf8)) }
        }
    }
}
private struct ProfileDeployment: NativeDeploymentProvider {
    let policy: NativeDeploymentPolicy
    func deployment() throws -> NativeDeploymentPolicy { policy }
    func requireQualifiedPrerequisites() throws {}
}
