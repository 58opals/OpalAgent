import Foundation

enum DurableWalletStoreError: Error { case effectEngineAlreadyConfigured }

/// Owns the actual SQLite writer and startup barrier. Platform composition supplies the
/// independent anchor; no file-backed anchor or wrapping-key fallback is installed here.
final class DurableWalletStore: @unchecked Sendable {
    let continuity: ContinuityCoordinator
    let ownerControl: OwnerWalletControl
    private let policy: AuthorityPolicy
    private let lifecycle = NSLock()
    private var authority: ServiceAuthority?
    private var paymentRuntime: PaymentEngine?
    private var receiveRuntime: ReceiveEngine?

    init(directory: URL, anchor: any ContinuityAnchorStore, policy: AuthorityPolicy) throws {
        guard directory.isFileURL else { throw SQLiteJournalError.invalidPath }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw SQLiteJournalError.invalidPath }
        let lease = try StoreLock(path: directory.appendingPathComponent("writer.lock").path)
        let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
        let coordinator = ContinuityCoordinator(database: journal, anchor: anchor, storageLease: lease)
        self.continuity = coordinator
        self.policy = policy
        self.ownerControl = OwnerWalletControl(continuity: coordinator, policy: policy)
        // A recovery failure leaves only the owner facade available, not integration authority.
        self.authority = try? ServiceAuthority(continuity: coordinator, policy: policy)
    }

    func integrationAuthority() throws -> ServiceAuthority {
        try lifecycle.withLock {
            if let authority { return authority }
            let value = try ServiceAuthority(continuity: continuity, policy: policy)
            authority = value
            return value
        }
    }

    // Configure each effect owner once; the store retains it for the runtime lifetime.
    func paymentEngine(boundary: any PaymentExecutionBoundary,
                       clock: any PaymentClock = SystemPaymentClock()) throws -> PaymentEngine {
        _ = try integrationAuthority()
        return try lifecycle.withLock {
            guard paymentRuntime == nil else { throw DurableWalletStoreError.effectEngineAlreadyConfigured }
            let engine = PaymentEngine(continuity: continuity, authorityPolicy: policy, boundary: boundary, clock: clock)
            paymentRuntime = engine
            return engine
        }
    }

    func receiveEngine(boundary: any AccountChainBoundary,
                       clock: any PaymentClock = SystemPaymentClock()) throws -> ReceiveEngine {
        _ = try integrationAuthority()
        return try lifecycle.withLock {
            guard receiveRuntime == nil else { throw DurableWalletStoreError.effectEngineAlreadyConfigured }
            let engine = ReceiveEngine(continuity: continuity, policy: policy, boundary: boundary, clock: clock)
            receiveRuntime = engine
            return engine
        }
    }
}
