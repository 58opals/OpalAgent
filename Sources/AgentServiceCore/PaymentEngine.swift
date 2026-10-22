import Foundation

private struct PaymentAccess: Sendable {
    var session: AuthorizationSession
    var connectionID: String
    var peer: PeerEvidence
}

private final class HandoffWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    func mark() { lock.withLock { entered = true } }
    var wasEntered: Bool { lock.withLock { entered } }
}

// The actor owns asynchronous work and the local transport slot. ContinuityCoordinator owns
// every durable transition and final handoff, including across a suspension in Base work.
actor PaymentEngine {
    private let continuity: ContinuityCoordinator
    private let authorityPolicy: AuthorityPolicy
    private let boundary: any PaymentExecutionBoundary
    private let clock: any PaymentClock
    private let runtimeID = UUID().uuidString
    private let startedMonotonic: UInt64
    private var preparing: Set<String> = []
    private var starting: Set<String> = []
    private var activeAttemptID: String?
    private var activeInvocation: PaymentTransportInvocation?
    private var stopping = false
    private var background: [UUID: Task<Void, Never>] = [:]
    private var activeCalls = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(continuity: ContinuityCoordinator, authorityPolicy: AuthorityPolicy,
         boundary: any PaymentExecutionBoundary, clock: any PaymentClock = SystemPaymentClock()) {
        self.continuity = continuity
        self.authorityPolicy = authorityPolicy
        self.boundary = boundary
        self.clock = clock
        self.startedMonotonic = clock.read().monotonic
    }

    // Terminal admission closure. Cancellation of a caller is not evidence that a boundary
    // stopped: every admitted call and background result retains this owner until it returns.
    func shutdown() async {
        stopping = true
        while !background.isEmpty || activeCalls > 0 {
            if let task = background.values.first { await task.value }
            else { await withCheckedContinuation { drainWaiters.append($0) } }
        }
    }

    func prepare(_ request: PaymentRequest, session: AuthorizationSession,
                 connectionID: String, peer: PeerEvidence) throws -> PaymentSnapshot {
        try requireRunning()
        guard validPaymentKey(request.requestKey), request.amount > 0, request.amount <= 2_100_000_000_000_000,
              request.feeRate > 0, !request.destinationScript.isEmpty, request.destinationScript.count <= 10_000,
              !request.accountID.isEmpty, !request.network.isEmpty else { throw PaymentFailure.invalidRequest }
        let access = PaymentAccess(session: session, connectionID: connectionID, peer: peer)
        let binding = try paymentEncoding(request)
        let now = clock.read().wall
        let snapshot = try command("payment.prepare") { state in
            try Self.authorize(access, accountID: request.accountID, network: request.network,
                               capability: "prepare", state: state, policy: authorityPolicy, now: now)
            if let retained = state.requests.first(where: {
                $0.principalID == session.principal.integrationID && $0.method == "prepare_payment" && $0.key == request.requestKey
            }) {
                guard let id = retained.paymentID, let payment = state.payments.first(where: { $0.id == id }),
                      payment.originGrantID == session.principal.grantID else { throw PaymentFailure.unavailable }
                guard retained.binding == binding else { throw PaymentFailure.conflictingRequest }
                return Self.snapshot(payment, state: state)
            }
            guard !Self.isHeld(request.accountID, state: state) else { throw PaymentFailure.accountRestricted }
            guard request.expiresAt.map({ $0 > now }) ?? true else { throw PaymentFailure.invalidRequest }
            let id = UUID().uuidString
            let payment = PaymentRecord(id: id, accountID: request.accountID, network: request.network,
                originGrantID: session.principal.grantID, canonicalBytes: Data(), transactionDigest: Data(),
                selectedInputs: [], change: Data(), disposition: .preparing, liabilityUnresolved: false,
                attempts: [], evidence: [], closures: [], request: request,
                originCredentialGeneration: session.credentialGeneration,
                walletGeneration: state.authorization.generation, policyRevision: state.paymentPolicy.revision)
            state.payments.append(payment)
            state.requests.append(RequestRecord(id: UUID().uuidString, principalID: session.principal.integrationID,
                paymentID: id, method: "prepare_payment", key: request.requestKey, binding: binding,
                disposition: .unsubmitted, result: Data(), consumedAttemptID: nil, tombstone: false,
                originGrantID: session.principal.grantID))
            Self.hold(id, accountID: request.accountID, state: &state)
            return Self.snapshot(payment, state: state)
        }
        if snapshot.payment.disposition == .preparing { schedulePreparation(snapshot.payment.id) }
        return snapshot
    }

    func get(operationID: String, session: AuthorizationSession,
             connectionID: String, peer: PeerEvidence) throws -> PaymentSnapshot {
        try requireRunning()
        let access = PaymentAccess(session: session, connectionID: connectionID, peer: peer)
        let now = clock.read().wall
        return try command("payment.read") { state in
            do {
                let payment = try Self.visible(operationID, access: access, state: state,
                                               policy: authorityPolicy, capability: "read", now: now)
                return Self.snapshot(payment, state: state)
            } catch { throw PaymentFailure.unavailable }
        }
    }

    func lookup(requestKey: String, session: AuthorizationSession,
                connectionID: String, peer: PeerEvidence) throws -> PaymentSnapshot {
        try requireRunning()
        guard validPaymentKey(requestKey) else { throw PaymentFailure.invalidRequest }
        let access = PaymentAccess(session: session, connectionID: connectionID, peer: peer)
        let now = clock.read().wall
        return try command("payment.read") { state in
            do {
                guard let request = state.requests.first(where: {
                    $0.principalID == session.principal.integrationID && $0.method == "prepare_payment" && $0.key == requestKey
                }), let id = request.paymentID else { throw PaymentFailure.unavailable }
                let payment = try Self.visible(id, access: access, state: state, policy: authorityPolicy,
                                               capability: "read", now: now)
                return Self.snapshot(payment, state: state)
            } catch { throw PaymentFailure.unavailable }
        }
    }

    func ownerStatus(operationID: String, owner: OwnerAuthenticationEvidence) throws -> PaymentSnapshot {
        try requireRunning()
        return try ownerSnapshot(operationID: operationID, owner: owner)
    }

    private func ownerSnapshot(operationID: String, owner: OwnerAuthenticationEvidence) throws -> PaymentSnapshot {
        let now = clock.read().wall
        return try continuity.inspect { state in
            try Self.authority(state, policy: authorityPolicy).requireOwner(owner: owner, now: now)
            guard let payment = state.payments.first(where: { $0.id == operationID }) else { throw PaymentFailure.unavailable }
            return Self.snapshot(payment, state: state)
        }
    }

    func submit(operationID: String, session: AuthorizationSession,
                connectionID: String, peer: PeerEvidence) throws -> PaymentSnapshot {
        try requireRunning()
        let access = PaymentAccess(session: session, connectionID: connectionID, peer: peer)
        let now = clock.read().wall
        let snapshot = try command("payment.submit") { state in
            _ = try Self.visible(operationID, access: access, state: state, policy: authorityPolicy,
                                 capability: "submit", now: now)
            let index = try Self.index(operationID, state)
            if state.payments[index].disposition == .prepared {
                if state.payments[index].preview.map({ now >= $0.leaseDeadline }) == true ||
                    state.payments[index].request?.expiresAt.map({ now >= $0 }) == true {
                    Self.closeUnsubmitted(operationID, reason: "expired", state: &state)
                    return Self.snapshot(state.payments[index], state: state)
                }
                try Self.originAuthority(state.payments[index], state: state, policy: authorityPolicy, now: now)
                try Self.livePreview(state.payments[index], now: now)
                state.payments[index].disposition = state.paymentPolicy.approvalRequired ? .pendingApproval : .ready
            }
            return Self.snapshot(state.payments[index], state: state)
        }
        if [.ready, .uncertain].contains(snapshot.payment.disposition), snapshot.payment.closures.isEmpty,
           snapshot.payment.ordinaryAdmissions < 3 { scheduleRelay(operationID) }
        return snapshot
    }

    func approve(operationID: String, owner: OwnerAuthenticationEvidence,
                 expectedPreviewContextDigest: Data? = nil) throws -> PaymentSnapshot {
        try requireRunning()
        let now = clock.read().wall
        let snapshot = try command("payment.approve") { state in
            try Self.authority(state, policy: authorityPolicy).requireOwner(owner: owner, now: now)
            let index = try Self.index(operationID, state)
            let payment = state.payments[index]
            if let expectedPreviewContextDigest {
                guard expectedPreviewContextDigest == paymentPreviewContextDigest(payment, state: state),
                      !expectedPreviewContextDigest.isEmpty else { throw PaymentFailure.staleContext }
            }
            if !payment.disposition.isUnsubmitted,
               state.approvals.contains(where: { $0.paymentID == operationID && !$0.ownerRelay && $0.active &&
                    $0.generation == state.authorization.generation && $0.policyRevision == state.paymentPolicy.revision }) {
                return Self.snapshot(payment, state: state)
            }
            guard [.pendingApproval, .ready].contains(payment.disposition), let preview = payment.preview else {
                throw PaymentFailure.invalidTransition
            }
            if now >= preview.leaseDeadline || payment.request?.expiresAt.map({ now >= $0 }) == true {
                Self.closeUnsubmitted(operationID, reason: "expired", state: &state)
                return Self.snapshot(state.payments[index], state: state)
            }
            try Self.originAuthority(payment, state: state, policy: authorityPolicy, now: now)
            try Self.livePreview(payment, now: now)
            let context = try paymentEncoding(preview)
            if !state.approvals.contains(where: {
                $0.paymentID == operationID && $0.active && !$0.ownerRelay && $0.context == context &&
                $0.generation == state.authorization.generation && $0.policyRevision == state.paymentPolicy.revision
            }) {
                state.approvals.append(ApprovalRecord(id: UUID().uuidString, paymentID: operationID,
                    generation: state.authorization.generation, context: context, active: true,
                    policyRevision: state.paymentPolicy.revision))
            }
            state.payments[index].disposition = .ready
            return Self.snapshot(state.payments[index], state: state)
        }
        if snapshot.payment.disposition == .ready { scheduleRelay(operationID) }
        return snapshot
    }

    func cancel(operationID: String, session: AuthorizationSession,
                connectionID: String, peer: PeerEvidence) async throws -> PaymentSnapshot {
        try beginCall()
        defer { finishCall() }
        let access = PaymentAccess(session: session, connectionID: connectionID, peer: peer)
        let now = clock.read().wall
        _ = try command("payment.cancel") { state in
            let payment = try Self.visible(operationID, access: access, state: state, policy: authorityPolicy,
                                           capability: "cancel", now: now)
            if payment.terminalReason == "cancelled" { return }
            guard payment.disposition.isUnsubmitted else { throw PaymentFailure.invalidTransition }
            Self.closeUnsubmitted(operationID, reason: "cancelled", state: &state)
        }
        await disposeAndRelease(operationID)
        return try command("payment.cancelDisclosure") { state in
            do {
                let payment = try Self.visible(operationID, access: access, state: state,
                    policy: authorityPolicy, capability: "cancel", now: clock.read().wall)
                return Self.snapshot(payment, state: state)
            } catch { throw PaymentFailure.unavailable }
        }
    }

    func reject(operationID: String, owner: OwnerAuthenticationEvidence,
                expectedPreviewContextDigest: Data? = nil) async throws -> PaymentSnapshot {
        try beginCall()
        defer { finishCall() }
        let now = clock.read().wall
        _ = try command("payment.cancel") { state in
            try Self.authority(state, policy: authorityPolicy).requireOwner(owner: owner, now: now)
            let index = try Self.index(operationID, state)
            if let expectedPreviewContextDigest {
                guard expectedPreviewContextDigest == paymentPreviewContextDigest(state.payments[index], state: state),
                      !expectedPreviewContextDigest.isEmpty else { throw PaymentFailure.staleContext }
            }
            if state.payments[index].terminalReason == "rejected" { return }
            guard state.payments[index].disposition.isUnsubmitted else { throw PaymentFailure.invalidTransition }
            Self.closeUnsubmitted(operationID, reason: "rejected", state: &state)
        }
        await disposeAndRelease(operationID)
        return try ownerSnapshot(operationID: operationID, owner: owner)
    }

    func changePolicy(approvalRequired: Bool, owner: OwnerAuthenticationEvidence,
                      expectedRevision: UInt64? = nil) async throws {
        try beginCall()
        defer { finishCall() }
        let now = clock.read().wall
        let invalidated: [String] = try command("payment.policy") { state in
            try Self.authority(state, policy: authorityPolicy).requireOwner(owner: owner, now: now)
            if let expectedRevision {
                guard expectedRevision == state.paymentPolicy.revision else { throw PaymentFailure.staleContext }
            }
            guard state.paymentPolicy.revision < UInt64.max else { throw PaymentFailure.invalidTransition }
            state.paymentPolicy.revision += 1
            state.paymentPolicy.approvalRequired = approvalRequired
            let ids = state.payments.filter { $0.disposition.isUnsubmitted }.map(\.id)
            for id in ids { Self.closeUnsubmitted(id, reason: "authorizationInvalidated", state: &state) }
            for index in state.approvals.indices { state.approvals[index].active = false }
            return ids
        }
        for id in invalidated { await disposeAndRelease(id) }
    }

    // Production startup/wake/continuation calls this; reads never schedule work.
    func continuePending() async {
        guard !stopping else { return }
        activeCalls += 1
        defer { finishCall() }
        let now = clock.read().wall
        let payments: [PaymentRecord]
        do {
            payments = try command("payment.expire", enabled: false) { state in
                for payment in state.payments where payment.disposition.isUnsubmitted &&
                    (payment.request?.expiresAt.map { now >= $0 } == true || payment.preview.map { now >= $0.leaseDeadline } == true) {
                    Self.closeUnsubmitted(payment.id, reason: "expired", state: &state)
                }
                return state.payments
            }
        } catch { return }
        for payment in payments {
            guard !stopping else { return }
            if payment.disposition == .preparing { schedulePreparation(payment.id) }
            if !payment.disposition.isUnsubmitted && !payment.liabilityUnresolved &&
                (payment.disposition == .invalidated || payment.terminalReason != nil) {
                await disposeAndRelease(payment.id)
            }
            var reconciledSequence: UInt64?
            if payment.liabilityUnresolved {
                try? await completeReconciliation(operationID: payment.id)
                reconciledSequence = try? continuity.inspect { state in
                    state.payments[try Self.index(payment.id, state)].observationSequence
                }
            }
            if let current = try? continuity.inspect({ state -> PaymentRecord? in
                guard state.mode == .enabled else { return nil }
                return state.payments[try Self.index(payment.id, state)]
            }), [.ready, .uncertain].contains(current.disposition), current.closures.isEmpty,
               current.ordinaryAdmissions < 3 {
                scheduleRelay(current.id, reconciledSequence: reconciledSequence)
            }
        }
    }

    func reconcile(operationID: String) async throws {
        try beginCall()
        defer { finishCall() }
        try await completeReconciliation(operationID: operationID)
    }

    private func completeReconciliation(operationID: String) async throws {
        try requireRunning()
        let captured: (generation: UInt64, payment: PaymentRecord) = try command("payment.observeBegin", enabled: false) { state in
            let index = try Self.index(operationID, state)
            guard state.payments[index].observationSequence < UInt64.max else { throw PaymentFailure.invalidTransition }
            state.payments[index].observationSequence += 1
            return (state.authorization.generation, state.payments[index])
        }
        let observation: PaymentObservation
        do { observation = try await boundary.observe(captured.payment) }
        catch {
            try? command("payment.blocker", enabled: false) { state in
                let index = try Self.index(operationID, state)
                if state.authorization.generation == captured.generation &&
                    state.payments[index].observationSequence == captured.payment.observationSequence {
                    state.payments[index].blocker = "networkUnavailable"
                }
            }
            throw error
        }
        let decisive = Self.accepts(observation, payment: captured.payment) || Self.conflicts(observation, payment: captured.payment)
        // Retain a late factual observation without starting disposal after admission closes.
        var releasable = !stopping
        if decisive, releasable {
            do { try await boundary.dispose(operationID: operationID) } catch { releasable = false }
        }
        let canRelease = releasable
        try command("payment.observe", enabled: false) { state in
            let index = try Self.index(operationID, state)
            guard state.authorization.generation == captured.generation,
                  state.payments[index].observationSequence == captured.payment.observationSequence,
                  state.payments[index].evidenceRevision == captured.payment.evidenceRevision else {
                state.payments[index].evidence.append(EvidenceRecord(id: UUID().uuidString,
                    source: observation.source, chainTip: observation.chainTip, observedAt: observation.observedAt,
                    contents: try paymentEncoding(observation), valid: false, observation: observation,
                    revision: captured.payment.evidenceRevision, sequence: captured.payment.observationSequence))
                return
            }
            try Self.apply(observation, operationID: operationID, canRelease: canRelease, state: &state)
        }
    }

    // Called by the owning evidence adapter for an actual evidence defect, never for
    // ordinary propagation delay or a temporary unavailable network/key.
    func requireEvidenceRepair(operationID: String, reason: String) throws {
        try requireRunning()
        guard !reason.isEmpty, reason.utf8.count <= 512 else { throw PaymentFailure.invalidRequest }
        try command("payment.damage", enabled: false) { state in
            let index = try Self.index(operationID, state)
            guard state.payments[index].liabilityUnresolved,
                  state.payments[index].disposition.isPossiblyRelayed else { throw PaymentFailure.invalidTransition }
            state.payments[index].disposition = .recoveryRequired
            state.payments[index].blocker = "evidenceDefect:\(reason)"
        }
    }

    func authorizeRelay(_ command: OwnerRelayCommand, owner: OwnerAuthenticationEvidence) async throws -> PaymentSnapshot {
        try beginCall()
        defer { finishCall() }
        guard validPaymentKey(command.key) else { throw PaymentFailure.invalidRequest }
        if let retained = try retainedOwnerCommand(command, owner: owner) { return retained }
        do {
            _ = try await startRelay(command.operationID, ownerCommand: command, owner: owner)
            return try retainedOwnerCommand(command, owner: owner) ?? ownerSnapshot(operationID: command.operationID, owner: owner)
        } catch {
            if let failure = error as? PaymentFailure, [.staleContext, .invalidTransition, .relayNotEligible].contains(failure) {
                let now = clock.read().wall
                try? self.command("payment.ownerDenied", enabled: false) { state in
                    try Self.authority(state, policy: authorityPolicy).requireOwner(owner: owner, now: now)
                    let binding = try paymentEncoding(command)
                    guard !state.requests.contains(where: { $0.principalID == "owner" && $0.method == "authorize_payment_relay" && $0.key == command.key }),
                          state.payments.contains(where: { $0.id == command.operationID }) else { return }
                    state.requests.append(RequestRecord(id: UUID().uuidString, principalID: "owner", paymentID: command.operationID,
                        method: "authorize_payment_relay", key: command.key, binding: binding, disposition: .closed,
                        result: Data(String(describing: error).utf8), consumedAttemptID: nil, tombstone: true,
                        ownerGeneration: state.authorization.generation))
                }
            }
            throw error
        }
    }

    private func retainedOwnerCommand(_ command: OwnerRelayCommand, owner: OwnerAuthenticationEvidence) throws -> PaymentSnapshot? {
        let now = clock.read().wall
        return try continuity.inspect { state in
            try Self.authority(state, policy: authorityPolicy).requireOwner(owner: owner, now: now)
            guard let row = state.requests.first(where: { $0.principalID == "owner" && $0.method == "authorize_payment_relay" && $0.key == command.key }) else { return nil }
            guard row.binding == (try paymentEncoding(command)) else { throw PaymentFailure.conflictingRequest }
            var snapshot = Self.snapshot(state.payments[try Self.index(command.operationID, state)], state: state)
            snapshot.ownerReceipt = row
            return snapshot
        }
    }

    func cancelLocalTransport() async {
        guard !stopping else { return }
        activeCalls += 1
        defer { finishCall() }
        guard let invocation = activeInvocation, let attemptID = activeAttemptID else { return }
        await invocation.cancel()
        if activeAttemptID == attemptID {
            try? recordTransport(.unknown(source: "cancelledLocalInvocation"), operationID: nil,
                                 attemptID: attemptID, evidenceRevision: nil)
            activeAttemptID = nil
            activeInvocation = nil
        }
    }

    private func schedulePreparation(_ id: String) {
        guard !stopping, preparing.insert(id).inserted else { return }
        track { await self.completePreparation(id) }
    }

    private func completePreparation(_ id: String) async {
        defer { preparing.remove(id) }
        guard !stopping else { return }
        do {
            let payment = try continuity.inspect { state in state.payments[try Self.index(id, state)] }
            guard payment.disposition == .preparing, let request = payment.request else { return }
            try await revalidateClosures(accountID: payment.accountID, excluding: id)
            guard !stopping else { return }
            try continuity.inspect { state in
                let current = state.payments[try Self.index(id, state)]
                guard current.disposition == .preparing else { throw PaymentFailure.invalidTransition }
                try Self.selectionGate(current, state: state)
            }
            let preview = try await boundary.prepare(PaymentPreparationInput(operationID: id,
                accountID: request.accountID, network: request.network, destinationScript: request.destinationScript,
                amount: request.amount, feeRate: request.feeRate, expiresAt: request.expiresAt))
            let now = clock.read().wall
            try command("payment.prepared") { state in
                let index = try Self.index(id, state)
                guard state.payments[index].disposition == .preparing else { throw PaymentFailure.invalidTransition }
                try Self.selectionGate(state.payments[index], state: state)
                try Self.originAuthority(state.payments[index], state: state, policy: authorityPolicy, now: now, capability: "prepare")
                if request.expiresAt.map({ now >= $0 }) == true {
                    Self.closeUnsubmitted(id, reason: "expired", state: &state)
                    return
                }
                guard preview.operationID == id, preview.accountID == request.accountID, preview.network == request.network,
                      preview.destinationScript == request.destinationScript, preview.amount == request.amount,
                      preview.fee >= 0, !preview.selectedInputs.isEmpty,
                      Set(preview.selectedInputs).count == preview.selectedInputs.count,
                      !preview.templateDigest.isEmpty, preview.leaseDeadline > now else { throw PaymentFailure.invalidRequest }
                state.payments[index].preview = preview
                state.payments[index].selectedInputs = preview.selectedInputs
                state.payments[index].change = preview.change
                state.payments[index].disposition = .prepared
                state.payments[index].blocker = nil
            }
        } catch {
            guard !stopping else { return }
            let transient = error as? PaymentFailure == .networkUnavailable || error as? PaymentFailure == .keyUnavailable
            try? command("payment.failure") { state in
                let index = try Self.index(id, state)
                if state.payments[index].disposition == .preparing {
                    if transient { state.payments[index].blocker = String(describing: error) }
                    else { Self.closeUnsubmitted(id, reason: "failedUnsubmitted", state: &state) }
                }
            }
            let terminal = (try? continuity.inspect { state in
                let current = state.payments[try Self.index(id, state)]
                return !current.disposition.isUnsubmitted && !current.liabilityUnresolved
            }) ?? false
            if !transient || terminal { await disposeAndRelease(id) }
        }
    }

    private func scheduleRelay(_ id: String, reconciledSequence: UInt64? = nil) {
        guard !stopping, starting.insert(id).inserted else { return }
        track { await self.completeRelay(id, reconciledSequence: reconciledSequence) }
    }

    private func completeRelay(_ id: String, reconciledSequence: UInt64?) async {
        defer { starting.remove(id) }
        do { _ = try await startRelay(id, reconciledSequence: reconciledSequence) }
        catch { recordBlocker(id, error: error) }
    }

    private func startRelay(_ id: String, ownerCommand: OwnerRelayCommand? = nil,
                            owner: OwnerAuthenticationEvidence? = nil,
                            reconciledSequence: UInt64? = nil) async throws -> PaymentSnapshot {
        try requireRunning()
        var payment = try continuity.inspect { state in
            let current = state.payments[try Self.index(id, state)]
            try Self.relayGuards(current, state: state, policy: authorityPolicy, now: clock.read().wall,
                                 ownerCommand: ownerCommand, owner: owner)
            return current
        }
        try await revalidateClosures(accountID: payment.accountID, excluding: id)
        if !payment.attempts.isEmpty && payment.observationSequence != reconciledSequence {
            try await completeReconciliation(operationID: id)
            payment = try continuity.inspect { state in state.payments[try Self.index(id, state)] }
        }
        try requireRunning()
        guard !payment.evidenceSupported else { throw PaymentFailure.relayNotEligible }
        if !payment.attempts.isEmpty {
            guard payment.lastReconciliationAt != nil,
                  !["networkUnavailable", "staleEvidence"].contains(payment.blocker ?? "") else {
                throw PaymentFailure.networkUnavailable
            }
        }
        let signed: SignedPayment
        if payment.canonicalBytes.isEmpty {
            guard let preview = payment.preview else { throw PaymentFailure.invalidTransition }
            signed = try await boundary.sign(preview)
            guard signed.operationID == id, !signed.bytes.isEmpty, signed.digest == paymentDigest(signed.bytes) else {
                throw PaymentFailure.invalidRequest
            }
        } else {
            signed = SignedPayment(operationID: id, bytes: payment.canonicalBytes,
                                   digest: payment.transactionDigest, transactionID: payment.transactionID)
        }
        try requireRunning()
        do { try await boundary.preflight(signed) }
        catch {
            if error as? PaymentFailure == .staleContext { await invalidateStaleAdmission(id) }
            throw error
        }
        try requireRunning()
        if let ownerCommand, let owner, let retained = try retainedOwnerCommand(ownerCommand, owner: owner) { return retained }
        guard activeAttemptID == nil else { throw PaymentFailure.transportBusy }
        let attemptID = UUID().uuidString
        activeAttemptID = attemptID
        let reading = clock.read()
        let runtime = runtimeID
        let started = startedMonotonic
        let policy = authorityPolicy
        let currentClock = clock
        let coordinator = continuity
        let execution = boundary
        let witness = HandoffWitness()
        let admissionRevision: UInt64
        var didAdmit = false
        do {
            admissionRevision = try command(ownerCommand == nil ? "payment.admit" : "payment.ownerAdmit") { state in
                let index = try Self.index(id, state)
                let current = state.payments[index]
                try execution.validateAdmission(signed)
                try Self.relayGuards(current, state: state, policy: policy, now: reading.wall,
                                     ownerCommand: ownerCommand, owner: owner)
                if ownerCommand == nil {
                    try Self.ordinaryEligibility(current, reading: reading, runtimeID: runtime, started: started)
                } else if let ownerCommand {
                    let binding = try paymentEncoding(ownerCommand)
                    if let old = state.requests.first(where: { $0.principalID == "owner" && $0.method == "authorize_payment_relay" && $0.key == ownerCommand.key }) {
                        guard old.binding == binding else { throw PaymentFailure.conflictingRequest }
                        throw PaymentFailure.relayNotEligible
                    }
                    state.requests.append(RequestRecord(id: UUID().uuidString, principalID: "owner", paymentID: id,
                        method: "authorize_payment_relay", key: ownerCommand.key, binding: binding,
                        disposition: .consumed, result: Data(), consumedAttemptID: attemptID, tombstone: true,
                        ownerGeneration: state.authorization.generation))
                    state.approvals.append(ApprovalRecord(id: UUID().uuidString, paymentID: id,
                        generation: state.authorization.generation, context: binding, active: true,
                        policyRevision: state.paymentPolicy.revision, ownerRelay: true))
                }
                guard current.canonicalBytes.isEmpty || (current.canonicalBytes == signed.bytes && current.transactionDigest == signed.digest) else {
                    throw PaymentFailure.invalidRequest
                }
                state.payments[index].canonicalBytes = signed.bytes
                state.payments[index].transactionDigest = signed.digest
                state.payments[index].transactionID = signed.transactionID
                state.payments[index].disposition = .submitting
                state.payments[index].liabilityUnresolved = true
                state.payments[index].blocker = nil
                let ordinary = ownerCommand == nil
                if ordinary { state.payments[index].ordinaryAdmissions += 1 }
                let used = state.payments[index].ordinaryAdmissions
                let delay: Int64? = ordinary && used < 3 ? (used == 1 ? 30 : 120) : nil
                state.payments[index].attempts.append(AttemptRecord(id: attemptID,
                    number: UInt64(current.attempts.count) + 1, commandID: ownerCommand?.key,
                    outcome: "admitted", route: ordinary ? "ordinary" : "owner", admittedAt: reading.wall,
                    monotonicAt: reading.monotonic, runtimeID: runtime,
                    nextEligibleAt: delay.flatMap { reading.wall.addingReportingOverflow($0).overflow ? nil : reading.wall + $0 }))
                for requestIndex in state.requests.indices where state.requests[requestIndex].paymentID == id &&
                    state.requests[requestIndex].method == "prepare_payment" {
                    state.requests[requestIndex].disposition = .consumed
                }
                Self.hold(id, accountID: current.accountID, state: &state)
                return current.evidenceRevision
            }
            didAdmit = true
            let invocation = try await boundary.handoff(signed) { actual in
                try coordinator.paymentTransaction(classification: "payment.handoff", mutation: { state -> Result<Void, any Error> in
                    let finalNow = currentClock.read().wall
                    if state.mode == .enabled {
                        var authority = Self.authority(state, policy: policy)
                        for grantID in authority.observeExpirations(now: finalNow) { state.invalidateUnsubmitted(grantID: grantID) }
                        state.authorization = authority.ledger
                    }
                    return Result {
                        try execution.validateAdmission(signed)
                        let current = state.payments[try Self.index(id, state)]
                        guard current.attempts.contains(where: { $0.id == attemptID }), current.disposition == .submitting,
                              current.evidenceRevision == admissionRevision else { throw PaymentFailure.staleContext }
                        try Self.relayGuards(current, state: state, policy: policy, now: finalNow,
                                             ownerCommand: ownerCommand, owner: owner, admitted: true)
                    }
                }, projection: { _, outcome in
                    try outcome.get()
                    witness.mark()
                    return try actual()
                })
            }
            activeInvocation = invocation
            // Always retain a handed-off invocation, even when shutdown began while its
            // middleware was suspended. Its result may be the only factual relay evidence.
            track {
                let result = await invocation.result()
                await self.finishTransport(result, operationID: id, attemptID: attemptID, evidenceRevision: admissionRevision)
            }
            return try continuity.inspect { state in Self.snapshot(state.payments[try Self.index(id, state)], state: state) }
        } catch {
            if !didAdmit {
                activeAttemptID = nil
                activeInvocation = nil
                if error as? PaymentFailure == .staleContext { await invalidateStaleAdmission(id) }
                throw error
            }
            // A live synchronous middleware refusal before its actual closure is affirmative
            // no-handoff evidence only for the first ever admission. A crash cannot supply it.
            if !witness.wasEntered || error as? PaymentFailure == .noHandoff {
                try? command("payment.noHandoff", enabled: false) { state in
                    let index = try Self.index(id, state)
                    if state.payments[index].disposition == .submitting && state.payments[index].attempts.count == 1 &&
                        state.payments[index].attempts.first?.id == attemptID && state.payments[index].attempts.first?.runtimeID == runtime {
                        state.payments[index].disposition = .closed
                        state.payments[index].terminalReason = "failedUnsubmitted"
                        state.payments[index].liabilityUnresolved = false
                        let proofID = UUID().uuidString
                        state.payments[index].evidence.append(EvidenceRecord(id: proofID,
                            source: "liveFirstAdmissionRefusal", chainTip: "local", observedAt: clock.read().wall,
                            contents: try paymentEncoding([attemptID, String(describing: error), "noHandoffOrQueuedRelay"]),
                            valid: true, revision: state.payments[index].evidenceRevision))
                        state.payments[index].closures.append(ClosureRecord(id: UUID().uuidString,
                            reason: "failedUnsubmitted", evidenceIDs: [proofID]))
                    } else if state.payments[index].disposition == .submitting {
                        state.payments[index].disposition = .uncertain
                    }
                }
                await disposeAndRelease(id)
            } else {
                try? recordTransport(.unknown(source: String(describing: error)), operationID: id,
                                     attemptID: attemptID, evidenceRevision: nil)
            }
            activeAttemptID = nil
            activeInvocation = nil
            throw error
        }
    }

    private func finishTransport(_ result: PaymentTransportResult, operationID: String,
                                 attemptID: String, evidenceRevision: UInt64) {
        try? recordTransport(result, operationID: operationID, attemptID: attemptID, evidenceRevision: evidenceRevision)
        if activeAttemptID == attemptID { activeAttemptID = nil; activeInvocation = nil }
    }

    private func recordTransport(_ result: PaymentTransportResult, operationID: String?, attemptID: String,
                                 evidenceRevision: UInt64?) throws {
        let now = clock.read().wall
        try command("payment.result", enabled: false) { state in
            guard let index = state.payments.firstIndex(where: { payment in
                (operationID == nil || payment.id == operationID) && payment.attempts.contains { $0.id == attemptID }
            }) else { throw PaymentFailure.unavailable }
            let current = state.payments[index]
            let isCurrent = evidenceRevision.map { $0 == current.evidenceRevision } ?? true
            let source: String
            switch result {
            case .accepted(let value): source = value
            case .rejected(let value): source = value
            case .unknown(let value): source = value
            }
            state.payments[index].evidence.append(EvidenceRecord(id: UUID().uuidString, source: source,
                chainTip: "relay", observedAt: now, contents: try paymentEncoding([attemptID, String(describing: result)]),
                valid: isCurrent, revision: current.evidenceRevision))
            guard isCurrent, current.disposition != .closed else { return }
            if case .accepted = result {
                state.payments[index].disposition = .accepted
                state.payments[index].evidenceSupported = true
            } else {
                state.payments[index].disposition = .uncertain
                if current.ordinaryAdmissions >= 3 { state.payments[index].blocker = "automaticRelayBudgetExhausted" }
            }
        }
    }

    private func revalidateClosures(accountID: String, excluding: String) async throws {
        let ids = try continuity.inspect { state in
            state.payments.filter { $0.id != excluding && $0.accountID == accountID && $0.disposition == .closed &&
                $0.evidenceSupported && $0.closures.contains { ["reconciledAccepted", "reconciledConflict"].contains($0.reason) } }.map(\.id)
        }
        for id in ids {
            try await completeReconciliation(operationID: id)
            let supported = try continuity.inspect { state in
                let current = state.payments[try Self.index(id, state)]
                return current.evidenceSupported && !current.liabilityUnresolved &&
                    !state.gates.contains { $0.accountID == accountID && $0.restrictions.contains("staleReadiness:\(id)") }
            }
            guard supported else { throw PaymentFailure.networkUnavailable }
        }
    }

    private func invalidateStaleAdmission(_ id: String) async {
        try? command("payment.failure", enabled: false) { state in
            if state.payments[try Self.index(id, state)].disposition.isUnsubmitted {
                Self.closeUnsubmitted(id, reason: "invalidated", state: &state)
            }
        }
        let payment = try? continuity.inspect { state in state.payments[try Self.index(id, state)] }
        if let payment {
            try? await revalidateClosures(accountID: payment.accountID, excluding: id)
            if !payment.attempts.isEmpty { try? await completeReconciliation(operationID: id) }
            else { await disposeAndRelease(id) }
        }
    }

    private func recordBlocker(_ id: String, error: any Error) {
        try? command("payment.blocker", enabled: false) { state in
            state.payments[try Self.index(id, state)].blocker = String(describing: error)
        }
    }

    private func disposeAndRelease(_ id: String) async {
        guard !stopping else { return }
        do {
            try await boundary.dispose(operationID: id)
            try command("payment.cleanup", enabled: false) { state in
                let payment = state.payments[try Self.index(id, state)]
                guard !payment.liabilityUnresolved, !payment.disposition.isUnsubmitted else { return }
                Self.release(id, state: &state)
            }
        } catch { recordBlocker(id, error: error) }
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

    private func track(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        background[id] = Task {
            await operation()
            self.background.removeValue(forKey: id)
        }
    }

    // Completion writes remain available while shutdown drains previously admitted work.
    private func command<Result>(_ classification: String, enabled: Bool = true,
                                 _ body: (inout CanonicalState) throws -> Result) throws -> Result {
        let now = clock.read().wall
        return try continuity.paymentTransaction(classification: classification, mutation: { state -> Swift.Result<Result, any Error> in
            if enabled { try Self.requireEnabled(state) }
            if state.mode == .enabled {
                var authority = Self.authority(state, policy: authorityPolicy)
                for grantID in authority.observeExpirations(now: now) { state.invalidateUnsubmitted(grantID: grantID) }
                state.authorization = authority.ledger
            }
            return Swift.Result { try body(&state) }
        }, projection: { _, outcome in try outcome.get() })
    }

    private static func authority(_ state: CanonicalState, policy: AuthorityPolicy) -> AuthorizationAuthority {
        AuthorizationAuthority(ledger: state.authorization, expectedBridgeIdentity: policy.bridge,
            trustedOwnerIdentity: policy.owner, maximumOwnerAuthenticationAge: policy.ownerAuthenticationAge, expectedAppleIntegrationIdentity: policy.appleIntegration)
    }
    private static func requireEnabled(_ state: CanonicalState) throws {
        guard state.mode == .enabled, state.history == .complete, state.custody != nil,
              state.hasCompleteGateCoverage() else { throw PaymentFailure.recoveryRequired }
    }
    private static func authorize(_ access: PaymentAccess, accountID: String, network: String,
                                  capability: String, state: CanonicalState, policy: AuthorityPolicy, now: Int64) throws {
        try requireEnabled(state)
        try authority(state, policy: policy).authorize(session: access.session, connectionID: access.connectionID,
            peer: access.peer, operation: AuthorizationOperation(walletID: state.authorization.walletID,
                network: network, accountID: accountID, capability: capability), now: now)
    }
    private static func visible(_ id: String, access: PaymentAccess, state: CanonicalState,
                                policy: AuthorityPolicy, capability: String, now: Int64) throws -> PaymentRecord {
        let payment = state.payments[try index(id, state)]
        guard payment.originGrantID == access.session.principal.grantID,
              state.requests.contains(where: { $0.paymentID == id && $0.method == "prepare_payment" &&
                $0.principalID == access.session.principal.integrationID }) else { throw PaymentFailure.unavailable }
        try authorize(access, accountID: payment.accountID, network: payment.network, capability: capability,
                      state: state, policy: policy, now: now)
        return payment
    }
    private static func originAuthority(_ payment: PaymentRecord, state: CanonicalState,
                                        policy: AuthorityPolicy, now: Int64, requireOriginalPolicy: Bool = true, capability: String = "submit") throws {
        try requireEnabled(state)
        guard let id = payment.originGrantID, let grant = state.authorization.grants.first(where: { $0.id == id }),
              !grant.revoked, !grant.expiredObserved, grant.expiresAt.map({ now < $0 }) ?? true,
              grant.credentialGeneration == payment.originCredentialGeneration,
              state.authorization.generation == payment.walletGeneration,
              grant.accountIDs.contains(payment.accountID), grant.capabilities.contains(capability),
              !requireOriginalPolicy || state.paymentPolicy.revision == payment.policyRevision else {
            throw PaymentFailure.staleContext
        }
    }
    private static func selectionGate(_ payment: PaymentRecord, state: CanonicalState) throws {
        guard state.gates.contains(where: { $0.accountID == payment.accountID && $0.liabilityIDs.contains(payment.id) }),
              state.gates.filter({ $0.accountID == payment.accountID }).allSatisfy({
                  $0.restrictions.isEmpty && $0.liabilityIDs.allSatisfy { $0 == payment.id }
              }) else { throw PaymentFailure.accountRestricted }
    }

    private static func livePreview(_ payment: PaymentRecord, now: Int64) throws {
        guard let preview = payment.preview, preview.leaseDeadline > now,
              payment.request?.expiresAt.map({ now < $0 }) ?? true else { throw PaymentFailure.leaseExpired }
    }
    private static func relayGuards(_ payment: PaymentRecord, state: CanonicalState, policy: AuthorityPolicy,
                                    now: Int64, ownerCommand: OwnerRelayCommand?, owner: OwnerAuthenticationEvidence?,
                                    admitted: Bool = false) throws {
        try requireEnabled(state)
        guard !payment.evidenceSupported,
              payment.canonicalBytes.isEmpty || payment.transactionDigest == paymentDigest(payment.canonicalBytes) else {
            throw PaymentFailure.relayNotEligible
        }
        if let command = ownerCommand, let owner {
            try authority(state, policy: policy).requireOwner(owner: owner, now: now)
            guard command.operationID == payment.id, command.accountID == payment.accountID,
                  command.network == payment.network, command.transactionDigest == payment.transactionDigest,
                  command.generation == state.authorization.generation, command.policyRevision == state.paymentPolicy.revision,
                  command.evidenceRevision == payment.evidenceRevision,
                  command.liabilityContextDigest == accountLiabilityContextDigest(accountID: payment.accountID, state: state),
                  !payment.canonicalBytes.isEmpty, payment.liabilityUnresolved,
                  [.uncertain, .possiblyRelayed, .closed, .submitting, .recoveryRequired].contains(payment.disposition),
                  payment.disposition != .closed || payment.closures.contains(where: { ["reconciledAccepted", "reconciledConflict"].contains($0.reason) }) else {
                throw PaymentFailure.staleContext
            }
        } else {
            guard admitted || [.ready, .uncertain, .possiblyRelayed].contains(payment.disposition),
                  payment.closures.isEmpty else { throw PaymentFailure.relayNotEligible }
            try originAuthority(payment, state: state, policy: policy, now: now)
            if payment.attempts.isEmpty || (admitted && payment.attempts.count == 1) { try livePreview(payment, now: now) }
            guard state.gates.filter({ $0.accountID == payment.accountID }).allSatisfy({
                $0.restrictions.isEmpty && $0.liabilityIDs.allSatisfy { $0 == payment.id }
            }) else { throw PaymentFailure.accountRestricted }
            if state.paymentPolicy.approvalRequired {
                guard let preview = payment.preview,
                      state.approvals.contains(where: { $0.paymentID == payment.id && $0.active && !$0.ownerRelay &&
                        $0.generation == state.authorization.generation && $0.policyRevision == state.paymentPolicy.revision &&
                        $0.context == (try? paymentEncoding(preview)) }) else { throw PaymentFailure.approvalNeeded }
            }
        }
    }
    private static func ordinaryEligibility(_ payment: PaymentRecord, reading: PaymentClockReading,
                                            runtimeID: String, started: UInt64) throws {
        guard payment.ordinaryAdmissions < 3 else { throw PaymentFailure.relayNotEligible }
        guard let last = payment.attempts.max(by: { $0.number < $1.number }) else { return }
        let delay: UInt64 = payment.ordinaryAdmissions <= 1 ? 30 : 120
        let base = last.runtimeID == runtimeID ? last.monotonicAt : started
        guard reading.monotonic >= base, reading.monotonic - base >= delay,
              last.nextEligibleAt.map({ reading.wall >= $0 }) ?? true else { throw PaymentFailure.relayNotEligible }
    }
    private static func accepts(_ observation: PaymentObservation, payment: PaymentRecord) -> Bool {
        observation.complete && observation.fresh && !payment.selectedInputs.isEmpty &&
        observation.exactTransactionBytes == payment.canonicalBytes && !payment.canonicalBytes.isEmpty &&
        Set(payment.selectedInputs).isSubset(of: Set(observation.spentConsistently)) &&
        Set(payment.selectedInputs).isSubset(of: Set(observation.accountedInputs)) && observation.changeTracked
    }
    private static func conflicts(_ observation: PaymentObservation, payment: PaymentRecord) -> Bool {
        observation.complete && observation.fresh && observation.canonicalConflict &&
        !Set(payment.selectedInputs).intersection(observation.confirmedConflictInputs).isEmpty &&
        Set(payment.selectedInputs).isSubset(of: Set(observation.accountedInputs)) && observation.changeTracked
    }
    private static func apply(_ observation: PaymentObservation, operationID: String,
                              canRelease: Bool, state: inout CanonicalState) throws {
        let index = try Self.index(operationID, state)
        let payment = state.payments[index]
        let positive = accepts(observation, payment: payment)
        let conflict = conflicts(observation, payment: payment)
        let priorView = payment.evidence.filter {
            $0.valid && $0.revision == payment.evidenceRevision && $0.observation?.complete == true && $0.observation?.fresh == true
        }.max(by: { $0.sequence < $1.sequence })?.observation
        let changedView = priorView.map { $0.source != observation.source || $0.view != observation.view } ?? false
        let invalidated = observation.complete && observation.fresh && !positive && !conflict &&
            (observation.supportRemoved || changedView) && (payment.evidenceSupported ||
                (!payment.liabilityUnresolved && payment.closures.contains { ["reconciledAccepted", "reconciledConflict"].contains($0.reason) }))
        if invalidated {
            guard payment.evidenceRevision < UInt64.max else { throw PaymentFailure.invalidTransition }
            state.payments[index].evidenceRevision += 1
            state.payments[index].evidenceSupported = false
            state.payments[index].liabilityUnresolved = true
            if state.payments[index].disposition != .closed { state.payments[index].disposition = .uncertain }
            Self.hold(operationID, accountID: payment.accountID, state: &state)
            for other in state.payments where other.accountID == payment.accountID && other.disposition.isUnsubmitted {
                closeUnsubmitted(other.id, reason: "invalidated", state: &state)
            }
        }
        let revision = state.payments[index].evidenceRevision
        let evidenceID = UUID().uuidString
        state.payments[index].evidence.append(EvidenceRecord(id: evidenceID, source: observation.source,
            chainTip: observation.chainTip, observedAt: observation.observedAt, contents: try paymentEncoding(observation),
            valid: observation.complete && observation.fresh, observation: observation, revision: revision,
            sequence: payment.observationSequence))
        if observation.complete && observation.fresh {
            state.payments[index].lastReconciliationAt = observation.observedAt
            if ["networkUnavailable", "staleEvidence", "inconclusiveEvidence"].contains(state.payments[index].blocker ?? "") {
                state.payments[index].blocker = nil
            }
        }
        if positive || conflict {
            state.payments[index].evidenceSupported = true
            if canRelease {
                let reason = positive ? "reconciledAccepted" : "reconciledConflict"
                state.payments[index].disposition = .closed
                state.payments[index].terminalReason = reason
                state.payments[index].liabilityUnresolved = false
                state.payments[index].blocker = nil
                if payment.disposition != .closed || payment.liabilityUnresolved || payment.terminalReason != reason {
                    state.payments[index].closures.append(ClosureRecord(id: UUID().uuidString, reason: reason,
                        evidenceIDs: [evidenceID], revision: revision))
                }
                release(operationID, clearReadiness: true, state: &state)
            } else { state.payments[index].blocker = "leaseCleanupFailed" }
        } else if !observation.complete || !observation.fresh || (payment.disposition == .closed && payment.evidenceSupported && !invalidated) {
            state.payments[index].blocker = !observation.fresh ? "staleEvidence" : (!observation.complete ? "networkUnavailable" : "inconclusiveEvidence")
            if payment.evidenceSupported || !payment.closures.isEmpty {
                let restriction = "staleReadiness:\(operationID)"
                if let gate = state.gates.firstIndex(where: { $0.accountID == payment.accountID }) {
                    if !state.gates[gate].restrictions.contains(restriction) { state.gates[gate].restrictions.append(restriction) }
                } else { state.gates.append(SpendingGate(accountID: payment.accountID, liabilityIDs: [], restrictions: [restriction])) }
            }
        }
    }
    private static func index(_ id: String, _ state: CanonicalState) throws -> Int {
        guard let index = state.payments.firstIndex(where: { $0.id == id }) else { throw PaymentFailure.unavailable }
        return index
    }
    private static func isHeld(_ accountID: String, state: CanonicalState) -> Bool {
        state.gates.contains { $0.accountID == accountID && (!$0.liabilityIDs.isEmpty || !$0.restrictions.isEmpty) }
    }
    private static func hold(_ id: String, accountID: String, state: inout CanonicalState) {
        if let index = state.gates.firstIndex(where: { $0.accountID == accountID }) {
            if !state.gates[index].liabilityIDs.contains(id) { state.gates[index].liabilityIDs.append(id) }
        } else { state.gates.append(SpendingGate(accountID: accountID, liabilityIDs: [id], restrictions: [])) }
    }
    private static func release(_ id: String, clearReadiness: Bool = false, state: inout CanonicalState) {
        for index in state.gates.indices {
            state.gates[index].liabilityIDs.removeAll { $0 == id }
            if clearReadiness { state.gates[index].restrictions.removeAll { $0 == "staleReadiness:\(id)" } }
        }
        state.gates.removeAll { $0.liabilityIDs.isEmpty && $0.restrictions.isEmpty }
    }
    private static func closeUnsubmitted(_ id: String, reason: String, state: inout CanonicalState) {
        guard let index = state.payments.firstIndex(where: { $0.id == id }), state.payments[index].disposition.isUnsubmitted else { return }
        state.payments[index].disposition = .closed
        state.payments[index].terminalReason = reason
        state.payments[index].closures.append(ClosureRecord(id: UUID().uuidString, reason: reason, evidenceIDs: []))
        for requestIndex in state.requests.indices where state.requests[requestIndex].paymentID == id {
            state.requests[requestIndex].disposition = .closed
            state.requests[requestIndex].tombstone = true
        }
        for approvalIndex in state.approvals.indices where state.approvals[approvalIndex].paymentID == id {
            state.approvals[approvalIndex].active = false
        }
    }
    private static func snapshot(_ payment: PaymentRecord, state: CanonicalState) -> PaymentSnapshot {
        PaymentSnapshot(payment: payment, accountRestricted: isHeld(payment.accountID, state: state), blocker: payment.blocker,
            liabilityContextDigest: accountLiabilityContextDigest(accountID: payment.accountID, state: state),
            walletID: state.authorization.walletID, currentWalletGeneration: state.authorization.generation,
            currentPolicyRevision: state.paymentPolicy.revision,
            previewContextDigest: paymentPreviewContextDigest(payment, state: state))
    }
}
