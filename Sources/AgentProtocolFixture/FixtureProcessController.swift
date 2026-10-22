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
    private var owner: FixtureOwnerSession?
    private var current: FixtureClientSession?

    init(runtime: FixtureRuntime) {
        self.runtime = runtime
        current = runtime.primarySession
    }

    func disconnectCurrent() async { await current?.close(); current = nil }
    func connect(_ credential: Data) async throws { current = try await runtime.openSession(credential: credential) }

    func integration(_ message: FixtureControlMessage) async throws -> PaymentOperation {
        let client: CapabilityClient
        switch message.connection {
        case "original": client = runtime.client
        case "current":
            guard let value = current else { throw FixtureFailure.fixtureUnavailable }; client = value.client
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
        if owner == nil { owner = try await runtime.openOwnerSession(consent: FixtureControllerConsent(clock: runtime.clock)) }
        guard let owner else { throw FixtureFailure.fixtureUnavailable }
        return try await owner.packet(input, requestID: id, method: request.call.method)
    }

    func close() async { await disconnectCurrent(); await owner?.close(); owner = nil }
}
#endif
