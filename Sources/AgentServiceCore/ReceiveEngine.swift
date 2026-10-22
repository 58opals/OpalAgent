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

/// Receive and keyed synchronization own durable identities; polling never starts work.
actor ReceiveEngine {
    private let continuity: ContinuityCoordinator
    private let policy: AuthorityPolicy
    private let boundary: any AccountChainBoundary
    private let clock: any PaymentClock
    private var running: [String: Task<Void, any Error>] = [:]
    private var stopping = false
    private var activeCalls = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(continuity: ContinuityCoordinator, policy: AuthorityPolicy, boundary: any AccountChainBoundary,
         clock: any PaymentClock = SystemPaymentClock()) {
        self.continuity = continuity; self.policy = policy; self.boundary = boundary; self.clock = clock
    }

    // The boundary can ignore cancellation. Retain every admitted call and keyed task until
    // it actually returns; shutdown does not close or erase its durable operation identity.
    func shutdown() async {
        stopping = true
        while !running.isEmpty || activeCalls > 0 {
            if let task = running.values.first { _ = await task.result }
            else { await withCheckedContinuation { drainWaiters.append($0) } }
        }
    }

    // Compatibility entry: explicit unkeyed refresh remains an awaited sync command.
    func synchronize(accountID: String, network: String, session: AuthorizationSession,
                     connectionID: String, peer: PeerEvidence) async throws -> AccountSyncRecord {
        try beginCall()
        defer { finishCall() }
        return try await refresh(accountID: accountID, network: network, capability: "sync",
                                 session: session, connectionID: connectionID, peer: peer)
    }

    func synchronize(_ request: AccountOperationRequest, session: AuthorizationSession,
                     connectionID: String, peer: PeerEvidence) async throws -> AccountOperationSnapshot {
        try requireRunning()
        let value = try begin(request, effect: .synchronize, session: session, connectionID: connectionID, peer: peer)
        if value.state == .pending { _ = schedule(value, session: session, connectionID: connectionID, peer: peer) }
        return value
    }

    func createOperation(_ request: ReceiveRequest, session: AuthorizationSession,
                         connectionID: String, peer: PeerEvidence) async throws -> AccountOperationSnapshot {
        try requireRunning()
        let value = try begin(AccountOperationRequest(accountID: request.accountID, network: request.network,
            requestKey: request.requestKey), effect: .receive, session: session, connectionID: connectionID, peer: peer)
        if value.state == .pending { _ = schedule(value, session: session, connectionID: connectionID, peer: peer) }
        return value
    }

    // M2 callers await the same operation; the public facade uses createOperation for prompt pending results.
    func create(_ request: ReceiveRequest, session: AuthorizationSession,
                connectionID: String, peer: PeerEvidence) async throws -> ReceiveAllocation {
        try beginCall()
        defer { finishCall() }
        let value = try begin(AccountOperationRequest(accountID: request.accountID, network: request.network,
            requestKey: request.requestKey), effect: .receive, session: session, connectionID: connectionID, peer: peer)
        if value.state == .pending {
            try await schedule(value, session: session, connectionID: connectionID, peer: peer).value
        }
        let current = try disclose(id: value.operationID, request: value.request, capability: "receive",
                                   session: session, connectionID: connectionID, peer: peer)
        guard let allocation = current.allocation else { throw current.blocker?.failure ?? PaymentFailure.invalidTransition }
        return allocation
    }

    func cached(accountID: String, network: String, session: AuthorizationSession,
                connectionID: String, peer: PeerEvidence) throws -> AccountSyncRecord? {
        try requireRunning()
        return try command("account.read", accountID: accountID, network: network, capability: "read",
                    session: session, connectionID: connectionID, peer: peer) { state in
            guard var snapshot = state.publicSnapshots.first(where: { $0.accountID == accountID && $0.network == network }) else { return nil }
            if snapshot.generation != state.authorization.generation { snapshot.fresh = false }
            return snapshot
        }
    }

    func get(id: String, accountID: String, network: String, session: AuthorizationSession,
             connectionID: String, peer: PeerEvidence) throws -> AccountOperationSnapshot {
        try requireRunning()
        return try disclose(id: id, request: .init(accountID: accountID, network: network, requestKey: ""), capability: "read",
                     session: session, connectionID: connectionID, peer: peer)
    }

    func lookup(request: AccountOperationRequest, effect: AccountOperationEffect, session: AuthorizationSession,
                connectionID: String, peer: PeerEvidence) throws -> AccountOperationSnapshot {
        try requireRunning()
        guard validPaymentKey(request.requestKey) else { throw PaymentFailure.invalidRequest }
        return try command("account.operationLookup", accountID: request.accountID, network: request.network, capability: "read",
            session: session, connectionID: connectionID, peer: peer) { state in
            guard let record = state.requests.first(where: { $0.principalID == session.principal.integrationID &&
                $0.method == effect.method && $0.key == request.requestKey && $0.originGrantID == session.principal.grantID }),
                try accountOperationRequest(record) == request else { throw PaymentFailure.unavailable }
            return try accountOperationSnapshot(record, in: state)
        }
    }

    func cancel(id: String, accountID: String, network: String, session: AuthorizationSession,
                connectionID: String, peer: PeerEvidence) throws -> AccountOperationSnapshot {
        try requireRunning()
        return try command("account.operationCancel", accountID: accountID, network: network, capability: "cancel",
            session: session, connectionID: connectionID, peer: peer) { state in
            let index = try visibleIndex(id, accountID: accountID, network: network, session: session, state: state)
            let snapshot = try accountOperationSnapshot(state.requests[index], in: state)
            if snapshot.state == .closed { return snapshot }
            guard snapshot.state == .pending else { throw PaymentFailure.invalidTransition }
            var result = try payload(state.requests[index], state: state, session: session)
            result.state = .closed; result.closeReason = .cancelled; result.blocker = nil
            state.requests[index].result = try paymentEncoding(result)
            state.requests[index].disposition = .closed
            return try accountOperationSnapshot(state.requests[index], in: state)
        }
    }

    private func begin(_ request: AccountOperationRequest, effect: AccountOperationEffect, session: AuthorizationSession,
                       connectionID: String, peer: PeerEvidence) throws -> AccountOperationSnapshot {
        guard validPaymentKey(request.requestKey), !request.accountID.isEmpty, !request.network.isEmpty else { throw PaymentFailure.invalidRequest }
        let binding = try paymentEncoding(request)
        return try command(effect == .receive ? "receive.request" : "sync.request", accountID: request.accountID,
            network: request.network, capability: effect.capability, session: session, connectionID: connectionID, peer: peer) { state in
            if let record = state.requests.first(where: { $0.principalID == session.principal.integrationID &&
                $0.method == effect.method && $0.key == request.requestKey }) {
                guard record.originGrantID == session.principal.grantID else { throw PaymentFailure.unavailable }
                guard record.binding == binding else { throw PaymentFailure.conflictingRequest }
                return try accountOperationSnapshot(record, in: state)
            }
            let result = AccountOperationResult(generation: state.authorization.generation,
                                                credentialGeneration: session.credentialGeneration)
            let record = RequestRecord(id: UUID().uuidString, principalID: session.principal.integrationID,
                method: effect.method, key: request.requestKey, binding: binding, disposition: .unsubmitted,
                result: try paymentEncoding(result), consumedAttemptID: nil, tombstone: false,
                formatVersion: 2, ownerGeneration: state.authorization.generation, originGrantID: session.principal.grantID)
            state.requests.append(record)
            return try accountOperationSnapshot(record, in: state)
        }
    }

    private func schedule(_ snapshot: AccountOperationSnapshot, session: AuthorizationSession,
                          connectionID: String, peer: PeerEvidence) -> Task<Void, any Error> {
        if let task = running[snapshot.operationID] { return task }
        let task = Task { [self] in
            defer { running.removeValue(forKey: snapshot.operationID) }
            do {
                try await run(snapshot, session: session, connectionID: connectionID, peer: peer)
            } catch {
                try? recordFailure(snapshot, error: error, session: session, connectionID: connectionID, peer: peer)
                throw error
            }
        }
        running[snapshot.operationID] = task
        return task
    }

    private func run(_ snapshot: AccountOperationSnapshot, session: AuthorizationSession,
                     connectionID: String, peer: PeerEvidence) async throws {
        guard !stopping else { return }
        let request = snapshot.request
        let token: AccountSyncRecord? = try command("account.operationBegin", accountID: request.accountID,
            network: request.network, capability: snapshot.effect.capability, session: session, connectionID: connectionID, peer: peer) { state in
            let index = try visibleIndex(snapshot.operationID, accountID: request.accountID, network: request.network,
                                         session: session, state: state)
            guard state.requests[index].disposition == .unsubmitted else { return nil }
            let result = try payload(state.requests[index], state: state, session: session)
            guard result.generation == state.authorization.generation,
                  result.credentialGeneration == session.credentialGeneration else { throw PaymentFailure.staleContext }
            return try beginAccountRefresh(&state, accountID: request.accountID, network: request.network)
        }
        guard let token else { return }
        let observed = try await boundary.refresh(accountID: request.accountID, network: request.network)
        let observation: AccountSyncRecord? = try command("account.operationCompleteRefresh", accountID: request.accountID,
            network: request.network, capability: snapshot.effect.capability, session: session, connectionID: connectionID, peer: peer) { state in
            let index = try visibleIndex(snapshot.operationID, accountID: request.accountID, network: request.network, session: session, state: state)
            guard state.requests[index].disposition == .unsubmitted else { return nil }
            let value = try completeAccountRefresh(&state, token: token, observed: observed)
            if snapshot.effect == .synchronize {
                var result = try payload(state.requests[index], state: state, session: session)
                result.state = .completed; result.blocker = nil; result.observation = value
                state.requests[index].result = try paymentEncoding(result); state.requests[index].disposition = .closed
            }
            return value
        }
        guard !stopping, snapshot.effect == .receive, let observation else { return }
        guard observation.complete, observation.fresh else { throw PaymentFailure.networkUnavailable }
        while true {
            guard !stopping else { return }
            let next: UInt32? = try command("receive.select", accountID: request.accountID, network: request.network,
                capability: "receive", session: session, connectionID: connectionID, peer: peer) { state in
                let index = try visibleIndex(snapshot.operationID, accountID: request.accountID, network: request.network, session: session, state: state)
                guard state.requests[index].disposition == .unsubmitted else { return nil }
                guard let current = state.publicSnapshots.first(where: { $0.accountID == request.accountID }),
                      current.sequence == observation.sequence, current.generation == observation.generation,
                      current.fresh, current.complete else { throw PaymentFailure.staleContext }
                return try nextReceivingIndex(state.allocations.first { $0.accountID == request.accountID && $0.branch == "receiving" },
                                               horizon: current.receivingHorizon)
            }
            guard let next else { return }
            let address = try await boundary.receivingAddress(at: next, accountID: request.accountID, network: request.network)
            guard !address.isEmpty else { throw PaymentFailure.unavailable }
            let allocation = ReceiveAllocation(operationID: snapshot.operationID, accountID: request.accountID,
                                               network: request.network, index: next, address: address)
            let done = try command("receive.allocate", accountID: request.accountID, network: request.network,
                capability: "receive", session: session, connectionID: connectionID, peer: peer) { state in
                let index = try visibleIndex(snapshot.operationID, accountID: request.accountID, network: request.network, session: session, state: state)
                guard state.requests[index].disposition == .unsubmitted else { return true }
                guard let current = state.publicSnapshots.first(where: { $0.accountID == request.accountID }),
                      current.sequence == observation.sequence, current.generation == state.authorization.generation,
                      current.fresh, current.complete else { throw PaymentFailure.staleContext }
                let existing = state.allocations.firstIndex { $0.accountID == request.accountID && $0.branch == "receiving" }
                let nextCurrent = try nextReceivingIndex(existing.map { state.allocations[$0] }, horizon: current.receivingHorizon)
                guard nextCurrent == next else { return false }
                var row = existing.map { state.allocations[$0] } ?? AllocationRecord(accountID: request.accountID,
                    branch: "receiving", issuedIndices: [], issuedHighWater: nil, confirmedHistoryHorizon: nil, issuanceEvidence: Data())
                row.issuedIndices.append(UInt64(next)); row.issuedHighWater = UInt64(next)
                row.confirmedHistoryHorizon = current.receivingHorizon >= 0 ? UInt64(current.receivingHorizon) : nil
                row.issuanceEvidence = try paymentEncoding(current)
                if let existing { state.allocations[existing] = row } else { state.allocations.append(row) }
                state.requests[index].result = try paymentEncoding(allocation)
                state.requests[index].disposition = .closed
                return true
            }
            if done { return }
        }
    }

    private func recordFailure(_ snapshot: AccountOperationSnapshot, error: any Error, session: AuthorizationSession,
                               connectionID: String, peer: PeerEvidence) throws {
        try command("account.operationFailure", accountID: snapshot.request.accountID, network: snapshot.request.network,
            capability: snapshot.effect.capability, session: session, connectionID: connectionID, peer: peer) { state in
            let index = try visibleIndex(snapshot.operationID, accountID: snapshot.request.accountID,
                network: snapshot.request.network, session: session, state: state)
            guard state.requests[index].disposition == .unsubmitted else { return }
            var result = try payload(state.requests[index], state: state, session: session)
            result.blocker = AccountOperationBlocker(error)
            if snapshot.effect == .synchronize || result.blocker?.permitsReceiveRetry != true {
                result.state = .closed; result.closeReason = .failed; state.requests[index].disposition = .closed
            }
            state.requests[index].result = try paymentEncoding(result)
        }
    }

    private func disclose(id: String, request: AccountOperationRequest, capability: String, session: AuthorizationSession,
                          connectionID: String, peer: PeerEvidence) throws -> AccountOperationSnapshot {
        try command("account.operationRead", accountID: request.accountID, network: request.network, capability: capability,
            session: session, connectionID: connectionID, peer: peer) { state in
            let index = try visibleIndex(id, accountID: request.accountID, network: request.network, session: session, state: state)
            return try accountOperationSnapshot(state.requests[index], in: state)
        }
    }

    private func visibleIndex(_ id: String, accountID: String, network: String, session: AuthorizationSession,
                              state: CanonicalState) throws -> Int {
        guard let index = state.requests.firstIndex(where: { $0.id == id && $0.principalID == session.principal.integrationID &&
            $0.originGrantID == session.principal.grantID && $0.paymentID == nil && AccountOperationEffect(method: $0.method) != nil }) else {
            throw PaymentFailure.unavailable
        }
        let request = try accountOperationRequest(state.requests[index])
        guard request.accountID == accountID, request.network == network else { throw PaymentFailure.unavailable }
        return index
    }

    private func payload(_ record: RequestRecord, state: CanonicalState, session: AuthorizationSession) throws -> AccountOperationResult {
        if record.result.isEmpty { return AccountOperationResult(generation: state.authorization.generation,
                                                               credentialGeneration: session.credentialGeneration) }
        return try JSONDecoder().decode(AccountOperationResult.self, from: record.result)
    }

    private func refresh(accountID: String, network: String, capability: String, session: AuthorizationSession,
                         connectionID: String, peer: PeerEvidence) async throws -> AccountSyncRecord {
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

    private func requireRunning() throws {
        guard !stopping else { throw PaymentFailure.unavailable }
    }

    private func beginCall() throws {
        try requireRunning()
        activeCalls += 1
    }

    private func finishCall() {
        activeCalls -= 1
        if activeCalls == 0 {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    // Internal completion writes remain available while previously admitted work drains.
    private func command<T>(_ name: String, accountID: String, network: String, capability: String,
                            session: AuthorizationSession, connectionID: String, peer: PeerEvidence,
                            operation: (inout CanonicalState) throws -> T) throws -> T {
        let now = clock.read().wall
        return try continuity.transaction(classification: name, mutation: { state -> Result<T, any Error> in
            guard state.mode == .enabled, state.history == .complete else { throw PaymentFailure.recoveryRequired }
            var authority = AuthorizationAuthority(ledger: state.authorization, expectedBridgeIdentity: policy.bridge,
                trustedOwnerIdentity: policy.owner, maximumOwnerAuthenticationAge: policy.ownerAuthenticationAge, expectedAppleIntegrationIdentity: policy.appleIntegration)
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
