import Foundation

struct AccountSyncRecord: Codable, Equatable, Sendable {
    var accountID: String
    var network: String
    var providerID: String
    var viewID: String
    var chainTip: String
    var observedAt: Int64
    var complete: Bool
    var fresh: Bool
    var balance: Int64?
    var snapshot: Data
    var receivingHorizon: Int64
    var changeHorizon: Int64
    var sequence: UInt64 = 0
    var generation: UInt64 = 0
}
struct ReceiveRequest: Codable, Equatable, Sendable {
    var accountID: String
    var network: String
    var requestKey: String
}
struct ReceiveAllocation: Codable, Equatable, Sendable {
    var operationID: String
    var accountID: String
    var network: String
    var index: UInt32
    var address: String
}
protocol AccountChainBoundary: Sendable {
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String
}

func requireAccountCustody(_ state: CanonicalState, accountID: String, network: String) throws {
    guard let custody = state.custody, custody.walletID == state.authorization.walletID,
          custody.network == state.authorization.network, custody.accountID == accountID,
          custody.network == network else { throw PaymentFailure.unavailable }
    try custody.validate()
}

func beginAccountRefresh(_ state: inout CanonicalState, accountID: String, network: String) throws -> AccountSyncRecord {
    try requireAccountCustody(state, accountID: accountID, network: network)
    let index = state.publicSnapshots.firstIndex { $0.accountID == accountID }
    var value = index.map { state.publicSnapshots[$0] } ?? AccountSyncRecord(accountID: accountID, network: network,
        providerID: "", viewID: "", chainTip: "", observedAt: 0, complete: false, fresh: false,
        balance: nil, snapshot: Data(), receivingHorizon: -1, changeHorizon: -1)
    guard value.sequence < UInt64.max else { throw PaymentFailure.staleContext }
    value.sequence += 1
    value.generation = state.authorization.generation
    value.fresh = false
    if let index { state.publicSnapshots[index] = value } else { state.publicSnapshots.append(value) }
    return value
}

func completeAccountRefresh(_ state: inout CanonicalState, token: AccountSyncRecord,
                            observed: AccountSyncRecord) throws -> AccountSyncRecord {
    try requireAccountCustody(state, accountID: token.accountID, network: token.network)
    guard observed.accountID == token.accountID, observed.network == token.network,
          (-1...Int64(0x7fff_ffff)).contains(observed.receivingHorizon),
          (-1...Int64(0x7fff_ffff)).contains(observed.changeHorizon),
          let index = state.publicSnapshots.firstIndex(where: { $0.accountID == token.accountID }),
          state.publicSnapshots[index].sequence == token.sequence,
          state.publicSnapshots[index].generation == token.generation,
          state.authorization.generation == token.generation else { throw PaymentFailure.staleContext }
    var value = observed
    value.sequence = token.sequence
    value.generation = token.generation
    state.publicSnapshots[index] = value
    return value
}

private func nextReceivingIndex(_ allocation: AllocationRecord?, horizon: Int64) throws -> UInt32 {
    guard (-1...Int64(0x7fff_ffff)).contains(horizon) else { throw PaymentFailure.staleContext }
    let next: UInt64
    if let high = allocation?.issuedHighWater {
        guard high < 0x7fff_ffff else { throw PaymentFailure.accountRestricted }
        next = high + 1
    } else { next = 0 }
    guard next <= UInt64(horizon + 20), let index = UInt32(exactly: next), index < 0x8000_0000 else {
        throw PaymentFailure.accountRestricted
    }
    return index
}

/// Receive effects and explicit synchronization share the authoritative request/anchor store.
actor ReceiveEngine {
    private let continuity: ContinuityCoordinator
    private let policy: AuthorityPolicy
    private let boundary: any AccountChainBoundary
    private let clock: any PaymentClock

    init(continuity: ContinuityCoordinator, policy: AuthorityPolicy, boundary: any AccountChainBoundary,
         clock: any PaymentClock = SystemPaymentClock()) {
        self.continuity = continuity
        self.policy = policy
        self.boundary = boundary
        self.clock = clock
    }

    func synchronize(accountID: String, network: String, session: AuthorizationSession,
                     connectionID: String, peer: PeerEvidence) async throws -> AccountSyncRecord {
        try await refresh(accountID: accountID, network: network, capability: "sync",
            session: session, connectionID: connectionID, peer: peer)
    }

    func cached(accountID: String, network: String, session: AuthorizationSession,
                connectionID: String, peer: PeerEvidence) throws -> AccountSyncRecord? {
        try command("account.read", accountID: accountID, network: network, capability: "read",
                    session: session, connectionID: connectionID, peer: peer) { state in
            guard var snapshot = state.publicSnapshots.first(where: { $0.accountID == accountID && $0.network == network }) else {
                return nil
            }
            // This is a projection: an owner reset retains public observations but retires their generation.
            if snapshot.generation != state.authorization.generation { snapshot.fresh = false }
            return snapshot
        }
    }

    func create(_ request: ReceiveRequest, session: AuthorizationSession,
                connectionID: String, peer: PeerEvidence) async throws -> ReceiveAllocation {
        guard validPaymentKey(request.requestKey) else { throw PaymentFailure.invalidRequest }
        let binding = try paymentEncoding(request)
        let principal = session.principal.integrationID
        let id = try command("receive.request", accountID: request.accountID, network: request.network,
                             capability: "receive", session: session, connectionID: connectionID, peer: peer) { state in
            if let old = state.requests.first(where: {
                $0.principalID == principal && $0.method == "create_receive_request" && $0.key == request.requestKey
            }) {
                guard old.originGrantID == session.principal.grantID else { throw PaymentFailure.unavailable }
                guard old.binding == binding else { throw PaymentFailure.conflictingRequest }
                return old.id
            }
            let id = UUID().uuidString
            state.requests.append(RequestRecord(id: id, principalID: principal, method: "create_receive_request",
                key: request.requestKey, binding: binding, disposition: .unsubmitted, result: Data(),
                consumedAttemptID: nil, tombstone: false, originGrantID: session.principal.grantID))
            return id
        }
        if let retained = try result(id: id, request: request, session: session, connectionID: connectionID, peer: peer) {
            return retained
        }
        let observation = try await refresh(accountID: request.accountID, network: request.network,
            capability: "receive", session: session, connectionID: connectionID, peer: peer)
        guard observation.complete, observation.fresh else { throw PaymentFailure.networkUnavailable }
        while true {
            let index: UInt32 = try command("receive.select", accountID: request.accountID, network: request.network,
                capability: "receive", session: session, connectionID: connectionID, peer: peer) { state in
                guard let snapshot = state.publicSnapshots.first(where: { $0.accountID == request.accountID }),
                      snapshot.sequence == observation.sequence, snapshot.generation == observation.generation,
                      snapshot.fresh, snapshot.complete else { throw PaymentFailure.staleContext }
                let allocation = state.allocations.first { $0.accountID == request.accountID && $0.branch == "receiving" }
                return try nextReceivingIndex(allocation, horizon: snapshot.receivingHorizon)
            }
            let address = try await boundary.receivingAddress(at: index, accountID: request.accountID, network: request.network)
            guard !address.isEmpty else { throw PaymentFailure.unavailable }
            let allocation = ReceiveAllocation(operationID: id, accountID: request.accountID,
                network: request.network, index: index, address: address)
            let committed: ReceiveAllocation? = try command("receive.allocate", accountID: request.accountID, network: request.network,
                capability: "receive", session: session, connectionID: connectionID, peer: peer) { state in
                guard let requestIndex = state.requests.firstIndex(where: { $0.id == id }) else { throw PaymentFailure.unavailable }
                if !state.requests[requestIndex].result.isEmpty {
                    return try JSONDecoder().decode(ReceiveAllocation.self, from: state.requests[requestIndex].result)
                }
                guard state.requests[requestIndex].disposition == .unsubmitted,
                      let snapshot = state.publicSnapshots.first(where: { $0.accountID == request.accountID }),
                      snapshot.sequence == observation.sequence, snapshot.generation == state.authorization.generation,
                      snapshot.complete, snapshot.fresh else { throw PaymentFailure.staleContext }
                let existing = state.allocations.firstIndex { $0.accountID == request.accountID && $0.branch == "receiving" }
                let next = try nextReceivingIndex(existing.map { state.allocations[$0] }, horizon: snapshot.receivingHorizon)
                guard next == index else { return nil }
                var row = existing.map { state.allocations[$0] } ?? AllocationRecord(accountID: request.accountID,
                    branch: "receiving", issuedIndices: [], issuedHighWater: nil, confirmedHistoryHorizon: nil, issuanceEvidence: Data())
                row.issuedIndices.append(UInt64(index)); row.issuedHighWater = UInt64(index)
                row.confirmedHistoryHorizon = snapshot.receivingHorizon >= 0 ? UInt64(snapshot.receivingHorizon) : nil
                row.issuanceEvidence = try paymentEncoding(snapshot)
                if let existing { state.allocations[existing] = row } else { state.allocations.append(row) }
                state.requests[requestIndex].result = try paymentEncoding(allocation)
                state.requests[requestIndex].disposition = .closed
                return allocation
            }
            if let committed { return committed }
        }
    }

    private func result(id: String, request: ReceiveRequest, session: AuthorizationSession,
                        connectionID: String, peer: PeerEvidence) throws -> ReceiveAllocation? {
        try command("receive.read", accountID: request.accountID, network: request.network, capability: "receive",
                    session: session, connectionID: connectionID, peer: peer) { state in
            guard let record = state.requests.first(where: { $0.id == id && $0.principalID == session.principal.integrationID &&
                $0.originGrantID == session.principal.grantID }) else {
                throw PaymentFailure.unavailable
            }
            if record.result.isEmpty {
                guard record.disposition == .unsubmitted else { throw PaymentFailure.staleContext }
                return nil
            }
            return try JSONDecoder().decode(ReceiveAllocation.self, from: record.result)
        }
    }

    private func refresh(accountID: String, network: String, capability: String,
                         session: AuthorizationSession, connectionID: String, peer: PeerEvidence) async throws -> AccountSyncRecord {
        let token = try command("account.refreshBegin", accountID: accountID, network: network, capability: capability,
            session: session, connectionID: connectionID, peer: peer) { state in
            try beginAccountRefresh(&state, accountID: accountID, network: network)
        }
        let observed = try await boundary.refresh(accountID: accountID, network: network)
        return try command("account.refreshComplete", accountID: accountID, network: network, capability: capability,
            session: session, connectionID: connectionID, peer: peer) { state in
            try completeAccountRefresh(&state, token: token, observed: observed)
        }
    }

    private func command<T>(_ name: String, accountID: String, network: String, capability: String,
                            session: AuthorizationSession, connectionID: String, peer: PeerEvidence,
                            operation: (inout CanonicalState) throws -> T) throws -> T {
        let now = clock.read().wall
        return try continuity.transaction(classification: name, mutation: { state -> Result<T, any Error> in
            guard state.mode == .enabled, state.history == .complete else { throw PaymentFailure.recoveryRequired }
            var authority = AuthorizationAuthority(ledger: state.authorization, expectedBridgeIdentity: policy.bridge,
                trustedOwnerIdentity: policy.owner, maximumOwnerAuthenticationAge: policy.ownerAuthenticationAge)
            for id in authority.observeExpirations(now: now) { state.invalidateUnsubmitted(grantID: id) }
            state.authorization = authority.ledger
            return Result {
                try authority.authorize(session: session, connectionID: connectionID, peer: peer,
                    operation: AuthorizationOperation(walletID: state.authorization.walletID, network: network,
                        accountID: accountID, capability: capability), now: now)
                try requireAccountCustody(state, accountID: accountID, network: network)
                return try operation(&state)
            }
        }, projection: { _, outcome in try outcome.get() })
    }
}
