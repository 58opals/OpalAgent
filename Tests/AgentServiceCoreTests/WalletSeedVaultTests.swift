import CryptoKit
import Foundation
import OpalBaseCore
import Testing
@testable import AgentServiceCore

struct WalletSeedVaultTests {
    @Test(arguments: ["mainnet", "testnet", "chipnet"])
    func realBaseFixedProfileRoundTripsThroughEncryptedCodableStorage(_ network: String) async throws {
        let vault = seedVault()
        let record = try await vault.protect(mnemonic: disposableMnemonic, walletID: "wallet", network: network)
        let decoded = try JSONDecoder().decode(WalletCustodyRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.profile == WalletCustodyRecord.fixedProfile)
        #expect(decoded.encryptedMnemonic.profile == .encrypted)
        #expect(decoded.encryptedMnemonic.body.range(of: disposableMnemonic) == nil)
        #expect(try await vault.open(decoded) == disposableMnemonic)
        let independentDerivation = try await BaseSeedAccountProvider().deriveAccount(mnemonic: disposableMnemonic, network: network)
        #expect(decoded.accountID == independentDerivation.accountID)
        #expect(decoded.publicDescriptor == Data(disposableAccountExtendedPublicKey.utf8))
    }

    @Test func encryptedCustodyRestoresAnActualPrivateAccountAndASeparatePublicAccount() async throws {
        let vault = seedVault()
        let custody = try await vault.protect(mnemonic: disposableMnemonic, walletID: "wallet", network: "mainnet")
        let provider = BaseSeedAccountProvider()
        let signing = try await provider.restoreSigningAccount(custody: custody, vault: vault)
        let publicAccount = try await provider.restorePublicAccount(custody: custody)
        #expect(await signing.id.base64EncodedString() == custody.accountID)
        #expect(await publicAccount.id.base64EncodedString() == custody.accountID)
        let privateAddress = try await signing.selectNextDerivedAddress(for: .receiving)
        let publicAddress = try await publicAccount.selectNextDerivedAddress(for: .receiving)
        #expect(privateAddress.address == publicAddress.address)
        let payment = OpalBase.Account.Payment(recipients: [.init(address: publicAddress.address, amount: try .init(1_000))])
        await #expect(throws: OpalBase.Account.Error.privateKeyMaterialUnavailable) {
            try await publicAccount.prepareSpend(payment)
        }
    }

    @Test(arguments: SeedKeyFailure.allCases)
    private func signingAccountRestorationNeverFallsBackWhenTheWrappingKeyFails(_ failure: SeedKeyFailure) async throws {
        let custody = try await seedVault().protect(mnemonic: disposableMnemonic, walletID: "wallet", network: "mainnet")
        let provider = BaseSeedAccountProvider()
        await #expect(throws: failure.expected) {
            try await provider.restoreSigningAccount(custody: custody, vault: seedVault(key: failure.availability))
        }
        // Public recovery consumes only the continuity-bound descriptor, even when no private account can open.
        let publicAccount = try await provider.restorePublicAccount(custody: custody)
        #expect(await publicAccount.id.base64EncodedString() == custody.accountID)
        #expect(try await seedVault().open(custody) == disposableMnemonic)
    }

    @Test(arguments: SeedRecordTampering.allCases)
    private func protectionProfileAndBoundRecoveryContextCannotBeRelabeled(_ tampering: SeedRecordTampering) async throws {
        let vault = seedVault()
        var record = try await vault.protect(mnemonic: disposableMnemonic, walletID: "wallet", network: "mainnet")
        switch tampering {
        case .profile: record.profile = "different-profile"
        case .network: record.network = "testnet"
        case .wallet:
            record.walletID = "other-wallet"
            record.encryptedMnemonic.walletID = "other-wallet"
        case .account: record.accountID += "other"
        case .descriptor: record.publicDescriptor.append(1)
        case .plaintext: record.encryptedMnemonic.profile = .plaintext
        case .ciphertext: record.encryptedMnemonic.body[0] ^= 1
        }
        await #expect(throws: (any Error).self) { try await vault.open(record) }
        await #expect(throws: (any Error).self) {
            try await BaseSeedAccountProvider().restoreSigningAccount(custody: record, vault: vault)
        }
        if [.profile, .account, .descriptor, .plaintext].contains(tampering) {
            await #expect(throws: (any Error).self) {
                try await BaseSeedAccountProvider().restorePublicAccount(custody: record)
            }
        }
    }

    @Test(arguments: SeedKeyFailure.allCases)
    private func missingInaccessibleAndWrongKeysNeverRestoreOrReplaceEncryptedFunds(_ failure: SeedKeyFailure) async throws {
        let protected = try await seedVault().protect(mnemonic: disposableMnemonic, walletID: "wallet", network: "mainnet")
        let vault = seedVault(key: failure.availability)
        await #expect(throws: failure.expected) { try await vault.open(protected) }
        #expect(throws: failure.expected) { try vault.requireAvailable(protected) }
    }

    @Test func invalidMnemonicAndUnsupportedNetworkAreRejected() async throws {
        let provider = BaseSeedAccountProvider()
        await #expect(throws: (any Error).self) { try await provider.deriveAccount(mnemonic: Data([0xff]), network: "mainnet") }
        await #expect(throws: (any Error).self) { try await provider.deriveAccount(mnemonic: Data("not a valid mnemonic".utf8), network: "mainnet") }
        await #expect(throws: ContinuityError.invalidState) { try await provider.deriveAccount(mnemonic: disposableMnemonic, network: "regtest") }
    }

    @Test func newWalletRequiresSeparateOwnerEnablementAndIssuesNoGrant() async throws {
        let fixture = try SeedControlFixture()
        defer { fixture.remove() }
        let vault = seedVault()
        let custody = try await fixture.control.createNew(vault: vault, network: "mainnet", owner: fixture.owner, now: 10)
        let mnemonic = try await vault.open(custody)
        #expect(String(data: mnemonic, encoding: .utf8)?.split(separator: " ").count == 12)
        let stored = try #require(try fixture.journal.read())
        #expect(stored.mode == .restricted && stored.history == .complete)
        #expect(stored.custody == custody)
        #expect(stored.authorization.grants.isEmpty && stored.approvals.isEmpty)
        #expect(try fixture.anchor.read()?.pending == nil)
        #expect(try fixture.anchor.read()?.recovery == nil)
        let enabled = try fixture.control.enable(vault: seedVault(), owner: fixture.owner, now: 10)
        #expect(enabled.mode == .enabled && enabled.authorization.grants.isEmpty)
        #expect(enabled.custody == custody)
        #expect(try SQLiteJournal(path: fixture.databasePath).read() == enabled.canonicalized())
        await #expect(throws: ContinuityError.invalidState) {
            try await fixture.control.createNew(vault: vault, network: "mainnet", owner: fixture.owner, now: 10)
        }
        #expect(try fixture.journal.read() == enabled.canonicalized())
    }

    @Test(arguments: SeedKeyFailure.allCases)
    private func ownerEnableRequiresAnAvailableMatchingWrappingKey(_ failure: SeedKeyFailure) async throws {
        let fixture = try SeedControlFixture()
        defer { fixture.remove() }
        _ = try await fixture.control.createNew(vault: seedVault(), network: "mainnet", owner: fixture.owner, now: 10)
        let original = try fixture.journal.read()
        #expect(throws: failure.expected) {
            try fixture.control.enable(vault: seedVault(key: failure.availability), owner: fixture.owner, now: 10)
        }
        #expect(try fixture.journal.read() == original)
        #expect(try fixture.journal.read()?.mode == .restricted)
    }

    @Test func seedOnlyRestorationStaysRestrictedAndCannotEnableOrInventHistory() async throws {
        let fixture = try SeedControlFixture()
        defer { fixture.remove() }
        let restored = try await fixture.control.restoreSeed(mnemonic: disposableMnemonic, vault: seedVault(),
            network: "mainnet", owner: fixture.owner, now: 10)
        #expect(restored.mode == .restricted && restored.history == .incomplete)
        #expect(restored.authorization.grants.isEmpty && restored.requests.isEmpty && restored.payments.isEmpty)
        #expect(restored.allocations.isEmpty && restored.approvals.isEmpty)
        let restoredCustody = try #require(restored.custody)
        #expect(try await seedVault().open(restoredCustody) == disposableMnemonic)
        #expect(throws: ContinuityError.incompleteHistory) { try fixture.control.enable(vault: seedVault(), owner: fixture.owner, now: 10) }
        let again = try fixture.control.recover(owner: fixture.owner, now: 10)
        #expect(again.history == .incomplete && again.mode == .restricted)
        #expect(throws: ContinuityError.incompleteHistory) { try fixture.control.enable(vault: seedVault(), owner: fixture.owner, now: 10) }
        let replacement = seedVault(key: .available(SymmetricKey(data: Data(repeating: 9, count: 32))))
        let rewrapped = try await fixture.control.restoreSeed(mnemonic: disposableMnemonic, vault: replacement,
            network: "mainnet", owner: fixture.owner, now: 10)
        #expect(rewrapped.history == .incomplete && rewrapped.mode == .restricted)
        #expect(try await replacement.open(#require(rewrapped.custody)) == disposableMnemonic)
        #expect(throws: ContinuityError.incompleteHistory) { try fixture.control.enable(vault: replacement, owner: fixture.owner, now: 10) }
    }

    @Test func forgedOwnerCannotCreateInspectRecoverOrEnable() async throws {
        let fixture = try SeedControlFixture()
        defer { fixture.remove() }
        let forged = OwnerAuthenticationEvidence(peer: PeerEvidence(identity: fixture.policy.bridge, signatureValidated: true),
            authenticationSucceeded: true, authenticatedAt: 10)
        await #expect(throws: AuthorizationFailure.untrustedPeer) {
            try await fixture.control.createNew(vault: seedVault(), network: "mainnet", owner: forged, now: 10)
        }
        #expect(throws: AuthorizationFailure.untrustedPeer) { try fixture.control.inspect(owner: forged, now: 10) }
        #expect(throws: AuthorizationFailure.untrustedPeer) { try fixture.control.recover(owner: forged, now: 10) }
        #expect(throws: AuthorizationFailure.untrustedPeer) { try fixture.control.enable(vault: seedVault(), owner: forged, now: 10) }
        #expect(try fixture.journal.read() == nil && fixture.anchor.read() == nil)
    }

    @Test func quarantinedOwnerRecoveryPreservesJournalAndLiabilitiesWithoutRestoringAuthority() async throws {
        let fixture = try SeedControlFixture()
        defer { fixture.remove() }
        let custody = try await fixture.control.createNew(vault: seedVault(), network: "mainnet", owner: fixture.owner, now: 10)
        _ = try fixture.control.enable(vault: seedVault(), owner: fixture.owner, now: 10)
        try addSeedLiability(to: fixture.continuity, accountID: custody.accountID)
        let before = try #require(try fixture.journal.read())
        var target = before
        target.commitID = "interrupted-target"
        var anchor = try #require(try fixture.anchor.read())
        anchor.pending = PendingState(parent: anchor.committed, target: try target.reference(), classification: "interrupted")
        try fixture.anchor.write(anchor)
        #expect(fixture.continuity.status() == .quarantined)
        let inspection = try fixture.control.inspect(owner: fixture.owner, now: 10)
        #expect(inspection.status == .quarantined && inspection.unresolvedPayments == ["possible"])
        #expect(throws: (any Error).self) { try fixture.control.enable(vault: seedVault(), owner: fixture.owner, now: 10) }
        let reset = try fixture.control.recover(owner: fixture.owner, now: 10)
        #expect(reset.mode == .restricted && reset.history == .complete)
        #expect(reset.payments == before.payments && reset.requests == before.requests && reset.gates == before.gates)
        #expect(reset.authorization.grants.allSatisfy { $0.revoked })
        #expect(reset.approvals.allSatisfy { !$0.active })
        let enabled = try fixture.control.enable(vault: seedVault(), owner: fixture.owner, now: 10)
        #expect(enabled.gates == before.gates && enabled.authorization.grants.allSatisfy { $0.revoked })
    }

    @Test func seedReplacementPreservesIndependentlyProvedCoverageAndSurvivingLiabilities() async throws {
        let fixture = try SeedControlFixture()
        defer { fixture.remove() }
        let vault = seedVault()
        let custody = try await fixture.control.createNew(vault: vault, network: "mainnet", owner: fixture.owner, now: 10)
        let mnemonic = try await vault.open(custody)
        _ = try fixture.control.enable(vault: seedVault(), owner: fixture.owner, now: 10)
        try addSeedLiability(to: fixture.continuity, accountID: custody.accountID)
        let before = try #require(try fixture.journal.read())
        let restored = try await fixture.control.restoreSeed(mnemonic: mnemonic, vault: vault,
            network: "mainnet", owner: fixture.owner, now: 10)
        #expect(restored.history == .complete && restored.mode == .restricted)
        #expect(restored.requests == before.requests && restored.payments == before.payments && restored.gates == before.gates)
        #expect(restored.authorization.grants.allSatisfy { $0.revoked } && restored.approvals.allSatisfy { !$0.active })
        #expect(restored.historyProvenance.sourceCommitment == (try before.reference()).commitment)
        #expect(try fixture.anchor.read()?.originalProofs.isEmpty == true)
        #expect(restored.custody?.encryptedMnemonic != before.custody?.encryptedMnemonic)
        #expect(try await vault.open(#require(restored.custody)) == mnemonic)
        let unchanged = try #require(try fixture.journal.read())
        await #expect(throws: PayloadProtectionError.contextMismatch) {
            try await fixture.control.restoreSeed(mnemonic: disposableMnemonic, vault: vault,
                network: "mainnet", owner: fixture.owner, now: 10)
        }
        #expect(try fixture.journal.read() == unchanged)
        let enabled = try fixture.control.enable(vault: vault, owner: fixture.owner, now: 10)
        #expect(enabled.mode == .enabled && enabled.history == .complete && enabled.gates == before.gates)
        #expect(enabled.authorization.grants.allSatisfy { $0.revoked } && enabled.approvals.allSatisfy { !$0.active })
    }

    @Test func suspendedSeedVerificationCannotReplaceAnEnginePaymentAdmittedInTheMeantime() async throws {
        let fixture = try SeedControlFixture()
        defer { fixture.remove() }
        let vault = seedVault()
        let custody = try await fixture.control.createNew(vault: vault, network: "mainnet", owner: fixture.owner, now: 10)
        let mnemonic = try await vault.open(custody)
        _ = try fixture.control.enable(vault: vault, owner: fixture.owner, now: 10)
        let policy = AuthorityPolicy(bridge: fixture.policy.bridge, owner: fixture.policy.owner,
            accountIDs: [custody.accountID], capabilities: ["read", "prepare", "submit"], ownerAuthenticationAge: 20)
        let authority = try ServiceAuthority(continuity: fixture.continuity, policy: policy)
        let issued = try authority.enroll(id: "race-grant", integrationID: "race-integration",
            accounts: [custody.accountID], capabilities: ["read", "prepare", "submit"], expiry: nil, owner: fixture.owner, now: 10)
        let peer = PeerEvidence(identity: policy.bridge, signatureValidated: true)
        let session = try authority.authenticate(connectionID: "race", peer: peer, credential: issued.rawValue, now: 10)
        let prior = try #require(try fixture.journal.read())
        let gate = SeedDerivationGate()
        let suspendedVault = WalletSeedVault(keys: vault.keys, accounts: SuspendedSeedAccountProvider(gate: gate))
        let restore = Task {
            try await fixture.control.restoreSeed(mnemonic: mnemonic, vault: suspendedVault,
                network: "mainnet", owner: fixture.owner, now: 10)
        }
        defer { restore.cancel(); Task { await gate.release() } }
        await gate.waitUntilEntered()
        let boundary = SeedRacePaymentBoundary()
        let engine = PaymentEngine(continuity: fixture.continuity, authorityPolicy: policy, boundary: boundary, clock: SeedRaceClock())
        let payment = try await engine.prepare(PaymentRequest(accountID: custody.accountID, network: "mainnet",
            requestKey: String(repeating: "f", count: 32), destinationScript: Data([0x51]), amount: 1_000),
            session: session, connectionID: "race", peer: peer)
        try await waitForSeedRacePayment(payment.payment.id, disposition: .prepared, journal: fixture.journal)
        _ = try await engine.submit(operationID: payment.payment.id, session: session, connectionID: "race", peer: peer)
        try await waitForSeedRacePayment(payment.payment.id, disposition: .uncertain, journal: fixture.journal)
        let captured = try fixture.continuity.inspect { state in (state, try fixture.anchor.read()) }
        let current = captured.0
        let anchor = captured.1
        // An explicit unproved earlier snapshot is also denied outside the seed facade.
        #expect(throws: ContinuityError.invalidState) {
            try fixture.continuity.recover(ownerAuthorized: true, source: prior)
        }
        #expect(try fixture.journal.read() == current && fixture.anchor.read() == anchor)
        await gate.release()
        await #expect(throws: ContinuityError.invalidState) { try await restore.value }
        #expect(try fixture.journal.read() == current && fixture.anchor.read() == anchor)
        let retained = try #require(current.payments.first { $0.id == payment.payment.id })
        #expect(!retained.canonicalBytes.isEmpty && retained.liabilityUnresolved && retained.attempts.count == 1)
        #expect(current.hasCompleteGateCoverage() && current.mode == .enabled && current.authorization.generation == 1)
        #expect(current.authorization.grants.contains { $0.id == "race-grant" && !$0.revoked })
        #expect(boundary.handoffs == 1)
    }

    @Test(arguments: SeedRewrapFault.allCases)
    private func recoveredCustodyWritePrefixesRetainCompleteCoverageAndLiabilities(_ fault: SeedRewrapFault) async throws {
        let fixture = try SeedControlFixture(fault: fault)
        defer { fixture.remove() }
        let oldVault = seedVault()
        let custody = try await fixture.control.createNew(vault: oldVault, network: "mainnet", owner: fixture.owner, now: 10)
        let mnemonic = try await oldVault.open(custody)
        _ = try fixture.control.enable(vault: oldVault, owner: fixture.owner, now: 10)
        try addSeedLiability(to: fixture.continuity, accountID: custody.accountID)
        let before = try #require(try fixture.journal.read())
        let replacement = seedVault(key: .available(SymmetricKey(data: Data(repeating: 9, count: 32))))
        if fault == .ambiguousSQLAfter {
            let complete = try await fixture.control.restoreSeed(mnemonic: mnemonic, vault: replacement,
                network: "mainnet", owner: fixture.owner, now: 10)
            #expect(complete.mode == .restricted && complete.history == .complete)
        } else {
            await #expect(throws: (any Error).self) {
                try await fixture.control.restoreSeed(mnemonic: mnemonic, vault: replacement,
                    network: "mainnet", owner: fixture.owner, now: 10)
            }
            #expect(fixture.continuity.status() == .quarantined)
        }
        #expect(fixture.anchor.injected)
        let physical = try #require(try fixture.journal.read())
        #expect(physical.mode == .restricted && physical.history == .complete)
        #expect(physical.payments == before.payments && physical.requests == before.requests && physical.gates == before.gates)
        #expect(physical.authorization.grants.allSatisfy { $0.revoked } && physical.approvals.allSatisfy { !$0.active })
        if [.stageBefore, .sqlBefore].contains(fault) { #expect(physical.custody == custody) }
        else { #expect(physical.custody?.encryptedMnemonic != custody.encryptedMnemonic) }
        let reopened = try SQLiteJournal(path: fixture.databasePath)
        let coordinator = ContinuityCoordinator(database: reopened, anchor: fixture.anchor)
        let owner = OwnerWalletControl(continuity: coordinator, policy: fixture.policy)
        let recovered = try await owner.restoreSeed(mnemonic: mnemonic, vault: replacement,
            network: "mainnet", owner: fixture.owner, now: 10)
        #expect(recovered.mode == .restricted && recovered.history == .complete)
        #expect(recovered.payments == before.payments && recovered.requests == before.requests && recovered.gates == before.gates)
        #expect(try await replacement.open(#require(recovered.custody)) == mnemonic)
        #expect(try fixture.anchor.read()?.pending == nil && fixture.anchor.read()?.recovery == nil)
        let enabled = try owner.enable(vault: replacement, owner: fixture.owner, now: 10)
        #expect(enabled.gates == before.gates && enabled.authorization.grants.allSatisfy { $0.revoked })
        #expect(enabled.approvals.allSatisfy { !$0.active })
    }

    @Test func recoveredCustodyReplacementRejectsUnauthorizedEnabledAndChangedScope() async throws {
        let fixture = try SeedControlFixture()
        defer { fixture.remove() }
        let vault = seedVault()
        let custody = try await fixture.control.createNew(vault: vault, network: "mainnet", owner: fixture.owner, now: 10)
        _ = try fixture.control.enable(vault: vault, owner: fixture.owner, now: 10)
        let enabledReference = try #require(try fixture.journal.read()).reference()
        #expect(throws: ContinuityError.ownerRequired) {
            try fixture.continuity.replaceRecoveredCustody(custody, ownerAuthorized: false, custodyCheck: {})
        }
        #expect(throws: ContinuityError.invalidState) {
            try fixture.continuity.replaceRecoveredCustody(custody, ownerAuthorized: true, custodyCheck: {})
        }
        #expect(try fixture.journal.read()?.reference() == enabledReference)
        let reset = try fixture.control.recover(owner: fixture.owner, now: 10)
        for changed in ["wallet", "network", "profile", "account", "descriptor"] {
            var proposed = custody
            switch changed {
            case "wallet": proposed.walletID = "other"; proposed.encryptedMnemonic.walletID = "other"
            case "network": proposed.network = "testnet"
            case "profile": proposed.profile = "other"
            case "account": proposed.accountID = "other"
            default: proposed.publicDescriptor = Data("other".utf8)
            }
            #expect(throws: ContinuityError.invalidState) {
                try fixture.continuity.replaceRecoveredCustody(proposed, ownerAuthorized: true, custodyCheck: {})
            }
            #expect(try fixture.journal.read()?.reference() == reset.reference())
        }
        #expect(throws: PayloadProtectionError.wrappingKeyInaccessible) {
            try fixture.continuity.replaceRecoveredCustody(custody, ownerAuthorized: true,
                custodyCheck: { throw PayloadProtectionError.wrappingKeyInaccessible })
        }
        #expect(try fixture.journal.read()?.reference() == reset.reference())
    }

    @Test(arguments: [SeedKeyFailure.missing, .inaccessible])
    private func completeJournalKeyLossRequiresAnExplicitUsableReplacement(_ unavailable: SeedKeyFailure) async throws {
        let fixture = try SeedControlFixture()
        defer { fixture.remove() }
        let oldVault = seedVault()
        let custody = try await fixture.control.createNew(vault: oldVault, network: "mainnet", owner: fixture.owner, now: 10)
        let mnemonic = try await oldVault.open(custody)
        _ = try fixture.control.enable(vault: oldVault, owner: fixture.owner, now: 10)
        try addSeedLiability(to: fixture.continuity, accountID: custody.accountID)
        let original = try #require(try fixture.journal.read())
        let independent = try fixture.anchor.read()
        await #expect(throws: unavailable.expected) {
            try await fixture.control.restoreSeed(mnemonic: mnemonic, vault: seedVault(key: unavailable.availability),
                network: "mainnet", owner: fixture.owner, now: 10)
        }
        #expect(try fixture.journal.read() == original && fixture.anchor.read() == independent)
        let replacement = seedVault(key: .available(SymmetricKey(data: Data(repeating: 9, count: 32))))
        let reset = try await fixture.control.restoreSeed(mnemonic: mnemonic, vault: replacement,
            network: "mainnet", owner: fixture.owner, now: 10)
        #expect(reset.mode == .restricted && reset.history == .complete)
        #expect(reset.payments == original.payments && reset.requests == original.requests && reset.gates == original.gates)
        #expect(reset.allocations == original.allocations && reset.paymentPolicy == original.paymentPolicy)
        #expect(reset.authorization.grants.allSatisfy { $0.revoked } && reset.approvals.allSatisfy { !$0.active })
        let restoredCustody = try #require(reset.custody)
        #expect(try await replacement.open(restoredCustody) == mnemonic)
        await #expect(throws: PayloadProtectionError.authenticationFailed) { try await oldVault.open(restoredCustody) }
        let signer = try await BaseSeedAccountProvider().restoreSigningAccount(custody: restoredCustody, vault: replacement)
        #expect(await signer.id.base64EncodedString() == custody.accountID)
        let enabled = try fixture.control.enable(vault: replacement, owner: fixture.owner, now: 10)
        #expect(enabled.history == .complete && enabled.gates == original.gates)
        #expect(enabled.authorization.grants.allSatisfy { $0.revoked } && enabled.approvals.allSatisfy { !$0.active })
    }
}

private enum SeedRecordTampering: CaseIterable, Equatable, Sendable {
    case profile, network, wallet, account, descriptor, plaintext, ciphertext
}
private enum SeedKeyFailure: CaseIterable, Sendable {
    case missing, inaccessible, wrong
    var availability: WrappingKeyAvailability {
        switch self {
        case .missing: .missing
        case .inaccessible: .inaccessible
        case .wrong: .available(SymmetricKey(data: Data(repeating: 9, count: 32)))
        }
    }
    var expected: PayloadProtectionError {
        switch self {
        case .missing: .wrappingKeyMissing
        case .inaccessible: .wrappingKeyInaccessible
        case .wrong: .authenticationFailed
        }
    }
}

// Published BIP39 test-vector material: permanently disposable and never funded.
private let disposableMnemonic = Data("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8)
// The existing Base known-vector expectation for m/44'/145'/0' with an empty passphrase.
private let disposableAccountExtendedPublicKey = "xpub6ByHsPNSQXTWZ7PLESMY2FufyYWtLXagSUpMQq7Un96SiThZH2iJB1X7pwviH1WtKVeDP6K8d6xxFzzoaFzF3s8BKCZx8oEDdDkNnp4owAZ"
private func seedVault(key: WrappingKeyAvailability = .available(SymmetricKey(data: Data(repeating: 7, count: 32)))) -> WalletSeedVault {
    WalletSeedVault(keys: InjectedWrappingKeySource(read: { key }), accounts: BaseSeedAccountProvider())
}

private struct SeedControlFixture {
    let directory: URL
    let databasePath: String
    let journal: SQLiteJournal
    let anchor: SeedTestAnchor
    let continuity: ContinuityCoordinator
    let policy: AuthorityPolicy
    let owner: OwnerAuthenticationEvidence
    var control: OwnerWalletControl { OwnerWalletControl(continuity: continuity, policy: policy) }

    init(fault: SeedRewrapFault? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        databasePath = directory.appendingPathComponent("wallet.sqlite").path
        let anchor = SeedTestAnchor(path: directory.appendingPathComponent("independent-anchor.json").path, fault: fault)
        self.anchor = anchor
        journal = try SQLiteJournal(path: databasePath) { try anchor.injectSQL($0) }
        continuity = ContinuityCoordinator(database: journal, anchor: anchor)
        let ownerIdentity = SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "owner")
        policy = AuthorityPolicy(bridge: SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "bridge"),
            owner: ownerIdentity, accountIDs: [], capabilities: [], ownerAuthenticationAge: 20)
        owner = OwnerAuthenticationEvidence(peer: PeerEvidence(identity: ownerIdentity, signatureValidated: true),
            authenticationSucceeded: true, authenticatedAt: 10)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private enum SeedRewrapFault: CaseIterable, Equatable, Sendable {
    case stageBefore, sqlBefore, ambiguousSQLAfter, promotionBefore
}
private enum SeedInjectedFailure: Error { case stop }
private final class SeedTestAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let path: String
    private let fault: SeedRewrapFault?
    private(set) var injected = false
    init(path: String, fault: SeedRewrapFault? = nil) { self.path = path; self.fault = fault }
    func injectSQL(_ point: SQLiteJournalFaultPoint) throws {
        guard !injected, try read()?.pending?.classification == "ownerCustodyRewrap" else { return }
        if (point == .beforeCommit && fault == .sqlBefore) || (point == .afterCommit && fault == .ambiguousSQLAfter) {
            injected = true
            throw SeedInjectedFailure.stop
        }
    }
    func read() throws -> ContinuityAnchor? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try JSONDecoder().decode(ContinuityAnchor.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    func write(_ anchor: ContinuityAnchor) throws {
        if !injected, fault == .stageBefore, anchor.pending?.classification == "ownerCustodyRewrap" {
            injected = true
            throw SeedInjectedFailure.stop
        }
        if !injected, fault == .promotionBefore, anchor.pending == nil, anchor.recovery == nil,
           try read()?.pending?.classification == "ownerCustodyRewrap" {
            injected = true
            throw SeedInjectedFailure.stop
        }
        try JSONEncoder().encode(anchor).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private func addSeedLiability(to continuity: ContinuityCoordinator, accountID: String) throws {
    try continuity.transaction { state in
        state.authorization.grants.append(GrantRecord(id: "grant", integrationID: "integration", accountIDs: [accountID],
            capabilities: ["read"], credentialDigest: Data(repeating: 1, count: 32), credentialGeneration: 1, expiresAt: nil, revoked: false))
        state.payments.append(PaymentRecord(id: "possible", accountID: accountID, network: "mainnet", originGrantID: "grant",
            canonicalBytes: Data([1, 2, 3]), transactionDigest: Data([4]), selectedInputs: ["input"], change: Data([5]),
            disposition: .possiblyRelayed, liabilityUnresolved: true,
            attempts: [AttemptRecord(id: "attempt", number: 1, commandID: nil, outcome: "unknown")], evidence: [], closures: []))
        state.requests.append(RequestRecord(id: "request", principalID: "grant", paymentID: "possible", method: "prepare",
            key: "0123456789abcdef0123456789abcdef", binding: Data([6]), disposition: .consumed, result: Data([7]),
            consumedAttemptID: "attempt", tombstone: true))
        state.approvals.append(ApprovalRecord(id: "approval", paymentID: "possible", generation: 1, context: Data([8]), active: true))
        state.gates.append(SpendingGate(accountID: accountID, liabilityIDs: ["possible"], restrictions: ["uncertain"]))
    }
}


private actor SeedDerivationGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
private struct SuspendedSeedAccountProvider: SeedAccountProvider {
    let gate: SeedDerivationGate
    func generateMnemonic() throws -> Data { try BaseSeedAccountProvider().generateMnemonic() }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        await gate.suspend()
        return try await BaseSeedAccountProvider().deriveAccount(mnemonic: mnemonic, network: network)
    }
}
private struct SeedRaceClock: PaymentClock {
    func read() -> PaymentClockReading { .init(wall: 10, monotonic: 10) }
}
private final class SeedRacePaymentBoundary: PaymentExecutionBoundary, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var handoffs: Int { lock.withLock { count } }
    func prepare(_ input: PaymentPreparationInput) async throws -> PaymentPreview {
        PaymentPreview(operationID: input.operationID, accountID: input.accountID, network: input.network,
            destinationScript: input.destinationScript, amount: input.amount, fee: 100,
            selectedInputs: ["seed-race-input"], change: Data([1]),
            templateDigest: paymentDigest(try paymentEncoding(input)), leaseDeadline: 1_000)
    }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment {
        let bytes = try paymentEncoding(preview)
        return SignedPayment(operationID: preview.operationID, bytes: bytes, digest: paymentDigest(bytes))
    }
    func preflight(_ payment: SignedPayment) async throws {}
    func validateAdmission(_ payment: SignedPayment) throws {
        guard !payment.bytes.isEmpty, payment.digest == paymentDigest(payment.bytes) else { throw PaymentFailure.invalidRequest }
    }
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        try admission {
            lock.withLock { count += 1 }
            return PaymentTransportInvocation(id: UUID().uuidString, result: { .unknown(source: "synthetic-seed-race") }, cancel: {})
        }
    }
    func dispose(operationID: String) async throws {}
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation {
        PaymentObservation(source: "synthetic-seed-race", view: "view", chainTip: "tip", observedAt: 10, complete: true, fresh: true)
    }
}
private func waitForSeedRacePayment(_ id: String, disposition: PaymentDisposition, journal: SQLiteJournal) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try journal.read()?.payments.first(where: { $0.id == id })?.disposition == disposition { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw PaymentFailure.invalidTransition
}
