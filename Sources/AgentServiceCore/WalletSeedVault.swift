import Foundation

struct WalletCustodyRecord: Codable, Equatable, Sendable {
    static let fixedProfile = "bip39-empty/bip44-145-0/v1"
    var walletID: String
    var network: String
    var accountID: String
    var profile: String = fixedProfile
    var encryptedMnemonic: ProtectedPayload
    var publicDescriptor: Data

    func validate() throws {
        guard profile == Self.fixedProfile, !walletID.isEmpty, !accountID.isEmpty,
              ["mainnet", "testnet", "chipnet"].contains(network),
              encryptedMnemonic.profile == .encrypted,
              encryptedMnemonic.walletID == walletID, !encryptedMnemonic.body.isEmpty,
              !publicDescriptor.isEmpty else { throw ContinuityError.invalidState }
    }
}

struct DerivedSeedAccount: Equatable, Sendable {
    var accountID: String
    var publicDescriptor: Data
}
protocol SeedAccountProvider: Sendable {
    func generateMnemonic() throws -> Data
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount
}
protocol WrappingKeySource: Sendable {
    func wrappingKey() throws -> WrappingKeyAvailability
}
struct InjectedWrappingKeySource: WrappingKeySource {
    var read: @Sendable () throws -> WrappingKeyAvailability
    func wrappingKey() throws -> WrappingKeyAvailability { try read() }
}
private struct MnemonicEnvelope: Codable {
    var profile: String
    var network: String
    var mnemonic: Data
}

/// Encrypts the fixed recovery profile; platform key access is supplied separately.
struct WalletSeedVault: Sendable {
    let keys: any WrappingKeySource
    let accounts: any SeedAccountProvider

    func create(walletID: String, network: String) async throws -> WalletCustodyRecord {
        try await protect(mnemonic: accounts.generateMnemonic(), walletID: walletID, network: network)
    }

    func protect(mnemonic: Data, walletID: String, network: String) async throws -> WalletCustodyRecord {
        guard ["mainnet", "testnet", "chipnet"].contains(network), !walletID.isEmpty else {
            throw ContinuityError.invalidState
        }
        let account = try await accounts.deriveAccount(mnemonic: mnemonic, network: network)
        let envelope = MnemonicEnvelope(profile: WalletCustodyRecord.fixedProfile, network: network, mnemonic: mnemonic)
        let payload = try protector(walletID: walletID).protect(JSONEncoder().encode(envelope))
        let result = WalletCustodyRecord(walletID: walletID, network: network, accountID: account.accountID,
            encryptedMnemonic: payload, publicDescriptor: account.publicDescriptor)
        try result.validate()
        return result
    }

    func open(_ record: WalletCustodyRecord) async throws -> Data {
        try record.validate()
        let cleartext = try protector(walletID: record.walletID).open(record.encryptedMnemonic)
        let envelope = try JSONDecoder().decode(MnemonicEnvelope.self, from: cleartext)
        guard envelope.profile == record.profile, envelope.network == record.network else {
            throw PayloadProtectionError.contextMismatch
        }
        let derived = try await accounts.deriveAccount(mnemonic: envelope.mnemonic, network: record.network)
        guard derived.accountID == record.accountID, derived.publicDescriptor == record.publicDescriptor else {
            throw PayloadProtectionError.contextMismatch
        }
        return envelope.mnemonic
    }

    func requireAvailable(_ record: WalletCustodyRecord) throws {
        try record.validate()
        // Authenticated decryption also rejects a wrong-but-present key. Do not create a key here.
        _ = try protector(walletID: record.walletID).open(record.encryptedMnemonic)
    }

    private func protector(walletID: String) throws -> PayloadProtector {
        PayloadProtector(profile: .encrypted, walletID: walletID, wrappingKey: try keys.wrappingKey())
    }
}

struct OwnerRecoverySummary: Equatable, Sendable {
    var status: ContinuityStatus
    var walletID: String?
    var generation: UInt64?
    var unresolvedPayments: [String]
}

/// Remains reachable for authenticated owner recovery when integration startup is denied.
struct OwnerWalletControl: Sendable {
    let continuity: ContinuityCoordinator
    let policy: AuthorityPolicy

    func inspect(owner: OwnerAuthenticationEvidence, now: Int64) throws -> OwnerRecoverySummary {
        try requireOwner(owner, now: now)
        let status = continuity.status()
        let state = try continuity.inspectRecoveryState()
        return OwnerRecoverySummary(status: status, walletID: state?.authorization.walletID,
            generation: state?.authorization.generation,
            unresolvedPayments: state?.payments.filter(\.liabilityUnresolved).map(\.id).sorted() ?? [])
    }

    func recover(owner: OwnerAuthenticationEvidence, now: Int64, source: CanonicalState? = nil) throws -> CanonicalState {
        try requireOwner(owner, now: now)
        return try continuity.recover(ownerAuthorized: true, source: source)
    }

    /// Public funds discovery is allowed in trusted restricted storage without issuing authority or addresses.
    func discover(accountID: String, network: String, boundary: any AccountChainBoundary,
                  owner: OwnerAuthenticationEvidence, now: Int64) async throws -> AccountSyncRecord {
        try requireOwner(owner, now: now)
        let token = try continuity.transaction(classification: "owner.discoveryBegin") { state in
            try beginAccountRefresh(&state, accountID: accountID, network: network)
        }
        let observed = try await boundary.refresh(accountID: accountID, network: network)
        try requireOwner(owner, now: now)
        return try continuity.transaction(classification: "owner.discoveryComplete") { state in
            try completeAccountRefresh(&state, token: token, observed: observed)
        }
    }

    func enable(vault: WalletSeedVault, owner: OwnerAuthenticationEvidence, now: Int64) throws -> CanonicalState {
        try requireOwner(owner, now: now)
        return try continuity.enable(ownerAuthorized: true) { state in
            guard let custody = state.custody else { throw ContinuityError.invalidState }
            try vault.requireAvailable(custody)
        }
    }

    func createNew(vault: WalletSeedVault, network: String, owner: OwnerAuthenticationEvidence,
                   now: Int64, walletID: String = UUID().uuidString) async throws -> WalletCustodyRecord {
        try requireOwner(owner, now: now)
        let custody = try await vault.create(walletID: walletID, network: network)
        let initial = CanonicalState(installationID: UUID().uuidString,
            authorization: AuthorizationLedger(walletID: walletID, network: network, generation: 1, grants: []),
            mode: .restricted, history: .complete, custody: custody)
        try continuity.initializeFreshWallet(initial)
        return custody
    }

    func restoreSeed(mnemonic: Data, vault: WalletSeedVault, network: String,
                     owner: OwnerAuthenticationEvidence, now: Int64,
                     walletID: String = UUID().uuidString) async throws -> CanonicalState {
        try requireOwner(owner, now: now)
        let prior = try continuity.inspectRecoveryState()
        let expectedStored: RecoveryStoredExpectation
        if let prior { expectedStored = .matching(try prior.reference()) }
        else { expectedStored = .absent }
        let identity = try continuity.recoveryIdentity()
        let selectedWallet = prior?.authorization.walletID ?? identity?.walletID ?? walletID
        let selectedNetwork = prior?.authorization.network ?? identity?.network ?? network
        guard selectedNetwork == network else { throw ContinuityError.invalidState }
        let custody = try await vault.protect(mnemonic: mnemonic, walletID: selectedWallet, network: network)
        if let old = prior?.custody {
            guard custody.accountID == old.accountID, custody.publicDescriptor == old.publicDescriptor else {
                throw PayloadProtectionError.contextMismatch
            }
        }
        let source = prior ?? CanonicalState(installationID: identity?.installationID ?? UUID().uuidString,
            authorization: AuthorizationLedger(walletID: selectedWallet, network: network, generation: 1, grants: []))
        try requireOwner(owner, now: now)
        // Qualify the original complete rows before a new ciphertext changes their commitment.
        _ = try continuity.recover(ownerAuthorized: true, source: source, expectedStored: expectedStored)
        return try continuity.replaceRecoveredCustody(custody, ownerAuthorized: true,
            custodyCheck: { try vault.requireAvailable(custody) })
    }

    private func requireOwner(_ owner: OwnerAuthenticationEvidence, now: Int64) throws {
        // Expected identity and authentication age come from trusted composition, never restored rows.
        let authority = AuthorizationAuthority(ledger: AuthorizationLedger(walletID: "owner-control", network: "owner-control", generation: 0, grants: []),
            expectedBridgeIdentity: policy.bridge, trustedOwnerIdentity: policy.owner,
            maximumOwnerAuthenticationAge: policy.ownerAuthenticationAge)
        try authority.requireOwner(owner: owner, now: now)
    }
}
