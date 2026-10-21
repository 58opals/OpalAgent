import CryptoKit
import Foundation

/// Trusted service composition retains this exact scope across attempts and restarts.
/// No request, default startup or recovery path constructs this capability.
struct KeychainNewWalletCreation: Sendable {
    let installationID: String
    let walletID: String
    let continuity: ContinuityCoordinator
    let vault: WalletSeedVault
    let keys: KeychainWrappingKeyProvisioner

    init(accessGroup: String, installationID: String, walletID: String,
         database: any ContinuityDatabase, accounts: any SeedAccountProvider,
         operations: any KeychainItemOperations,
         generateKey: @escaping @Sendable () throws -> SymmetricKey = { SymmetricKey(size: .bits256) },
         storageLease: StoreLock? = nil) throws {
        self.installationID = installationID
        self.walletID = walletID
        let reader = try KeychainWrappingKeySource(accessGroup: accessGroup, walletID: walletID,
            operations: operations)
        let anchor = try KeychainContinuityAnchorStore(accessGroup: accessGroup,
            installationID: installationID, walletID: walletID, operations: operations)
        continuity = ContinuityCoordinator(database: database, anchor: anchor, storageLease: storageLease)
        vault = WalletSeedVault(keys: reader, accounts: accounts)
        keys = try KeychainWrappingKeyProvisioner(accessGroup: accessGroup, walletID: walletID,
            operations: operations, generateKey: generateKey)
    }

    func ownerControl(policy: AuthorityPolicy) -> OwnerWalletControl {
        OwnerWalletControl(continuity: continuity, policy: policy, newWalletCreation: self)
    }
}
