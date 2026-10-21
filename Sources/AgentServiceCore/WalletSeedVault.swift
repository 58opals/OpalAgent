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
struct PreparedWalletSeed: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let mnemonic: Data
    let network: String
    let account: DerivedSeedAccount
    var description: String { "PreparedWalletSeed(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["material": "<redacted>"]) }
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

    func prepareNew(network: String) async throws -> PreparedWalletSeed {
        guard ["mainnet", "testnet", "chipnet"].contains(network) else { throw ContinuityError.invalidState }
        let mnemonic = try accounts.generateMnemonic()
        let account = try await accounts.deriveAccount(mnemonic: mnemonic, network: network)
        return PreparedWalletSeed(mnemonic: mnemonic, network: network, account: account)
    }

    func protect(_ prepared: PreparedWalletSeed, walletID: String,
                 wrappingKey: WrappingKeyAvailability) throws -> WalletCustodyRecord {
        guard !walletID.isEmpty, ["mainnet", "testnet", "chipnet"].contains(prepared.network) else {
            throw ContinuityError.invalidState
        }
        let envelope = MnemonicEnvelope(profile: WalletCustodyRecord.fixedProfile,
            network: prepared.network, mnemonic: prepared.mnemonic)
        let protector = PayloadProtector(profile: .encrypted, walletID: walletID, wrappingKey: wrappingKey)
        let result = WalletCustodyRecord(walletID: walletID, network: prepared.network,
            accountID: prepared.account.accountID,
            encryptedMnemonic: try protector.protect(JSONEncoder().encode(envelope)),
            publicDescriptor: prepared.account.publicDescriptor)
        try result.validate()
        return result
    }

    func protect(mnemonic: Data, walletID: String, network: String) async throws -> WalletCustodyRecord {
        guard ["mainnet", "testnet", "chipnet"].contains(network), !walletID.isEmpty else {
            throw ContinuityError.invalidState
        }
        let account = try await accounts.deriveAccount(mnemonic: mnemonic, network: network)
        return try protect(PreparedWalletSeed(mnemonic: mnemonic, network: network, account: account),
            walletID: walletID, wrappingKey: keys.wrappingKey())
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
    private let newWalletCreation: KeychainNewWalletCreation?

    init(continuity: ContinuityCoordinator, policy: AuthorityPolicy,
         newWalletCreation: KeychainNewWalletCreation? = nil) {
        self.continuity = continuity
        self.policy = policy
        self.newWalletCreation = newWalletCreation
    }

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
                  owner: OwnerAuthenticationEvidence, now: Int64,
                  authorizationCheck: @Sendable () throws -> Void = {}) async throws -> AccountSyncRecord {
        try authorizationCheck()
        try requireOwner(owner, now: now)
        let token = try continuity.transaction(classification: "owner.discoveryBegin") { state in
            try beginAccountRefresh(&state, accountID: accountID, network: network)
        }
        let observed = try await boundary.refresh(accountID: accountID, network: network)
        try authorizationCheck()
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

    /// Explicit service composition fixes the key, anchor and state identities together.
    func createNew(network: String, owner: OwnerAuthenticationEvidence, now: Int64,
                   authorizationCheck: @Sendable () throws -> Void = {}) async throws -> WalletCustodyRecord {
        guard let creation = newWalletCreation, creation.continuity === continuity else {
            throw ContinuityError.invalidState
        }
        try authorizationCheck()
        try requireOwner(owner, now: now)
        try continuity.requireFreshWallet()
        try creation.keys.requireAbsent()
        let prepared = try await creation.vault.prepareNew(network: network)
        try authorizationCheck()
        try requireOwner(owner, now: now)
        let commitID = UUID().uuidString
        let state = try continuity.initializeFreshWallet(commitID: commitID,
            preflight: {
                try authorizationCheck()
                try requireOwner(owner, now: now)
                try creation.keys.requireAbsent()
            }, makeState: {
                let key = try creation.keys.provision()
                let custody = try creation.vault.protect(prepared, walletID: creation.walletID,
                    wrappingKey: .available(key))
                return freshState(custody: custody, installationID: creation.installationID, commitID: commitID)
            })
        guard let custody = state.custody else { throw ContinuityError.invalidState }
        return custody
    }

    // Preprovisioned/injected composition remains read-only with respect to wrapping keys.
    func createNew(vault: WalletSeedVault, network: String, owner: OwnerAuthenticationEvidence,
                   now: Int64, walletID: String = UUID().uuidString,
                   authorizationCheck: @Sendable () throws -> Void = {}) async throws -> WalletCustodyRecord {
        guard !walletID.isEmpty else { throw ContinuityError.invalidState }
        try authorizationCheck()
        try requireOwner(owner, now: now)
        try continuity.requireFreshWallet()
        let prepared = try await vault.prepareNew(network: network)
        try authorizationCheck()
        try requireOwner(owner, now: now)
        // This path has no provisioning effect: an unavailable existing key must leave
        // fresh storage untouched, as before. Locked freshness is rechecked afterward.
        let custody = try vault.protect(prepared, walletID: walletID, wrappingKey: vault.keys.wrappingKey())
        let commitID = UUID().uuidString
        let initial = freshState(custody: custody, installationID: UUID().uuidString, commitID: commitID)
        _ = try continuity.initializeFreshWallet(commitID: commitID, preflight: {
            try authorizationCheck()
            try requireOwner(owner, now: now)
        }, makeState: { initial })
        return custody
    }

    private func freshState(custody: WalletCustodyRecord, installationID: String,
                            commitID: String) -> CanonicalState {
        CanonicalState(installationID: installationID,
            authorization: AuthorizationLedger(walletID: custody.walletID, network: custody.network,
                generation: 1, grants: []), commitID: commitID,
            mode: .restricted, history: .complete, custody: custody)
    }

    func restoreSeed(mnemonic: Data, vault: WalletSeedVault, network: String,
                     owner: OwnerAuthenticationEvidence, now: Int64,
                     walletID: String = UUID().uuidString,
                     authorizationCheck: @Sendable () throws -> Void = {}) async throws -> CanonicalState {
        try authorizationCheck()
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
        try authorizationCheck()
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
            maximumOwnerAuthenticationAge: policy.ownerAuthenticationAge, expectedAppleIntegrationIdentity: policy.appleIntegration)
        try authority.requireOwner(owner: owner, now: now)
    }
}
