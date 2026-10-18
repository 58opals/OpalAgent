import CryptoKit
import Foundation
import OpalBaseCore

/// Provenance for a coherent public-chain view. The provider owns completeness and
/// canonical-chain selection; this adapter does not implement an SPV/header-chain client.
struct BaseChainContext: Sendable, Equatable {
    var network: String
    var source: String
    var view: String
    var tip: String
    var tipHeight: UInt64
    var observedAt: Int64
    var complete: Bool
    var fresh: Bool
}

/// A header already selected by the provider's validated canonical view. The adapter
/// independently verifies transaction inclusion and binds the proof to that exact view.
struct BaseCanonicalTransactionProof: Sendable {
    var context: BaseChainContext
    var height: UInt32
    var header: OpalBase.Block.Header
    var inclusion: OpalBase.Transaction.MerkleProof
}

private struct BaseInputPayload: Codable, Equatable, Sendable {
    var value: UInt64
    var script: Data
    var hash: Data
    var index: UInt32
    init(_ input: OpalBase.Transaction.Output.Unspent) {
        value = input.value; script = input.lockingScript
        hash = input.previousTransactionHash.naturalOrder; index = input.previousTransactionOutputIndex
    }
    var input: OpalBase.Transaction.Output.Unspent {
        .init(value: value, lockingScript: script, previousTransactionHash: .init(naturalOrder: hash), previousTransactionOutputIndex: index)
    }
}
private struct BaseChangePayload: Codable, Equatable, Sendable {
    var index: UInt32
    var amount: UInt64
    var script: Data
    init(_ change: OpalBase.Account.SpendPlan.TransactionResult.Change) {
        index = change.derivedAddress.derivationPath.index; amount = change.amount.uint64
        script = OpalBase.Transaction.Output(value: amount, address: change.derivedAddress.address).lockingScript
    }
    func change(network: OpalBase.Network.Environment) throws -> OpalBase.Account.SpendPlan.TransactionResult.Change {
        let address = try OpalBase.Address(script: .decode(lockingScript: script), network: network)
        let derived = OpalBase.Account.DerivedAddress(address: address,
            derivationPath: try .init(purpose: .bip44, coinType: .bitcoinCash, account: .init(rawIndexInteger: 0), usage: .change, index: index),
            createdAt: Date(timeIntervalSince1970: 0))
        return .init(derivedAddress: derived, amount: try .init(amount))
    }
}

/// The sole Base account owner behind the service's durable command pipeline.
/// No client receives this adapter, Base plans, descriptors, custody or raw signing authority.
actor BaseBCHAdapter: PaymentExecutionBoundary, AccountChainBoundary {
    private struct LivePlan {
        var plan: OpalBase.Account.SpendPlan
        var preview: PaymentPreview
        var context: BaseChainContext
        var finalized: OpalBase.FinalizedBCHTransaction?
        var handedOff = false
        var attempt: OpalBase.TransactionRelayAttempt?
        let lease = BaseLeaseDisposalState()
    }
    private let account: OpalBase.Account
    private let custody: WalletCustodyRecord
    private let vault: WalletSeedVault
    private let continuity: ContinuityCoordinator
    private let chain: OpalBase.WalletPublicChainOperations
    private let network: OpalBase.Network.Environment
    private let clock: any PaymentClock
    private let context: @Sendable () throws -> BaseChainContext
    private let canonicalProof: (@Sendable (OpalBase.Transaction.Hash, UInt32, BaseChainContext) async throws -> BaseCanonicalTransactionProof?)?
    private let relay: OpalBase.TransactionRelay
    private nonisolated let admissionGate: BaseAdmissionGate
    private var frontier: OpalBase.ConfirmedAddressFrontier?
    private var plans: [String: LivePlan] = [:]
    private var preparing: Set<String> = []
    private var handingOff: Set<String> = []
    private var refreshing = false
    private var localInvocations: [String: OpalBase.TransactionRelayAttempt] = [:]
    private var observedContexts: [String: BaseChainContext] = [:]
    private var admissionContexts: [String: BaseChainContext] = [:]

    init(account: OpalBase.Account, custody: WalletCustodyRecord, vault: WalletSeedVault,
         continuity: ContinuityCoordinator, chain: OpalBase.WalletPublicChainOperations,
         clock: any PaymentClock = SystemPaymentClock(),
         context: @escaping @Sendable () throws -> BaseChainContext,
         canonicalProof: (@Sendable (OpalBase.Transaction.Hash, UInt32, BaseChainContext) async throws -> BaseCanonicalTransactionProof?)? = nil,
         relay: OpalBase.TransactionRelay? = nil) async throws {
        let accountID = await account.id
        guard let network = OpalBase.Network.Environment(rawValue: custody.network),
              accountID.base64EncodedString() == custody.accountID else { throw PaymentFailure.invalidRequest }
        try custody.validate()
        self.account = account; self.custody = custody; self.vault = vault; self.continuity = continuity
        self.chain = chain; self.network = network; self.clock = clock; self.context = context
        self.canonicalProof = canonicalProof
        self.admissionGate = BaseAdmissionGate(provider: context, vault: vault, custody: custody, clock: clock)
        self.relay = relay ?? OpalBase.TransactionRelay(network: network, transactionClient: chain.transactionClient)
    }

    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        try requireIdentity(accountID, network)
        let pass = try await refreshPublicState()
        return pass.record
    }

    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        try requireIdentity(accountID, network)
        guard let frontier else { throw PaymentFailure.networkUnavailable }
        return try await account.boundedReceivingAddress(at: index, frontier: frontier).address.string
    }

    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview {
        try requireIdentity(request.accountID, request.network)
        try requireCustody()
        if let live = plans[request.operationID] { return live.preview }
        guard preparing.insert(request.operationID).inserted else { throw PaymentFailure.unavailable }
        defer { preparing.remove(request.operationID) }
        guard let amount = UInt64(exactly: request.amount), amount > 0,
              let feeRate = UInt64(exactly: request.feeRate), feeRate > 0 else { throw PaymentFailure.invalidRequest }
        let pass = try await refreshPublicState()
        guard let frontier else { throw PaymentFailure.networkUnavailable }
        try continuity.inspect { state in
            if let high = state.allocations.first(where: { $0.accountID == custody.accountID && $0.branch == "receiving" })?.issuedHighWater {
                guard high <= UInt64(frontier.receivingHighestIndex + Int64(OpalBase.ConfirmedAddressFrontier.gap)) else { throw PaymentFailure.accountRestricted }
            }
        }
        let destination = try OpalBase.Address(script: .decode(lockingScript: request.destinationScript), network: network)
        let payment = OpalBase.Account.Payment(recipients: [.init(address: destination, amount: try .init(amount))],
            feeOverride: .init(explicitFeeRate: feeRate))
        let plan = try await account.prepareBoundedSpend(payment, frontier: frontier)
        do {
            let review = try await plan.review(network: network)
            try requireCustody()
            let now = clock.read().wall
            let deadline = min(request.expiresAt ?? now + 300, now + 300)
            guard deadline > now else { throw PaymentFailure.leaseExpired }
            let preview = PaymentPreview(operationID: request.operationID, accountID: request.accountID, network: request.network,
                destinationScript: request.destinationScript, amount: request.amount, fee: Int64(review.fee.uint64),
                selectedInputs: review.inputs.map(Self.outpoint), change: try Self.changeData(review.change),
                templateDigest: review.templateDigest, leaseDeadline: deadline,
                inputPayloads: try paymentEncoding(review.inputs.map(BaseInputPayload.init)),
                unsignedTemplate: try review.envelope.unsignedTransaction.encode())
            plans[request.operationID] = LivePlan(plan: plan, preview: preview, context: pass.context)
            return preview
        } catch { try? await plan.cancelReservation(); throw error }
    }

    func sign(_ preview: PaymentPreview) async throws -> SignedPayment {
        try requireIdentity(preview.accountID, preview.network)
        try requireCustody()
        guard let live = plans[preview.operationID], live.preview == preview,
              clock.read().wall < preview.leaseDeadline else { throw PaymentFailure.leaseExpired }
        try continuity.inspect { state in
            guard let payment = state.payments.first(where: { $0.id == preview.operationID }),
                  payment.preview == preview, payment.disposition == .ready else { throw PaymentFailure.invalidTransition }
        }
        let finalized = try await live.plan.finalize(network: network)
        let template = try OpalBase.Transaction.decode(from: preview.unsignedTemplate)
        guard template.bytesRead == preview.unsignedTemplate.count,
              finalized.transaction.outputs == template.transaction.outputs,
              finalized.transaction.version == template.transaction.version,
              finalized.transaction.lockTime == template.transaction.lockTime,
              Int64(finalized.fee.uint64) == preview.fee,
              finalized.inputs.map(Self.outpoint) == preview.selectedInputs,
              try paymentEncoding(finalized.inputs.map(BaseInputPayload.init)) == preview.inputPayloads,
              try Self.changeData(finalized.change) == preview.change else { throw PaymentFailure.staleContext }
        try requireCustody()
        plans[preview.operationID]?.finalized = finalized
        return SignedPayment(operationID: preview.operationID, bytes: finalized.rawBytes,
            digest: paymentDigest(finalized.rawBytes), transactionID: Self.hex(finalized.hash.reverseOrder))
    }

    func preflight(_ payment: SignedPayment) async throws {
        try requireCustody()
        let current = try checkedContext()
        let expected = plans[payment.operationID].flatMap { $0.handedOff ? nil : $0.context } ?? observedContexts[payment.operationID]
        guard let expected, Self.sameView(expected, current) else { throw PaymentFailure.staleContext }
        let finalized = try retainedTransaction(payment)
        guard finalized.rawBytes == payment.bytes else { throw PaymentFailure.staleContext }
        if let live = plans[payment.operationID], !live.handedOff {
            try await live.plan.requireActiveReservation()
        } else {
            try continuity.inspect { state in
                guard let record = state.payments.first(where: { $0.id == payment.operationID }),
                      !record.canonicalBytes.isEmpty, record.canonicalBytes == payment.bytes,
                      !record.attempts.isEmpty else { throw PaymentFailure.leaseExpired }
            }
        }
        admissionContexts[payment.operationID] = current
        admissionGate.record(payment, context: current)
    }

    nonisolated func validateAdmission(_ payment: SignedPayment) throws { try admissionGate.validate(payment) }

    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        try requireCustody()
        guard handingOff.insert(payment.operationID).inserted else { throw PaymentFailure.transportBusy }
        defer { handingOff.remove(payment.operationID) }
        let finalized = try retainedTransaction(payment)
        let vault = self.vault; let custody = self.custody
        let current = try checkedContext()
        guard let admitted = admissionContexts[payment.operationID], Self.sameView(admitted, current) else { throw PaymentFailure.noHandoff }
        let source = current.source; let provider = context; let currentClock = clock
        if let live = plans[payment.operationID], !live.handedOff {
            let witness = BaseHandoffWitness()
            do {
                let attempt = try await live.plan.claimAndHandoff(finalized, using: relay) { claim in
                    var actual: OpalBase.TransactionRelayAttempt?
                    let result = try admission {
                        try Self.requireCurrentView(provider, expected: admitted, now: currentClock.read().wall)
                        try Self.requireVault(vault, custody: custody)
                        let attempt = try claim()
                        witness.mark(attempt); actual = attempt
                        return Self.invocation(attempt, source: source)
                    }
                    guard let actual else { throw PaymentFailure.noHandoff }
                    guard result.id == actual.id.uuidString else { throw PaymentFailure.staleContext }
                    return actual
                }
                plans[payment.operationID]?.handedOff = true
                plans[payment.operationID]?.attempt = attempt
                localInvocations[payment.operationID] = attempt
                return Self.invocation(attempt, source: source, lease: live.lease)
            } catch {
                if let invocation = witness.invocation {
                    plans[payment.operationID]?.handedOff = true
                    localInvocations[payment.operationID] = invocation
                }
                throw error
            }
        }
        var actual: OpalBase.TransactionRelayAttempt?
        defer { if let actual { localInvocations[payment.operationID] = actual } }
        let invocation = try admission {
            try Self.requireCurrentView(provider, expected: admitted, now: currentClock.read().wall)
            try Self.requireVault(vault, custody: custody)
            let attempt = try self.relay.begin(finalized)
            actual = attempt
            return Self.invocation(attempt, source: source)
        }
        guard let actual else { throw PaymentFailure.noHandoff }
        guard invocation.id == actual.id.uuidString else { throw PaymentFailure.staleContext }
        return invocation
    }

    func dispose(operationID: String) async throws {
        if let invocation = localInvocations[operationID] {
            await invocation.cancelAndWait()
            localInvocations.removeValue(forKey: operationID)
        }
        guard let live = plans[operationID] else { return }
        if live.handedOff {
            if let attempt = live.attempt {
                await attempt.cancelAndWait()
                do {
                    let outcome = try await attempt.value()
                    live.lease.complete(outcome.reservationCompletionError == nil ? .disposed : .failed)
                } catch { live.lease.complete(.unknown) }
            }
            switch live.lease.state {
            case .disposed: break
            case .unknown:
                do {
                    try await live.plan.completeClaimedReservationAfterReconciliation()
                    live.lease.complete(.disposed)
                } catch { live.lease.complete(.failed); throw PaymentFailure.networkUnavailable }
            case .pending, .failed: throw PaymentFailure.networkUnavailable
            }
        } else { try await live.plan.cancelReservation() }
        plans.removeValue(forKey: operationID)
    }

    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation {
        try requireIdentity(payment.accountID, payment.network)
        let pass = try await refreshPublicState()
        let view = pass.context
        var raw: [String: OpalBase.Transaction] = [:]
        var exact: Data?
        var confirmedConflicts = Set<String>()
        guard let reader = chain.transactionReader else { throw PaymentFailure.networkUnavailable }
        for record in pass.state.history {
            let bytes = try await reader.fetchRawTransaction(for: record.transactionHash)
            let parsed = try OpalBase.Transaction.decode(from: bytes)
            guard parsed.bytesRead == bytes.count, try parsed.transaction.encode() == bytes,
                  Self.transactionHash(bytes) == record.transactionHash.naturalOrder else { throw PaymentFailure.networkUnavailable }
            let identifier = Self.hex(record.transactionHash.reverseOrder)
            raw[identifier] = parsed.transaction
            if bytes == payment.canonicalBytes { exact = bytes }
            if bytes != payment.canonicalBytes, record.isConfirmed,
               let height = UInt32(exactly: record.chainMetadata.height),
               let canonicalProof, let proof = try await canonicalProof(record.transactionHash, height, view),
               Self.valid(proof, hash: record.transactionHash, height: height, context: view) {
                for input in parsed.transaction.inputs {
                    let outpoint = Self.outpoint(input)
                    if payment.selectedInputs.contains(outpoint) { confirmedConflicts.insert(outpoint) }
                }
            }
        }
        guard exact == nil || confirmedConflicts.isEmpty else { throw PaymentFailure.networkUnavailable }
        let end = try checkedContext()
        guard Self.sameView(view, end) else { throw PaymentFailure.networkUnavailable }
        let unspent = Set(try pass.state.addressBook.utxos.map { "\(try Self.rpcIdentifier($0.transactionHash)):\($0.outputIndex)" })
        let observedSpends = Set(raw.values.flatMap { $0.inputs.map(Self.outpoint) })
        let selected = Set(payment.selectedInputs)
        let accounted = selected.intersection(unspent.union(observedSpends))
        let consistent = exact == nil ? Set<String>() : selected.subtracting(unspent).intersection(observedSpends)
        let changeTracked: Bool
        if payment.change.isEmpty { changeTracked = true }
        else if let transaction = exact.flatMap({ _ in raw[payment.transactionID] }) {
            let change = try JSONDecoder().decode(BaseChangePayload.self, from: payment.change)
            let candidates = transaction.outputs.enumerated().filter { $0.element.lockingScript == change.script && $0.element.value == change.amount }
            changeTracked = !candidates.isEmpty && candidates.allSatisfy { candidate in
                let outpoint = "\(payment.transactionID):\(candidate.offset)"
                return unspent.contains(outpoint) || observedSpends.contains(outpoint)
            }
        } else { changeTracked = !confirmedConflicts.isEmpty }
        observedContexts[payment.id] = end
        return PaymentObservation(source: end.source, view: end.view, chainTip: end.tip, observedAt: end.observedAt,
            complete: end.complete, fresh: end.fresh, exactTransactionBytes: exact,
            spentConsistently: consistent.sorted(), accountedInputs: accounted.sorted(), changeTracked: changeTracked,
            confirmedConflictInputs: confirmedConflicts.sorted(), canonicalConflict: !confirmedConflicts.isEmpty,
            supportRemoved: payment.evidenceSupported && exact == nil)
    }

    private func refreshPublicState() async throws -> (record: AccountSyncRecord, state: OpalBase.Account.ChainStateSnapshot, context: BaseChainContext) {
        guard !refreshing else { throw PaymentFailure.networkUnavailable }
        refreshing = true; defer { refreshing = false }
        let start = try checkedContext()
        let sync = OpalBase.WalletBlockchainSyncInteractor(readOnlyAccount: account, publicChain: chain)
        _ = try await sync.refreshBalances()
        _ = try await sync.refreshTransactionHistory()
        _ = try await sync.refreshUTXOSet()
        _ = try await sync.refreshTransactionConfirmations()
        let refreshedFrontier = try await account.refreshConfirmedAddressFrontier(network: network, using: chain)
        let coherent = try await account.makeChainStateSnapshot()
        let end = try checkedContext()
        guard Self.sameView(start, end) else {
            await account.invalidateConfirmedAddressFrontier(); frontier = nil
            throw PaymentFailure.networkUnavailable
        }
        frontier = refreshedFrontier
        let path = await account.derivationPath
        let snapshot = OpalBase.Account.Snapshot(purpose: path.purpose, coinType: path.coinType,
            accountUnhardenedIndex: await account.unhardenedIndex, addressBook: coherent.addressBook)
        let record = AccountSyncRecord(accountID: custody.accountID, network: custody.network, providerID: end.source,
            viewID: end.view, chainTip: end.tip, observedAt: end.observedAt, complete: end.complete, fresh: end.fresh,
            balance: Int64(coherent.balance.uint64), snapshot: try paymentEncoding(snapshot),
            receivingHorizon: refreshedFrontier.receivingHighestIndex, changeHorizon: refreshedFrontier.changeHighestIndex)
        return (record, coherent, end)
    }

    private func retainedTransaction(_ payment: SignedPayment) throws -> OpalBase.FinalizedBCHTransaction {
        guard payment.digest == paymentDigest(payment.bytes), !payment.bytes.isEmpty else { throw PaymentFailure.recoveryRequired }
        if let finalized = plans[payment.operationID]?.finalized {
            guard finalized.rawBytes == payment.bytes else { throw PaymentFailure.staleContext }
            return finalized
        }
        return try continuity.inspect { state in
            guard let record = state.payments.first(where: { $0.id == payment.operationID }), let preview = record.preview,
                  record.canonicalBytes == payment.bytes, record.transactionDigest == payment.digest,
                  !preview.inputPayloads.isEmpty, !preview.unsignedTemplate.isEmpty else { throw PaymentFailure.recoveryRequired }
            let inputs = try JSONDecoder().decode([BaseInputPayload].self, from: preview.inputPayloads).map(\.input)
            let change = try preview.change.isEmpty ? nil : JSONDecoder().decode(BaseChangePayload.self, from: preview.change).change(network: network)
            let finalized = try OpalBase.FinalizedBCHTransaction(rawBytes: payment.bytes, network: network, inputs: inputs, change: change)
            let decoded = try OpalBase.Transaction.decode(from: preview.unsignedTemplate)
            guard decoded.bytesRead == preview.unsignedTemplate.count,
                  Self.transactionHash(preview.unsignedTemplate) == preview.templateDigest,
                  decoded.transaction.outputs == finalized.transaction.outputs,
                  decoded.transaction.version == finalized.transaction.version,
                  decoded.transaction.lockTime == finalized.transaction.lockTime,
                  decoded.transaction.inputs.map(Self.outpoint) == finalized.transaction.inputs.map(Self.outpoint),
                  decoded.transaction.inputs.map(\.sequence) == finalized.transaction.inputs.map(\.sequence),
                  Int64(finalized.fee.uint64) == preview.fee,
                  Self.hex(finalized.hash.reverseOrder) == payment.transactionID,
                  inputs.map(Self.outpoint) == preview.selectedInputs else { throw PaymentFailure.recoveryRequired }
            return finalized
        }
    }

    private func requireIdentity(_ accountID: String, _ network: String) throws {
        guard accountID == custody.accountID, network == custody.network else { throw PaymentFailure.invalidRequest }
    }
    private func requireCustody() throws {
        try continuity.inspect { state in
            guard state.mode == .enabled, state.history == .complete, state.custody == custody else { throw PaymentFailure.recoveryRequired }
            try Self.requireVault(vault, custody: custody)
        }
    }
    private func checkedContext() throws -> BaseChainContext {
        let result = try context()
        guard result.complete, result.fresh, !result.source.isEmpty, !result.view.isEmpty, !result.tip.isEmpty,
              result.network == custody.network, result.observedAt >= 0, result.observedAt <= clock.read().wall else { throw PaymentFailure.networkUnavailable }
        return result
    }
    private static func requireCurrentView(_ provider: @Sendable () throws -> BaseChainContext, expected: BaseChainContext, now: Int64) throws {
        let current = try provider()
        guard sameView(current, expected), current.complete, current.fresh, current.observedAt >= 0, current.observedAt <= now else { throw PaymentFailure.noHandoff }
    }
    fileprivate static func sameView(_ lhs: BaseChainContext, _ rhs: BaseChainContext) -> Bool {
        lhs.network == rhs.network && lhs.source == rhs.source && lhs.view == rhs.view && lhs.tip == rhs.tip && lhs.tipHeight == rhs.tipHeight
    }
    private static func valid(_ proof: BaseCanonicalTransactionProof, hash: OpalBase.Transaction.Hash,
                              height: UInt32, context: BaseChainContext) -> Bool {
        proof.context == context && proof.context.complete && proof.context.fresh && proof.height == height &&
        UInt64(height) <= context.tipHeight && proof.inclusion.blockHeight == height &&
        proof.header.previousBlockHash.count == 32 && proof.header.merkleRoot.count == 32 &&
        proof.inclusion.computeRoot(for: hash) == proof.header.merkleRoot &&
        (proof.inclusion.blockHash == nil || proof.inclusion.blockHash == headerHash(proof.header))
    }
    fileprivate static func requireVault(_ vault: WalletSeedVault, custody: WalletCustodyRecord) throws {
        do { try vault.requireAvailable(custody) }
        catch PayloadProtectionError.wrappingKeyMissing { throw PaymentFailure.keyUnavailable }
        catch PayloadProtectionError.wrappingKeyInaccessible { throw PaymentFailure.keyUnavailable }
        catch { throw PaymentFailure.recoveryRequired }
    }
    private static func headerHash(_ header: OpalBase.Block.Header) -> Data {
        var bytes = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
        }
        append(header.version); bytes.append(header.previousBlockHash); bytes.append(header.merkleRoot)
        append(header.time); append(header.bits); append(header.nonce)
        return transactionHash(bytes)
    }
    private static func invocation(_ attempt: OpalBase.TransactionRelayAttempt, source: String, lease: BaseLeaseDisposalState? = nil) -> PaymentTransportInvocation {
        PaymentTransportInvocation(id: attempt.id.uuidString, result: {
            do {
                let outcome = try await attempt.value()
                lease?.complete(outcome.reservationCompletionError == nil ? .disposed : .failed)
                return .accepted(source: source)
            } catch { lease?.complete(.unknown); return .unknown(source: source) }
        }, cancel: { await attempt.cancelAndWait() })
    }
    private static func changeData(_ change: OpalBase.Account.SpendPlan.TransactionResult.Change?) throws -> Data {
        try change.map { try paymentEncoding(BaseChangePayload($0)) } ?? Data()
    }
    private static func outpoint(_ input: OpalBase.Transaction.Output.Unspent) -> String {
        "\(hex(input.previousTransactionHash.reverseOrder)):\(input.previousTransactionOutputIndex)"
    }
    private static func outpoint(_ input: OpalBase.Transaction.Input) -> String {
        "\(hex(input.previousTransactionHash.reverseOrder)):\(input.previousTransactionOutputIndex)"
    }
    private static func rpcIdentifier(_ naturalHex: String) throws -> String {
        guard naturalHex.utf8.count == 64 else { throw PaymentFailure.networkUnavailable }
        var bytes = Data(); var offset = naturalHex.startIndex
        while offset < naturalHex.endIndex {
            let next = naturalHex.index(offset, offsetBy: 2)
            guard let value = UInt8(naturalHex[offset..<next], radix: 16) else { throw PaymentFailure.networkUnavailable }
            bytes.append(value); offset = next
        }
        return hex(Data(bytes.reversed()))
    }
    private static func transactionHash(_ bytes: Data) -> Data { Data(SHA256.hash(data: Data(SHA256.hash(data: bytes)))) }
    private static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

private final class BaseHandoffWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OpalBase.TransactionRelayAttempt?
    func mark(_ invocation: OpalBase.TransactionRelayAttempt) { lock.withLock { value = invocation } }
    var invocation: OpalBase.TransactionRelayAttempt? { lock.withLock { value } }
}

/// Synchronous provider state is a local snapshot, never a network operation. This gate is
/// callable while service serialization is held and never enters the continuity coordinator.
private final class BaseAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var expected: [String: (Data, BaseChainContext)] = [:]
    private let provider: @Sendable () throws -> BaseChainContext
    private let vault: WalletSeedVault
    private let custody: WalletCustodyRecord
    private let clock: any PaymentClock
    init(provider: @escaping @Sendable () throws -> BaseChainContext, vault: WalletSeedVault,
         custody: WalletCustodyRecord, clock: any PaymentClock) {
        self.provider = provider; self.vault = vault; self.custody = custody; self.clock = clock
    }
    func record(_ payment: SignedPayment, context: BaseChainContext) {
        lock.withLock { expected[payment.operationID] = (payment.digest, context) }
    }
    func validate(_ payment: SignedPayment) throws {
        guard let binding = lock.withLock({ expected[payment.operationID] }), binding.0 == payment.digest else { throw PaymentFailure.staleContext }
        let current = try provider()
        guard BaseBCHAdapter.sameView(current, binding.1), current.complete, current.fresh,
              current.observedAt >= 0, current.observedAt <= clock.read().wall else { throw PaymentFailure.staleContext }
        try BaseBCHAdapter.requireVault(vault, custody: custody)
    }
}

/// Unknown transport may settle after affirmative reconciliation. A concrete completion
/// failure remains visible until a fresh process/account proves its local lease is gone.
private final class BaseLeaseDisposalState: @unchecked Sendable {
    enum State: Equatable { case pending, unknown, disposed, failed }
    private let lock = NSLock()
    private var value = State.pending
    func complete(_ state: State) { lock.withLock { if value != .failed { value = state } } }
    var state: State { lock.withLock { value } }
}
