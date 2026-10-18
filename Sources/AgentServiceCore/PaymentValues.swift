import CryptoKit
import Foundation

struct PaymentPolicyRecord: Codable, Equatable, Sendable {
    var revision: UInt64 = 1
    var approvalRequired: Bool = false
}

struct PaymentRequest: Codable, Equatable, Sendable {
    var accountID: String
    var network: String
    var requestKey: String
    var destinationScript: Data
    var amount: Int64
    var feeRate: Int64 = 1
    var expiresAt: Int64? = nil
}

struct PaymentPreparationInput: Codable, Equatable, Sendable {
    var operationID: String
    var accountID: String
    var network: String
    var destinationScript: Data
    var amount: Int64
    var feeRate: Int64
    var expiresAt: Int64?
}

struct PaymentPreview: Codable, Equatable, Sendable {
    var operationID: String
    var accountID: String
    var network: String
    var destinationScript: Data
    var amount: Int64
    var fee: Int64
    var selectedInputs: [String]
    var change: Data
    var templateDigest: Data
    var leaseDeadline: Int64
    var inputPayloads: Data = Data()
    var unsignedTemplate: Data = Data()
}

struct SignedPayment: Codable, Equatable, Sendable {
    var operationID: String
    var bytes: Data
    var digest: Data
    var transactionID: String = ""
}

struct PaymentClockReading: Sendable {
    var wall: Int64
    var monotonic: UInt64
}
protocol PaymentClock: Sendable { func read() -> PaymentClockReading }
struct SystemPaymentClock: PaymentClock {
    func read() -> PaymentClockReading {
        PaymentClockReading(wall: Int64(Date().timeIntervalSince1970), monotonic: DispatchTime.now().uptimeNanoseconds / 1_000_000_000)
    }
}

enum PaymentTransportResult: Sendable, Equatable {
    case accepted(source: String)
    case rejected(source: String)
    case unknown(source: String)
}
struct PaymentTransportInvocation: Sendable {
    var id: String
    var result: @Sendable () async -> PaymentTransportResult
    // Must return only after this local invocation has ended; remote uncertainty may remain.
    var cancel: @Sendable () async -> Void
}
typealias PaymentAdmission = @Sendable (_ actualHandoff: () throws -> PaymentTransportInvocation) throws -> PaymentTransportInvocation

protocol PaymentExecutionBoundary: Sendable {
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment
    func preflight(_ payment: SignedPayment) async throws
    func validateAdmission(_ payment: SignedPayment) throws
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation
    func dispose(operationID: String) async throws
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation
}

extension PaymentExecutionBoundary {
    // An older injected boundary supplies no atomic admission guarantee.
    func validateAdmission(_ payment: SignedPayment) throws { throw PaymentFailure.unavailable }
}

// A coherent public observation supplied by the chain/account adapter. The engine validates
// the closure predicate; an adapter does not return a precomputed payment outcome.
struct PaymentObservation: Codable, Equatable, Sendable {
    var source: String
    var view: String
    var chainTip: String
    var observedAt: Int64
    var complete: Bool
    var fresh: Bool
    var exactTransactionBytes: Data? = nil
    var spentConsistently: [String] = []
    var accountedInputs: [String] = []
    var changeTracked: Bool = false
    var confirmedConflictInputs: [String] = []
    var canonicalConflict: Bool = false
    var supportRemoved: Bool = false
}

struct OwnerRelayCommand: Codable, Equatable, Sendable {
    var key: String
    var operationID: String
    var accountID: String
    var network: String
    var transactionDigest: Data
    var generation: UInt64
    var policyRevision: UInt64
    var evidenceRevision: UInt64
    var liabilityContextDigest: Data = Data()
}

struct PaymentSnapshot: Codable, Equatable, Sendable {
    var payment: PaymentRecord
    var accountRestricted: Bool
    var blocker: String?
    var ownerReceipt: RequestRecord? = nil
    var liabilityContextDigest: Data = Data()
    var walletID: String = ""
    var currentWalletGeneration: UInt64 = 0
    var currentPolicyRevision: UInt64 = 0
    var previewContextDigest: Data = Data()
}

private struct PreviewReviewBinding: Codable {
    var walletID: String
    var generation: UInt64
    var policyRevision: UInt64
    var originGrantID: String?
    var originCredentialGeneration: UInt64
    var request: PaymentRequest?
    var preview: PaymentPreview
}

func paymentPreviewContextDigest(_ payment: PaymentRecord, state: CanonicalState) -> Data {
    guard let preview = payment.preview else { return Data() }
    let binding = PreviewReviewBinding(walletID: state.authorization.walletID,
        generation: state.authorization.generation, policyRevision: state.paymentPolicy.revision,
        originGrantID: payment.originGrantID, originCredentialGeneration: payment.originCredentialGeneration,
        request: payment.request, preview: preview)
    guard let encoded = try? paymentEncoding(binding) else { return Data() }
    return paymentDigest(encoded)
}

enum PaymentFailure: Error, Equatable, Sendable {
    case invalidRequest, unavailable, accountRestricted, invalidTransition, staleContext
    case approvalNeeded, leaseExpired, relayNotEligible, transportBusy, keyUnavailable
    case networkUnavailable, recoveryRequired, conflictingRequest, noHandoff
}

func paymentDigest(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
func paymentEncoding<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func validPaymentKey(_ value: String) -> Bool {
    value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

// Only the payment owner may use these transitions. This validator supplies the narrow
// exception to generic retention; it is never a blanket permission to replace rows.
func validatePaymentTransition(from old: CanonicalState, to new: CanonicalState, classification: String) throws {
    guard classification.hasPrefix("payment."), old.allocations == new.allocations,
          old.custody == new.custody else { throw ContinuityError.invalidState }
    try new.validate()
    if old.paymentPolicy != new.paymentPolicy {
        guard classification == "payment.policy", old.paymentPolicy.revision < UInt64.max,
              new.paymentPolicy.revision == old.paymentPolicy.revision + 1 else { throw ContinuityError.invalidState }
    }
    guard Set(old.payments.map(\.id)).isSubset(of: Set(new.payments.map(\.id))) else { throw ContinuityError.invalidState }
    for before in old.payments {
        guard let after = new.payments.first(where: { $0.id == before.id }),
              before.accountID == after.accountID, before.network == after.network,
              before.originGrantID == after.originGrantID, before.request == after.request,
              before.originCredentialGeneration == after.originCredentialGeneration,
              before.walletGeneration == after.walletGeneration, before.policyRevision == after.policyRevision,
              before.preview == nil || before.preview == after.preview,
              before.canonicalBytes.isEmpty || (before.canonicalBytes == after.canonicalBytes &&
                before.transactionDigest == after.transactionDigest && before.transactionID == after.transactionID),
              before.attempts.allSatisfy({ after.attempts.contains($0) }),
              before.evidence.allSatisfy({ after.evidence.contains($0) }),
              before.closures.allSatisfy({ after.closures.contains($0) }),
              after.evidenceRevision >= before.evidenceRevision,
              after.observationSequence >= before.observationSequence,
              after.ordinaryAdmissions >= before.ordinaryAdmissions,
              after.ordinaryAdmissions <= 3 else { throw ContinuityError.invalidState }
        if before.preview != nil {
            guard before.selectedInputs == after.selectedInputs, before.change == after.change else {
                throw ContinuityError.invalidState
            }
        } else if after.preview != nil {
            guard classification == "payment.prepared", before.disposition == .preparing,
                  after.disposition == .prepared else { throw ContinuityError.invalidState }
        }
        if before.canonicalBytes.isEmpty && !after.canonicalBytes.isEmpty {
            guard classification == "payment.admit", before.disposition == .ready,
                  after.transactionDigest == paymentDigest(after.canonicalBytes) else { throw ContinuityError.invalidState }
        }
        if after.attempts.count != before.attempts.count {
            guard ["payment.admit", "payment.ownerAdmit"].contains(classification),
                  after.attempts.count == before.attempts.count + 1,
                  after.disposition == .submitting, after.liabilityUnresolved,
                  let attempt = after.attempts.max(by: { $0.number < $1.number }), attempt.number == UInt64(after.attempts.count),
                  !attempt.id.isEmpty, !after.canonicalBytes.isEmpty,
                  attempt.route == (classification == "payment.admit" ? "ordinary" : "owner"),
                  after.ordinaryAdmissions == before.ordinaryAdmissions + (attempt.route == "ordinary" ? 1 : 0) else {
                throw ContinuityError.invalidState
            }
        } else if after.ordinaryAdmissions != before.ordinaryAdmissions { throw ContinuityError.invalidState }
        if before.liabilityUnresolved && !after.liabilityUnresolved {
            guard ["payment.observe", "payment.noHandoff"].contains(classification), after.disposition == .closed,
                  after.closures.count > before.closures.count else { throw ContinuityError.invalidState }
        }
        if before.evidenceSupported && !after.evidenceSupported {
            guard classification == "payment.observe", after.evidenceRevision > before.evidenceRevision,
                  after.liabilityUnresolved else { throw ContinuityError.invalidState }
        }
        if before.disposition != after.disposition {
            let valid: Bool
            if before.disposition.isUnsubmitted && [.closed, .invalidated].contains(after.disposition) {
                valid = ["payment.cancel", "payment.expire", "payment.policy", "payment.observe", "payment.failure", "payment.submit", "payment.approve", "payment.prepared"].contains(classification)
                    || after.terminalReason == "authorizationInvalidated"
            } else {
                switch (before.disposition, after.disposition) {
                case (.preparing, .prepared): valid = classification == "payment.prepared"
                case (.prepared, .pendingApproval), (.prepared, .ready): valid = classification == "payment.submit"
                case (.pendingApproval, .ready): valid = classification == "payment.approve"
                case (.ready, .submitting), (.uncertain, .submitting), (.possiblyRelayed, .submitting):
                    valid = ["payment.admit", "payment.ownerAdmit"].contains(classification)
                case (.recoveryRequired, .submitting): valid = classification == "payment.ownerAdmit"
                case (.uncertain, .recoveryRequired), (.accepted, .recoveryRequired), (.possiblyRelayed, .recoveryRequired), (.submitting, .recoveryRequired):
                    valid = classification == "payment.damage"
                case (.closed, .submitting):
                    valid = classification == "payment.ownerAdmit" && !before.evidenceSupported && before.liabilityUnresolved &&
                        before.closures.contains { ["reconciledAccepted", "reconciledConflict"].contains($0.reason) }
                case (.submitting, .accepted), (.submitting, .uncertain), (.uncertain, .accepted):
                    valid = ["payment.result", "payment.noHandoff", "payment.observe"].contains(classification)
                case (.accepted, .uncertain): valid = classification == "payment.observe"
                case (.uncertain, .closed), (.accepted, .closed), (.possiblyRelayed, .closed), (.recoveryRequired, .closed):
                    valid = classification == "payment.observe"
                case (.submitting, .closed): valid = ["payment.observe", "payment.noHandoff"].contains(classification)
                default: valid = false
                }
            }
            guard valid else { throw ContinuityError.invalidState }
        }
    }
    for added in new.payments where !old.payments.contains(where: { $0.id == added.id }) {
        guard classification == "payment.prepare", added.disposition == .preparing,
              added.canonicalBytes.isEmpty, added.attempts.isEmpty, !added.liabilityUnresolved,
              added.request != nil, new.gates.contains(where: { $0.accountID == added.accountID && $0.liabilityIDs.contains(added.id) }) else {
            throw ContinuityError.invalidState
        }
    }
    for gate in old.gates {
        let retained = new.gates.first { $0.accountID == gate.accountID }
        for restriction in gate.restrictions where !(retained?.restrictions.contains(restriction) ?? false) {
            guard classification == "payment.observe", restriction.hasPrefix("staleReadiness:"),
                  let payment = new.payments.first(where: { "staleReadiness:\($0.id)" == restriction }),
                  payment.disposition == .closed, payment.evidenceSupported, !payment.liabilityUnresolved else {
                throw ContinuityError.invalidState
            }
        }
        for removed in gate.liabilityIDs where !(retained?.liabilityIDs.contains(removed) ?? false) {
            guard ["payment.cleanup", "payment.observe"].contains(classification),
                  let payment = new.payments.first(where: { $0.id == removed }),
                  !payment.liabilityUnresolved, !payment.disposition.isUnsubmitted else { throw ContinuityError.invalidState }
        }
    }
    for request in new.requests where request.method == "authorize_payment_relay" && !old.requests.contains(where: { $0.id == request.id }) {
        guard request.principalID == "owner", request.tombstone else { throw ContinuityError.invalidState }
        if let attemptID = request.consumedAttemptID {
            guard classification == "payment.ownerAdmit",
                  new.payments.contains(where: { $0.id == request.paymentID && $0.attempts.contains(where: { $0.id == attemptID && $0.commandID == request.key && $0.route == "owner" }) }) else {
                throw ContinuityError.invalidState
            }
        } else {
            guard classification == "payment.ownerDenied", request.disposition == .closed,
                  !request.result.isEmpty else { throw ContinuityError.invalidState }
        }
    }
}

// Material account context excludes polling times, observation sequence, attempt progress and
// routine refreshed observations. It changes when the reviewed liability/support set changes.
func accountLiabilityContextDigest(accountID: String, state: CanonicalState) -> Data {
    var data = Data("OpalAgentAccountLiability/v1".utf8)
    func appendNumber(_ value: UInt64) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
    func appendBytes(_ value: Data) { appendNumber(UInt64(value.count)); data.append(value) }
    func appendString(_ value: String) { appendBytes(Data(value.utf8)) }
    appendString(accountID)
    let gates = state.gates.filter { $0.accountID == accountID }
    let members = Set(gates.flatMap(\.liabilityIDs)).sorted()
    appendNumber(UInt64(members.count)); for id in members { appendString(id) }
    let restrictions = Set(gates.flatMap(\.restrictions)).sorted()
    appendNumber(UInt64(restrictions.count)); for restriction in restrictions { appendString(restriction) }
    let relevant = state.payments.filter { payment in
        payment.accountID == accountID && (payment.liabilityUnresolved || members.contains(payment.id) ||
            payment.closures.contains { ["reconciledAccepted", "reconciledConflict"].contains($0.reason) })
    }.sorted { $0.id < $1.id }
    appendNumber(UInt64(relevant.count))
    for payment in relevant {
        appendString(payment.id); appendBytes(payment.transactionDigest)
        appendNumber(payment.evidenceRevision); appendNumber(payment.evidenceSupported ? 1 : 0)
        appendNumber(payment.liabilityUnresolved ? 1 : 0)
        let closures = payment.closures.sorted { $0.id < $1.id }
        appendNumber(UInt64(closures.count))
        for closure in closures {
            appendString(closure.id); appendString(closure.reason); appendNumber(closure.revision)
            let evidence = closure.evidenceIDs.sorted()
            appendNumber(UInt64(evidence.count)); for id in evidence { appendString(id) }
        }
    }
    return paymentDigest(data)
}
