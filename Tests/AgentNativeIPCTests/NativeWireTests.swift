import AgentValues
import AgentNativeIPC
import Foundation
import Testing

@Test func nativeFrameRejectsUnknownFieldsVersionCorrelationAndOversize() throws {
    let id = UUID()
    let bytes = try NativeWire.frame(NativeHello(channel: .integration, connectionID: ""), kind: .hello, requestID: id)
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object["owner"] = true
    #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.unpack(JSONSerialization.data(withJSONObject: object)) }
    #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.unpack(bytes, requestID: UUID()) }
    #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.unpack(Data(count: NativeWire.maximumFrameBytes + 1)) }
    object.removeValue(forKey: "owner"); object["protocolVersion"] = ServiceStatus.currentProtocolVersion + 1
    #expect(throws: NativeIPCFailure.incompatibleProtocol) { try NativeWire.unpack(JSONSerialization.data(withJSONObject: object)) }
    let denied = NativeWire.problem(.keyUnavailable, requestID: id)
    #expect(throws: ServiceProblem(.keyUnavailable)) { try NativeWire.unpack(denied, kind: .ownerResponse, requestID: id) }
}

@Test func nativeWireRejectsNestedAuthorityFieldsWithoutSerializingOwnerMaterial() throws {
    let wallet = try WalletScope(walletID: "wallet", network: .mainnet)
    let account = try AccountScope(wallet: wallet, accountID: "account")
    let request = CapabilityRequest(call: .getBalance(account))
    let bytes = try NativeWire.encode(request)
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var parameters = try #require(object["parameters"] as? [String: Any])
    var nested = try #require(parameters["wallet"] as? [String: Any]); nested["approved"] = true
    parameters["wallet"] = nested; object["parameters"] = parameters
    #expect(throws: (any Error).self) { try NativeWire.decode(CapabilityRequest.self, from: JSONSerialization.data(withJSONObject: object)) }
    let marker = Data("NATIVE_OWNER_ONLY_SYNTHETIC".utf8)
    let owner = OwnerControlRequest(call: .restoreSeed(SeedRestoreRequest(network: .chipnet, mnemonic: try SensitiveOwnerMaterial(bytes: marker))))
    let packet = try NativeWire.ownerRequest(owner, requestID: UUID())
    let metadata = String(decoding: packet.frame, as: UTF8.self)
    #expect(!metadata.contains(marker.base64EncodedString()) && packet.sensitive == marker)
    let (_, decoded) = try NativeWire.decodeOwnerRequest(packet)
    guard case .restoreSeed(let restored) = decoded.call else { throw NativeIPCFailure.malformedFrame }
    #expect(restored.network == .chipnet && restored.mnemonic.withBytes { $0 == marker })
    #expect(!String(reflecting: packet).contains("NATIVE_OWNER_ONLY_SYNTHETIC"))
    #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.decodeOwnerRequest(NativeOwnerPacket(frame: packet.frame)) }
    let status = try NativeWire.ownerRequest(OwnerControlRequest(call: .status), requestID: UUID())
    #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.decodeOwnerRequest(NativeOwnerPacket(frame: status.frame, sensitive: marker)) }
}

@Test func nativePolicyRequiresExactConfiguredIdentityAndDistinctChannels() throws {
    // Synthetic policy syntax only; these fixtures never qualify artifacts or establish a native connection.
    let service = try NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "fixture.service")
    let bridge = try NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "fixture.bridge")
    let wallet = try NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "fixture.wallet")
    let policy = try NativeDeploymentPolicy(service: service, bridge: bridge, wallet: wallet,
        integrationMachService: "fixture.integration", ownerMachService: "fixture.owner")
    #expect(policy.peer(for: .integration) == bridge && policy.peer(for: .owner) == wallet)
    #expect(!service.requirement.contains("*") && service.requirement.contains("identifier \"fixture.service\""))
    #expect(throws: NativeIPCFailure.untrustedPeer) { try NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "*") }
    #expect(throws: NativeIPCFailure.untrustedPeer) { try NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "x\" or true") }
    #expect(throws: NativeIPCFailure.untrustedPeer) { try NativeDeploymentPolicy(service: service, bridge: bridge, wallet: wallet, integrationMachService: "same", ownerMachService: "same") }
}
