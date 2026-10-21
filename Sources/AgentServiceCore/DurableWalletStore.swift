import CryptoKit
import Darwin
import Foundation

enum DurableWalletStoreError: Error, Equatable {
    case effectEngineAlreadyConfigured, custodyNotConfigured
    case initializationExists, scopeUnavailable, invalidScope, scopeMismatch
}

/// Owns the actual SQLite writer and startup barrier. Platform composition supplies the
/// independent anchor; no file-backed anchor or wrapping-key fallback is installed here.
final class DurableWalletStore: @unchecked Sendable {
    let continuity: ContinuityCoordinator
    let ownerControl: OwnerWalletControl
    let scope: WalletStoreScope?
    let vault: WalletSeedVault?
    let permitsNewWallet: Bool
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
        self.scope = nil; self.vault = nil; self.permitsNewWallet = false
        // A recovery failure leaves only the owner facade available, not integration authority.
        self.authority = try? ServiceAuthority(continuity: coordinator, policy: policy)
    }

    /// Explicitly establishes a new service-selected root once. Any interrupted prefix is retained.
    static func initializeNew(directory: URL, accessGroup: String, accounts: any SeedAccountProvider,
                              operations: any KeychainItemOperations, policy: AuthorityPolicy,
                              generateKey: @escaping @Sendable () throws -> SymmetricKey = {
                                  SymmetricKey(size: .bits256)
                              }) throws -> DurableWalletStore {
        guard directory.isFileURL else { throw SQLiteJournalError.invalidPath }
        guard mkdir(directory.path, S_IRWXU) == 0 else {
            if errno == EEXIST { throw DurableWalletStoreError.initializationExists }
            throw DurableWalletStoreError.scopeUnavailable
        }
        let lease = try StoreLock(path: directory.appendingPathComponent("writer.lock").path)
        let scope = WalletStoreScope(installationID: UUID(), walletID: UUID())
        try scope.writeNew(in: directory)
        let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
        let creation = try KeychainNewWalletCreation(accessGroup: accessGroup,
            installationID: scope.installationID.uuidString, walletID: scope.walletID.uuidString,
            database: journal, accounts: accounts, operations: operations,
            generateKey: generateKey, storageLease: lease)
        return DurableWalletStore(continuity: creation.continuity, policy: policy,
            owner: creation.ownerControl(policy: policy), scope: scope, vault: creation.vault,
            permitsNewWallet: true, authority: nil)
    }

    /// Opens only the same trusted selected store. Metadata locates; independent custody verifies.
    static func reopen(directory: URL, accessGroup: String, accounts: any SeedAccountProvider,
                       operations: any KeychainItemOperations,
                       policy: AuthorityPolicy) throws -> DurableWalletStore {
        try WalletStoreScope.requireDirectory(directory)
        let lease = try StoreLock(path: directory.appendingPathComponent("writer.lock").path,
                                  createIfMissing: false)
        let scope = try WalletStoreScope.read(in: directory)
        let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path,
                                        createIfMissing: false)
        let reader = try KeychainWrappingKeySource(accessGroup: accessGroup,
            walletID: scope.walletID.uuidString, operations: operations)
        let anchor = try KeychainContinuityAnchorStore(accessGroup: accessGroup,
            installationID: scope.installationID.uuidString, walletID: scope.walletID.uuidString,
            operations: operations)
        let coordinator = ContinuityCoordinator(database: journal, anchor: anchor, storageLease: lease)
        let vault = WalletSeedVault(keys: reader, accounts: accounts)
        try coordinator.inspect { state in
            guard state.installationID == scope.installationID.uuidString,
                  state.authorization.walletID == scope.walletID.uuidString,
                  let custody = state.custody, custody.walletID == scope.walletID.uuidString else {
                throw DurableWalletStoreError.scopeMismatch
            }
            try vault.requireAvailable(custody)
        }
        // This may invalidate retained preparation, and must succeed before any authority escapes.
        let authority = try ServiceAuthority(continuity: coordinator, policy: policy)
        return DurableWalletStore(continuity: coordinator, policy: policy,
            owner: OwnerWalletControl(continuity: coordinator, policy: policy), scope: scope,
            vault: vault, permitsNewWallet: false, authority: authority)
    }

    private init(continuity: ContinuityCoordinator, policy: AuthorityPolicy,
                 owner: OwnerWalletControl, scope: WalletStoreScope, vault: WalletSeedVault,
                 permitsNewWallet: Bool, authority: ServiceAuthority?) {
        self.continuity = continuity; self.policy = policy; self.ownerControl = owner
        self.scope = scope; self.vault = vault; self.permitsNewWallet = permitsNewWallet
        self.authority = authority
    }

    var configuredPaymentEngine: PaymentEngine? { lifecycle.withLock { paymentRuntime } }

    var authorityPolicy: AuthorityPolicy { policy }

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
