#if DEBUG
import Foundation
@testable import AgentServiceCore

enum FixturePhase: String, Sendable { case beforeHandoff, acceptedResult, ownerReplyProduced }

/// Explicit cancellable checkpoints outside the coordinator lock. Every ACK is generated
/// from a trusted projection; the checkpoint never changes engine rows or Base outcomes.
actor FixturePhaseController {
    private var armed: FixturePhase?
    private let latch = FixtureRelayLatch()
    private var notification: (@Sendable (FixturePhase) throws -> Void)?
    func observe(_ notification: @escaping @Sendable (FixturePhase) throws -> Void) { self.notification = notification }
    func arm(_ phase: FixturePhase) async throws {
        guard armed == nil else { throw FixtureFailure.invalidArguments }
        await latch.close(); armed = phase
    }
    func reach(_ phase: FixturePhase) async throws {
        guard armed == phase else { return }
        try notification?(phase)
        try await latch.wait()
    }
    func release() async { armed = nil; await latch.open() }
}

struct FixturePhaseBoundary: PaymentExecutionBoundary {
    let base: BaseBCHAdapter
    let phases: FixturePhaseController
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview { try await base.prepare(request) }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment { try await base.sign(preview) }
    func preflight(_ payment: SignedPayment) async throws { try await base.preflight(payment) }
    func validateAdmission(_ payment: SignedPayment) throws { try base.validateAdmission(payment) }
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        try await phases.reach(.beforeHandoff)
        let invocation = try await base.handoff(payment, admission: admission)
        return PaymentTransportInvocation(id: invocation.id, result: {
            let result = await invocation.result()
            if case .accepted = result { try? await phases.reach(.acceptedResult) }
            return result
        }, cancel: { await invocation.cancel() })
    }
    func dispose(operationID: String) async throws { try await base.dispose(operationID: operationID) }
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation { try await base.observe(payment) }
}

/// Owner metadata/recovery does not require integration authentication or key opening.
/// Missing effect dependencies fail unavailable; no synthetic business outcome is supplied.
struct FixtureUnavailableBoundary: PaymentExecutionBoundary, AccountChainBoundary {
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview { throw PaymentFailure.unavailable }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment { throw PaymentFailure.unavailable }
    func preflight(_ payment: SignedPayment) async throws { throw PaymentFailure.unavailable }
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation { throw PaymentFailure.unavailable }
    func dispose(operationID: String) async throws { throw PaymentFailure.unavailable }
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation { throw PaymentFailure.unavailable }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord { throw PaymentFailure.unavailable }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String { throw PaymentFailure.unavailable }
}
#endif
