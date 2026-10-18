import Foundation

struct AccountOperationRequest: Codable, Equatable, Sendable {
    var accountID: String
    var network: String
    var requestKey: String
}

enum AccountOperationEffect: String, Codable, Sendable {
    case receive, synchronize
    var method: String { self == .receive ? "create_receive_request" : "synchronize_account" }
    var capability: String { self == .receive ? "receive" : "sync" }
    init?(method: String) {
        switch method {
        case "create_receive_request": self = .receive
        case "synchronize_account": self = .synchronize
        default: return nil
        }
    }
}
enum AccountOperationState: String, Codable, Sendable { case pending, allocated, completed, closed }
enum AccountOperationCloseReason: String, Codable, Sendable { case cancelled, invalidated, authorizationInvalidated, failed }
enum AccountOperationBlocker: String, Codable, Sendable {
    case accountRestricted, networkUnavailable, staleContext, keyUnavailable, unavailable, failed
    init(_ error: any Error) {
        switch error as? PaymentFailure {
        case .accountRestricted: self = .accountRestricted
        case .networkUnavailable: self = .networkUnavailable
        case .staleContext: self = .staleContext
        case .keyUnavailable: self = .keyUnavailable
        case .unavailable: self = .unavailable
        default: self = .failed
        }
    }
    var failure: PaymentFailure {
        switch self {
        case .accountRestricted: .accountRestricted
        case .networkUnavailable: .networkUnavailable
        case .staleContext: .staleContext
        case .keyUnavailable: .keyUnavailable
        case .unavailable, .failed: .unavailable
        }
    }
    var permitsReceiveRetry: Bool { [.accountRestricted, .networkUnavailable, .staleContext, .keyUnavailable].contains(self) }
}

/// Internal journal projection. External adapters must build safe public values, never export these rows.
struct AccountOperationSnapshot: Equatable, Sendable {
    var operationID: String
    var request: AccountOperationRequest
    var effect: AccountOperationEffect
    var state: AccountOperationState
    var closeReason: AccountOperationCloseReason? = nil
    var blocker: AccountOperationBlocker? = nil
    var allocation: ReceiveAllocation? = nil
    var observation: AccountSyncRecord? = nil
}

struct AccountOperationResult: Codable, Equatable, Sendable {
    var version: UInt64 = 1
    var generation: UInt64
    var credentialGeneration: UInt64
    var state: AccountOperationState = .pending
    var closeReason: AccountOperationCloseReason? = nil
    var blocker: AccountOperationBlocker? = nil
    var observation: AccountSyncRecord? = nil
}

func accountOperationRequest(_ record: RequestRecord) throws -> AccountOperationRequest {
    guard record.paymentID == nil, AccountOperationEffect(method: record.method) != nil else { throw PaymentFailure.unavailable }
    guard [1, 2].contains(record.formatVersion) else { throw ContinuityError.incompatibleSchema }
    return try JSONDecoder().decode(AccountOperationRequest.self, from: record.binding)
}

func accountOperationSnapshot(_ record: RequestRecord, in state: CanonicalState) throws -> AccountOperationSnapshot {
    let request = try accountOperationRequest(record)
    guard let effect = AccountOperationEffect(method: record.method) else { throw PaymentFailure.unavailable }
    let result = record.result.isEmpty ? nil : try? JSONDecoder().decode(AccountOperationResult.self, from: record.result)
    let legacy = effect == .receive && record.disposition == .closed
        ? (try? JSONDecoder().decode(ReceiveAllocation.self, from: record.result)) : nil
    guard record.result.isEmpty || result != nil || legacy != nil else { throw ContinuityError.invalidState }
    if let result {
        guard result.version == 1, result.generation > 0, result.credentialGeneration > 0,
              record.ownerGeneration == nil || record.ownerGeneration == result.generation,
              (result.state == .closed) == (result.closeReason != nil),
              result.state != .allocated else { throw ContinuityError.invalidState }
        if let observation = result.observation {
            guard result.state == .completed, effect == .synchronize,
                  observation.accountID == request.accountID, observation.network == request.network,
                  observation.generation == result.generation, observation.sequence > 0,
                  (-1...Int64(0x7fff_ffff)).contains(observation.receivingHorizon),
                  (-1...Int64(0x7fff_ffff)).contains(observation.changeHorizon) else { throw ContinuityError.invalidState }
        }
    }
    var snapshot = AccountOperationSnapshot(operationID: record.id, request: request, effect: effect, state: .pending)
    if record.disposition == .invalidated {
        let grant = state.authorization.grants.first { $0.id == record.originGrantID }
        let retired = grant?.revoked == true || grant?.expiredObserved == true ||
            result.map { $0.credentialGeneration != grant?.credentialGeneration } == true
        snapshot.state = .closed
        snapshot.closeReason = retired ? .authorizationInvalidated : .invalidated
        return snapshot
    }
    // Allocated M2 rows retain their original encoding, keeping old journals/readers compatible.
    if let allocation = legacy {
        guard allocation.operationID == record.id, allocation.accountID == request.accountID,
              allocation.network == request.network, allocation.index < 0x8000_0000,
              !allocation.address.isEmpty else { throw ContinuityError.invalidState }
        snapshot.state = .allocated; snapshot.allocation = allocation
        return snapshot
    }
    guard let result else {
        guard record.result.isEmpty, record.disposition == .unsubmitted else { throw ContinuityError.invalidState }
        return snapshot
    }
    guard result.version == 1,
          (record.disposition == .unsubmitted && result.state == .pending) ||
          (record.disposition == .closed && [.completed, .closed].contains(result.state)),
          (result.state != .completed || effect == .synchronize && result.observation != nil),
          (result.state != .closed || result.closeReason != nil) else { throw ContinuityError.invalidState }
    snapshot.state = result.state; snapshot.closeReason = result.closeReason; snapshot.blocker = result.blocker
    snapshot.observation = result.observation
    if snapshot.observation?.generation != state.authorization.generation { snapshot.observation?.fresh = false }
    return snapshot
}

/// Called by the coordinator's common validator; only this new account-operation format is owned here.
func validateAccountOperationRecords(_ state: CanonicalState) throws {
    for record in state.requests where AccountOperationEffect(method: record.method) != nil {
        guard [1, 2].contains(record.formatVersion) else { throw ContinuityError.incompatibleSchema }
        guard record.formatVersion == 2 else { continue }
        let request = try accountOperationRequest(record)
        guard validPaymentKey(request.requestKey), record.key == request.requestKey,
              request.network == state.authorization.network, !request.accountID.isEmpty, !record.result.isEmpty,
              let ownerGeneration = record.ownerGeneration, ownerGeneration > 0,
              ownerGeneration <= state.authorization.generation,
              let grant = state.authorization.grants.first(where: { $0.id == record.originGrantID }),
              grant.integrationID == record.principalID else { throw ContinuityError.invalidState }
        _ = try accountOperationSnapshot(record, in: state)
    }
}
