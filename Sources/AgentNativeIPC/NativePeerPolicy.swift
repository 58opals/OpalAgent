import AgentValues
import Foundation
import Security

public enum NativeIPCFailure: Error, Sendable, Equatable { case unavailable, malformedFrame, incompatibleProtocol, untrustedPeer }
public enum NativeChannel: String, Codable, Sendable { case integration, owner, appleAutomation }

/// Values come from the accepted signed-artifact policy, never a message or an inferred developer identity.
public struct NativeSignedIdentity: Sendable, Equatable {
    public let teamIdentifier: String
    public let signingIdentifier: String
    public let requirement: String
    public init(teamIdentifier: String, signingIdentifier: String) throws {
        guard teamIdentifier.utf8.count == 10,
              teamIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              !signingIdentifier.isEmpty, signingIdentifier.utf8.count <= 255,
              signingIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46].contains($0) }) else {
            throw NativeIPCFailure.untrustedPeer
        }
        let expression = "anchor apple generic and identifier \"\(signingIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &parsed) == errSecSuccess, parsed != nil else {
            throw NativeIPCFailure.untrustedPeer
        }
        self.teamIdentifier = teamIdentifier; self.signingIdentifier = signingIdentifier; self.requirement = expression
    }
}
public struct NativeDeploymentPolicy: Sendable, Equatable {
    public let service: NativeSignedIdentity
    public let bridge: NativeSignedIdentity
    public let wallet: NativeSignedIdentity
    public let integrationMachService: String
    public let ownerMachService: String
    public let appleIntegrationMachService: String?
    public init(service: NativeSignedIdentity, bridge: NativeSignedIdentity, wallet: NativeSignedIdentity,
                integrationMachService: String, ownerMachService: String, appleIntegrationMachService: String? = nil) throws {
        guard service.teamIdentifier == bridge.teamIdentifier, service.teamIdentifier == wallet.teamIdentifier,
              Set([service.signingIdentifier, bridge.signingIdentifier, wallet.signingIdentifier]).count == 3,
              Self.validName(integrationMachService), Self.validName(ownerMachService), integrationMachService != ownerMachService,
              appleIntegrationMachService.map({ Self.validName($0) && $0 != integrationMachService && $0 != ownerMachService }) ?? true else {
            throw NativeIPCFailure.untrustedPeer
        }
        self.service = service; self.bridge = bridge; self.wallet = wallet
        self.integrationMachService = integrationMachService; self.ownerMachService = ownerMachService
        self.appleIntegrationMachService = appleIntegrationMachService
    }
    public func peer(for channel: NativeChannel) -> NativeSignedIdentity {
        switch channel { case .integration: bridge; case .owner, .appleAutomation: wallet }
    }
    public func machService(for channel: NativeChannel) -> String {
        switch channel {
        case .integration: integrationMachService
        case .owner: ownerMachService
        case .appleAutomation: appleIntegrationMachService ?? ""
        }
    }
    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46].contains($0)
        }
    }
}

/// Trusted deployment composition must qualify the exact artifacts, native signing and custody prerequisites.
/// There is no production qualifying implementation in this package and no message can provide this authority.
public protocol NativeDeploymentProvider: Sendable {
    func deployment() throws -> NativeDeploymentPolicy
    func requireQualifiedPrerequisites() throws
}
