import Foundation
import OpalBaseCore

/// The fixed mnemonic-only recovery profile. No persistent Base storage or network is opened.
struct BaseSeedAccountProvider: SeedAccountProvider {
    func generateMnemonic() throws -> Data {
        Data(try OpalBase.Key.Mnemonic.generate(length: .words12, language: .english).phrase.utf8)
    }

    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        let restored = try await signingAccount(mnemonic: mnemonic, network: network)
        let accountID = await restored.account.id
        return DerivedSeedAccount(accountID: accountID.base64EncodedString(), publicDescriptor: restored.descriptor)
    }

    /// Opens encrypted custody before restoring the private account retained only by service composition.
    func restoreSigningAccount(custody: WalletCustodyRecord, vault: WalletSeedVault) async throws -> OpalBase.Account {
        let mnemonic = try await vault.open(custody)
        let restored = try await signingAccount(mnemonic: mnemonic, network: custody.network)
        let accountID = await restored.account.id
        guard accountID.base64EncodedString() == custody.accountID,
              restored.descriptor == custody.publicDescriptor else { throw PayloadProtectionError.contextMismatch }
        return restored.account
    }

    /// Uses only a public descriptor already bound to custody by trusted continuity.
    func restorePublicAccount(custody: WalletCustodyRecord) async throws -> OpalBase.Account {
        try custody.validate()
        guard let descriptor = String(data: custody.publicDescriptor, encoding: .utf8) else {
            throw PayloadProtectionError.contextMismatch
        }
        let snapshot = OpalBase.Account.Snapshot(purpose: .bip44, coinType: .bitcoinCash,
            accountUnhardenedIndex: 0,
            addressBook: .init(receivingEntries: [], changeEntries: [], utxos: [], transactions: []))
        let account = try await OpalBase.Account(serializedAccountExtendedPublicKey: descriptor,
            purpose: .bip44, coinType: .bitcoinCash, account: 0, snapshot: snapshot)
        let accountID = await account.id
        guard accountID.base64EncodedString() == custody.accountID else { throw PayloadProtectionError.contextMismatch }
        return account
    }

    private func signingAccount(mnemonic: Data, network: String) async throws -> (account: OpalBase.Account, descriptor: Data) {
        guard OpalBase.Network.Environment(rawValue: network) != nil,
              let phrase = String(data: mnemonic, encoding: .utf8) else {
            throw ContinuityError.invalidState
        }
        let mnemonic = try OpalBase.Key.Mnemonic(phrase: phrase)
        let descriptor = try mnemonic.makeSerializedAccountExtendedPublicKey(
            passphrase: "", purpose: .bip44, coinType: .bitcoinCash, account: 0)
        let wallet = try OpalBase.Wallet(mnemonic: mnemonic, passphrase: "", purpose: .bip44, coinType: .bitcoinCash)
        try await wallet.addAccount(unhardenedIndex: 0)
        return (try await wallet.fetchAccount(at: 0), Data(descriptor.utf8))
    }
}
