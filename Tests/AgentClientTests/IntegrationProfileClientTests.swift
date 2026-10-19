import AgentClient
import AgentValues
import Foundation
import Testing

struct IntegrationProfileClientTests {
    @Test(arguments: [IntegrationPeerProfile.mcp, .appleAutomation])
    func explicitAuthenticationRechecksPrerequisitesBeforeOpeningNativeConnection(profile: IntegrationPeerProfile) async throws {
        let deployment = try AuthenticationPrerequisites()
        let transport = try NativeClientFactory(deployment: deployment).integrationTransport(
            credential: Data(repeating: 1, count: 32), peerProfile: profile)
        #expect(deployment.checkCount == 1)
        await #expect(throws: ClientFailure.unavailable) { try await transport.authenticate() }
        #expect(deployment.checkCount == 2)
    }

    @Test(arguments: [IntegrationPeerProfile.mcp, .appleAutomation])
    func enrollmentDeliveryCannotSubstituteAnotherPeerProfile(profile: IntegrationPeerProfile) async throws {
        let wallet = try WalletScope(walletID: "wallet", network: .mainnet)
        let request = try EnrollmentRequest(wallet: wallet, integrationID: "integration", accountIDs: ["account"], scopes: [.read], peerProfile: profile)
        let wrong: IntegrationPeerProfile = profile == .mcp ? .appleAutomation : .mcp
        let transport = ProfileOwnerTransport(profile: wrong)
        let client = OwnerControlClient(transport: transport)
        await #expect(throws: (any Error).self) { try await client.call(.enrollIntegration(request)) }
        let correct = OwnerControlClient(transport: ProfileOwnerTransport(profile: profile))
        let response = try await correct.call(.enrollIntegration(request))
        guard case .enrollIntegration(let issued) = response else { throw CapabilityFailure.invalidResponse }
        #expect(issued.grant.peerProfile == profile)
    }
}
private struct ProfileOwnerTransport: OwnerControlTransport {
    let profile: IntegrationPeerProfile
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        guard case .enrollIntegration(let enrollment) = request.call else { throw CapabilityFailure.invalidRequest }
        let grant = GrantProjection(selector: try GrantSelector(wallet: enrollment.wallet, grantID: "grant"), integrationID: enrollment.integrationID,
            accountIDs: enrollment.accountIDs, scopes: enrollment.scopes, expiresAt: enrollment.expiresAt,
            credentialGeneration: 1, state: .active, peerProfile: profile)
        return OwnerControlResponse(result: .enrollIntegration(OwnerIssuedCredential(grant: grant,
            credential: try SensitiveOwnerMaterial(bytes: Data(repeating: 1, count: 32)))))
    }
}

/// Denies before NativeClientLink construction; this fixture never activates a native connection.
private final class AuthenticationPrerequisites: NativeDeploymentProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let policy: NativeDeploymentPolicy
    init() throws {
        policy = try NativeDeploymentPolicy(
            service: NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "fixture.service"),
            bridge: NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "fixture.bridge"),
            wallet: NativeSignedIdentity(teamIdentifier: "AAAAAAAAAA", signingIdentifier: "fixture.wallet"),
            integrationMachService: "fixture.integration", ownerMachService: "fixture.owner", appleIntegrationMachService: "fixture.apple")
    }
    var checkCount: Int { lock.withLock { checks } }
    func deployment() throws -> NativeDeploymentPolicy { policy }
    func requireQualifiedPrerequisites() throws {
        try lock.withLock {
            checks += 1
            guard checks == 1 else { throw ClientFailure.unavailable }
        }
    }
}
