#if DEBUG
import AgentClient
import AgentNativeIPC
import AgentValues
import Foundation
@testable import AgentServiceCore

/// A second explicitly synthetic owner can change reviewed state while the UI's
/// reverse-consent callback is held. It still uses actual challenges and service frames.
private struct FixtureControllerConsent: OwnerConsentProvider {
    let clock: FixtureClock
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        .init(challenge: challenge, authenticatedAt: clock.read().wall)
    }
}

/// Closed development controls, not an owner transport or an MCP capability.
actor FixtureProcessController {
    private let runtime: FixtureRuntime
    private let owner: OwnerControlService
    private let ownerConnection: OwnerConnectionContext
    private var current: CapabilityClient?

    init(runtime: FixtureRuntime) {
        self.runtime = runtime
        current = runtime.context == nil ? nil : runtime.client
        let source = runtime.ownerService
        owner = OwnerControlService(continuity: source.continuity, policy: source.policy,
            authority: source.authority, vault: source.vault, accounts: source.accounts,
            payments: source.payments, consent: FixtureControllerConsent(clock: runtime.clock), clock: runtime.clock)
        ownerConnection = OwnerConnectionContext(connectionID: UUID().uuidString,
            peer: PeerEvidence(identity: runtime.policy.owner, signatureValidated: true))
    }

    func disconnectCurrent() { current = nil }
    func connect(_ credential: Data) throws { current = try runtime.integrationClient(credential: credential) }

    func integration(_ message: FixtureControlMessage) async throws -> PaymentOperation {
        let client: CapabilityClient
        switch message.connection {
        case "original": client = runtime.client
        case "current":
            guard let value = current else { throw FixtureFailure.fixtureUnavailable }; client = value
        default: throw FixtureFailure.invalidArguments
        }
        switch message.kind {
        case "integrationPrepare":
            guard let request = message.preparation,
                  case .preparePayment(var value) = try await client.call(.preparePayment(request)) else {
                throw FixtureFailure.invalidArguments
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while value.state == .preparing {
                guard clock.now < deadline else { throw FixtureFailure.fixtureUnavailable }
                try await Task.sleep(for: .milliseconds(20))
                guard case .getOperation(.payment(let updated)) = try await client.call(.getOperation(.operation(value.identity.selector))) else {
                    throw FixtureFailure.fixtureUnavailable
                }
                value = updated
            }
            return value
        case "integrationSubmit":
            guard let selector = message.operation,
                  case .submitPayment(let value) = try await client.call(.submitPayment(selector)) else {
                throw FixtureFailure.invalidArguments
            }
            return value
        case "integrationLookup":
            guard let lookup = message.lookup,
                  case .getOperation(.payment(let value)) = try await client.call(.getOperation(lookup)) else {
                throw FixtureFailure.invalidArguments
            }
            return value
        default: throw FixtureFailure.invalidArguments
        }
    }

    func send(_ request: OwnerControlRequest, id: UUID) async throws -> OwnerControlResponse {
        switch request.call {
        case .setApprovalPolicy, .rotateGrant, .revokeGrant, .enrollIntegration: break
        default: throw FixtureFailure.invalidArguments
        }
        let input = try NativeWire.ownerRequest(request, requestID: id)
        let output = await NativeServiceFrames.owner(input, service: owner, context: ownerConnection)
        return try NativeWire.decodeOwnerResponse(output, requestID: id, method: request.call.method)
    }

    func close() { current = nil; ownerConnection.invalidate() }
}
#endif
