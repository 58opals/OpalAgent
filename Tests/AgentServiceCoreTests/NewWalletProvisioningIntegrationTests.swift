import AgentValues
import CryptoKit
import Foundation
import Security
import Testing
@testable import AgentServiceCore

struct NewWalletProvisioningIntegrationTests {
    @Test func composedCreationVerifiesItsKeyAndCommitsRestrictedEncryptedCustody() async throws {
        let fixture = try ProvisioningFixture()
        defer { fixture.remove() }
        let creation = try fixture.creation()
        let control = creation.ownerControl(policy: provisioningPolicy)
        #expect(fixture.operations.backend.calls.isEmpty)
        #expect(fixture.effects.keyGenerations == 0)

        let custody = try await control.createNew(network: "mainnet", owner: provisioningOwner, now: 10)

        let stored = try #require(try fixture.journal.read())
        let anchor = try #require(try fixture.anchor().read())
        #expect(stored.installationID == "installation")
        #expect(stored.authorization.walletID == "wallet" && stored.authorization.network == "mainnet")
        #expect(stored.authorization.generation == 1)
        #expect(stored.mode == .restricted && stored.history == .complete)
        #expect(stored.authorization.grants.isEmpty && stored.approvals.isEmpty)
        #expect(stored.requests.isEmpty && stored.payments.isEmpty && stored.gates.isEmpty)
        #expect(stored.allocations.isEmpty && stored.publicSnapshots.isEmpty)
        #expect(stored.custody == custody)
        #expect(try anchor.committed == stored.reference())
        #expect(anchor.pending == nil && anchor.recovery == nil)
        #expect(creation.continuity.status() == .trusted(mode: .restricted, history: .complete, generation: 1))
        #expect(fixture.effects.keyGenerations == 1 && fixture.effects.mnemonicGenerations == 1)
        #expect(fixture.operations.keyAdds == 1 && fixture.operations.keyUpdates == 0)
        #expect(custody.encryptedMnemonic.body.range(of: provisioningMnemonic) == nil)
        #expect(try await creation.vault.open(custody) == provisioningMnemonic)

        // Verify the authenticated envelope independently of the vault's decrypt path.
        let cleartext = try AES.GCM.open(AES.GCM.SealedBox(combined: custody.encryptedMnemonic.body),
            using: SymmetricKey(data: provisioningKey), authenticating: provisioningContext(walletID: "wallet"))
        let envelope = try #require(try JSONSerialization.jsonObject(with: cleartext) as? [String: String])
        #expect(envelope["profile"] == "bip39-empty/bip44-145-0/v1")
        #expect(envelope["network"] == "mainnet")
        #expect(envelope["mnemonic"].flatMap { Data(base64Encoded: $0) } == provisioningMnemonic)
        #expect(custody.accountID == "synthetic-account")
        #expect(custody.publicDescriptor == Data("synthetic public descriptor".utf8))
        #expect(try SQLiteJournal(path: fixture.databasePath).read() == stored)

        let beforeDatabase = try fixture.databaseBytes()
        let beforeItems = fixture.operations.backend.storedItems as NSArray
        let beforeWrites = fixture.operations.writeCount
        await #expect(throws: ContinuityError.invalidState) {
            try await control.createNew(network: "mainnet", owner: provisioningOwner, now: 10)
        }
        #expect(try fixture.databaseBytes() == beforeDatabase)
        #expect(beforeItems.isEqual(fixture.operations.backend.storedItems as NSArray))
        #expect(fixture.operations.writeCount == beforeWrites)
        #expect(fixture.effects.keyGenerations == 1 && fixture.effects.mnemonicGenerations == 1)
    }

    @Test func forgedOwnerAndUnsupportedNetworkCannotReachEntropyOrPersistence() async throws {
        let fixture = try ProvisioningFixture()
        defer { fixture.remove() }
        let control = try fixture.creation().ownerControl(policy: provisioningPolicy)
        let forged = OwnerAuthenticationEvidence(
            peer: PeerEvidence(identity: provisioningPolicy.bridge, signatureValidated: true),
            authenticationSucceeded: true, authenticatedAt: 10)

        await #expect(throws: AuthorizationFailure.untrustedPeer) {
            try await control.createNew(network: "mainnet", owner: forged, now: 10)
        }
        #expect(fixture.operations.backend.calls.isEmpty)
        await #expect(throws: ContinuityError.invalidState) {
            try await control.createNew(network: "unsupported", owner: provisioningOwner, now: 10)
        }

        #expect(fixture.effects.mnemonicGenerations == 0 && fixture.effects.derivations == 0)
        #expect(fixture.effects.keyGenerations == 0 && fixture.operations.writeCount == 0)
        #expect(try fixture.journal.read() == nil && fixture.anchor().read() == nil)
    }

    @Test func invalidatedOwnerConnectionAfterPreparationCannotProvisionOrCreate() async throws {
        let gate = ProvisioningPreparationGate(expected: 1)
        let fixture = try ProvisioningFixture(gate: gate)
        defer { fixture.remove() }
        let creation = try fixture.creation()
        let connection = OwnerConnectionContext(connectionID: "synthetic-owner-connection",
            peer: provisioningOwner.peer)
        let service = OwnerControlService(creation: creation, policy: provisioningPolicy,
            authority: { throw AuthorizationFailure.unavailable }, accounts: ProvisioningUnusedChain(),
            consent: ProvisioningConsent(), clock: ProvisioningClock())
        let pending = Task {
            let result: Result<OwnerControlResponse, any Error>
            do {
                result = .success(try await service.send(
                    OwnerControlRequest(call: .createWallet(network: .mainnet)), connection: connection))
            } catch { result = .failure(error) }
            await gate.completed()
            return result
        }
        #expect(await gate.waitUntilPrepared())
        connection.invalidate()
        await gate.release()

        switch await pending.value {
        case .success: Issue.record("An invalidated owner connection created a wallet")
        case .failure(let error): #expect(error as? ServiceProblem == ServiceProblem(.unavailable))
        }
        #expect(fixture.effects.mnemonicGenerations == 1 && fixture.effects.derivations == 1)
        #expect(fixture.effects.keyGenerations == 0 && fixture.operations.writeCount == 0)
        #expect(try fixture.journal.read() == nil && fixture.anchor().read() == nil)
    }

    @Test(arguments: ProvisioningExistingEvidence.allCases)
    private func existingOrUnreadableEvidenceRefusesCreationBeforeEntropy(_ evidence: ProvisioningExistingEvidence) async throws {
        let fixture = try ProvisioningFixture()
        defer { fixture.remove() }
        switch evidence {
        case .database:
            try fixture.journal.write(provisioningExistingState())
        case .ciphertextWithoutKey:
            var state = provisioningExistingState()
            let vault = WalletSeedVault(keys: InjectedWrappingKeySource {
                .available(SymmetricKey(data: provisioningKey))
            }, accounts: ProvisioningAccounts(effects: ProvisioningEffects(), gate: nil))
            state.custody = try await vault.protect(mnemonic: provisioningMnemonic, walletID: "wallet", network: "mainnet")
            try fixture.journal.write(state)
        case .anchor:
            let anchor = ContinuityAnchor(committed: try provisioningExistingState().reference())
            fixture.operations.backend.insert(provisioningAnchorItem(try JSONEncoder().encode(anchor)))
        case .key:
            fixture.operations.backend.insert(keychainTestItem(data: provisioningKey))
        case .malformedAnchor:
            fixture.operations.backend.insert(provisioningAnchorItem(Data([0xff])))
        case .malformedKey:
            fixture.operations.backend.insert(keychainTestItem(data: Data([0xff])))
        case .unavailableKey:
            fixture.operations.blockReads(service: provisioningKeyService)
        case .unavailableAnchor:
            fixture.operations.blockReads(service: provisioningAnchorService)
        case .unavailableDatabase:
            break
        }
        let database: any ContinuityDatabase = evidence == .unavailableDatabase
            ? ProvisioningUnreadableDatabase() : fixture.journal
        let control = try fixture.creation(database: database).ownerControl(policy: provisioningPolicy)
        let beforeDatabase = try fixture.databaseBytes()
        let beforeState = try fixture.journal.read()
        let beforeItems = fixture.operations.backend.storedItems as NSArray

        await #expect(throws: (any Error).self) {
            try await control.createNew(network: "mainnet", owner: provisioningOwner, now: 10)
        }

        #expect(fixture.effects.mnemonicGenerations == 0 && fixture.effects.derivations == 0)
        #expect(fixture.effects.keyGenerations == 0 && fixture.operations.writeCount == 0)
        #expect(try fixture.journal.read() == beforeState)
        #expect(try fixture.databaseBytes() == beforeDatabase)
        #expect(beforeItems.isEqual(fixture.operations.backend.storedItems as NSArray))
    }

    @Test(arguments: ProvisioningLateEvidence.allCases)
    private func evidenceAppearingDuringPreparationIsPreservedByTheLockedRecheck(_ evidence: ProvisioningLateEvidence) async throws {
        let gate = ProvisioningPreparationGate(expected: 1)
        let fixture = try ProvisioningFixture(gate: gate)
        defer { fixture.remove() }
        let control = try fixture.creation().ownerControl(policy: provisioningPolicy)
        let state = provisioningExistingState()
        let anchorItem = provisioningAnchorItem(try JSONEncoder().encode(ContinuityAnchor(committed: state.reference())))
        let pending = Task { await provisioningAttempt(control, gate: gate) }
        #expect(await gate.waitUntilPrepared())
        do {
            switch evidence {
            case .database: try fixture.journal.write(state)
            case .anchor: fixture.operations.backend.insert(anchorItem)
            case .key: fixture.operations.backend.insert(keychainTestItem(data: provisioningKey))
            }
        } catch {
            await gate.release()
            _ = await pending.value
            throw error
        }
        let beforeDatabase = try fixture.databaseBytes()
        let beforeItems = fixture.operations.backend.storedItems as NSArray
        await gate.release()

        switch await pending.value {
        case .success: Issue.record("Creation ignored evidence that appeared during preparation")
        case .failure(let error): #expect(error as? ContinuityError == .invalidState)
        }
        #expect(fixture.effects.mnemonicGenerations == 1 && fixture.effects.derivations == 1)
        #expect(fixture.effects.keyGenerations == 0 && fixture.operations.writeCount == 0)
        #expect(try fixture.databaseBytes() == beforeDatabase)
        #expect(beforeItems.isEqual(fixture.operations.backend.storedItems as NSArray))
    }

    @Test(arguments: ProvisioningInitialMarkerFailure.allCases)
    private func failedInitialMarkerCannotReachKeyGenerationOrCustody(_ failure: ProvisioningInitialMarkerFailure) async throws {
        let fixture = try ProvisioningFixture(initialMarkerFailure: failure)
        defer { fixture.remove() }
        let control = try fixture.creation().ownerControl(policy: provisioningPolicy)
        let beforeDatabase = try fixture.databaseBytes()

        await #expect(throws: (any Error).self) {
            try await control.createNew(network: "mainnet", owner: provisioningOwner, now: 10)
        }

        #expect(fixture.effects.keyGenerations == 0 && fixture.operations.keyAdds == 0)
        #expect(fixture.operations.keyUpdates == 0 && fixture.operations.initialMarkerAddAttempts == 1)
        #expect(try fixture.journal.read() == nil)
        #expect(try fixture.databaseBytes() == beforeDatabase)
        let attempted = try #require(fixture.operations.attemptedInitialMarker)
        let marker = try JSONDecoder().decode(ContinuityAnchor.self, from: attempted)
        #expect(marker.committed == nil && marker.pending == nil)
        #expect(marker.recovery?.targetGeneration == 1)
        let items = fixture.operations.backend.storedItems
        if failure == .errorAfterPersistence || failure == .readbackUnavailable {
            #expect(items.count == 1)
            #expect(items.first?[kSecValueData as String] as? Data == attempted)
            #expect(try fixture.anchor().read() == marker)
        } else {
            #expect(items.isEmpty)
            #expect(try fixture.anchor().read() == nil)
        }
    }

    @Test func concurrentPreparedRequestsHaveExactlyOneCreationWinner() async throws {
        let gate = ProvisioningPreparationGate(expected: 2)
        let fixture = try ProvisioningFixture(gate: gate)
        defer { fixture.remove() }
        let control = try fixture.creation().ownerControl(policy: provisioningPolicy)
        let first = Task { await provisioningAttempt(control, gate: gate) }
        let second = Task { await provisioningAttempt(control, gate: gate) }
        #expect(await gate.waitUntilPrepared())
        #expect(fixture.effects.keyGenerations == 0 && fixture.operations.writeCount == 0)
        await gate.release()
        let results = await [first.value, second.value]
        let successes = results.compactMap { try? $0.get() }
        #expect(successes.count == 1)
        #expect(results.filter { if case .failure = $0 { true } else { false } }.count == 1)
        #expect(fixture.effects.mnemonicGenerations == 2 && fixture.effects.derivations == 2)
        #expect(fixture.effects.keyGenerations == 1)
        #expect(fixture.operations.keyAdds == 1 && fixture.operations.keyUpdates == 0)
        let winner = try #require(successes.first)
        let stored = try #require(try fixture.journal.read())
        #expect(stored.custody == winner && stored.mode == .restricted)
        #expect(stored.authorization.grants.isEmpty)
        let anchor = try #require(try fixture.anchor().read())
        #expect(try anchor.committed == stored.reference())
        #expect(anchor.pending == nil && anchor.recovery == nil)
    }

    @Test(arguments: ProvisioningInterruption.allCases)
    private func interruptedInitializationRetainsEvidenceAndCannotRestartCreation(_ interruption: ProvisioningInterruption) async throws {
        let fixture = try ProvisioningFixture(interruption: interruption)
        defer { fixture.remove() }
        let control = try fixture.creation().ownerControl(policy: provisioningPolicy)

        await #expect(throws: (any Error).self) {
            try await control.createNew(network: "mainnet", owner: provisioningOwner, now: 10)
        }

        let retainedAnchor = try #require(try fixture.anchor().read())
        let latch = try #require(retainedAnchor.recovery)
        #expect(!latch.id.isEmpty && latch.targetGeneration == 1)
        #expect(fixture.effects.keyGenerations == 1)
        let retainedKey = fixture.operations.backend.storedItems.first {
            $0[kSecAttrService as String] as? String == provisioningKeyService
        }
        #expect((retainedKey != nil) == (interruption != .keyGeneration))
        if let retainedKey { #expect(retainedKey[kSecValueData as String] as? Data == provisioningKey) }
        let retainedState = try fixture.journal.read()
        switch interruption {
        case .keyGeneration, .keyAddAfterPersistence:
            #expect(retainedState == nil)
            #expect(retainedAnchor.committed == nil && retainedAnchor.pending == nil)
        case .databaseBeforeCommit:
            #expect(retainedState == nil && retainedAnchor.committed == nil)
            #expect(retainedAnchor.pending != nil)
        case .anchorPromotion:
            #expect(retainedState != nil && retainedAnchor.committed == nil)
            #expect(retainedAnchor.pending != nil)
        case .finalLatchClear:
            #expect(retainedState != nil && retainedAnchor.pending == nil)
            #expect(try retainedAnchor.committed == retainedState?.reference())
        }
        if let retainedState {
            #expect(retainedState.mode == .restricted && retainedState.authorization.grants.isEmpty)
            #expect(retainedState.custody != nil)
        }
        let beforeDatabase = try fixture.databaseBytes()
        let beforeItems = fixture.operations.backend.storedItems as NSArray
        let beforeWrites = fixture.operations.writeCount

        // A fresh service instance reuses the provisioned service scope; no request
        // may switch namespace or resume initialization after an interrupted prefix.
        let restartedEffects = ProvisioningEffects()
        let restarted = try fixture.creation(database: SQLiteJournal(path: fixture.databasePath),
            effects: restartedEffects).ownerControl(policy: provisioningPolicy)
        await #expect(throws: (any Error).self) {
            try await restarted.createNew(network: "mainnet", owner: provisioningOwner, now: 10)
        }

        #expect(restartedEffects.mnemonicGenerations == 0 && restartedEffects.derivations == 0)
        #expect(restartedEffects.keyGenerations == 0)
        #expect(fixture.operations.writeCount == beforeWrites && fixture.operations.keyUpdates == 0)
        #expect(try fixture.databaseBytes() == beforeDatabase)
        #expect(try fixture.journal.read() == retainedState)
        #expect(try fixture.anchor().read() == retainedAnchor)
        #expect(beforeItems.isEqual(fixture.operations.backend.storedItems as NSArray))
    }
}

private let provisioningKeyService = "com.58opals.OpalAgent.wrapkey"
private let provisioningAnchorService = "com.58opals.OpalAgent.continuityanchor"
private let provisioningKey = Data(repeating: 7, count: 32)
private let provisioningMnemonic = Data("disposable synthetic provisioning fixture".utf8)
private let provisioningPolicy = AuthorityPolicy(
    bridge: SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "bridge"),
    owner: SignedPeerIdentity(teamIdentifier: "synthetic", signingIdentifier: "owner"),
    accountIDs: [], capabilities: [], ownerAuthenticationAge: 20)
private let provisioningOwner = OwnerAuthenticationEvidence(
    peer: PeerEvidence(identity: provisioningPolicy.owner, signatureValidated: true),
    authenticationSucceeded: true, authenticatedAt: 10)

private enum ProvisioningExistingEvidence: CaseIterable {
    case database, ciphertextWithoutKey, anchor, key, malformedAnchor, malformedKey
    case unavailableKey, unavailableAnchor, unavailableDatabase
}
private enum ProvisioningLateEvidence: CaseIterable { case database, anchor, key }
private enum ProvisioningInitialMarkerFailure: CaseIterable {
    case errorBeforePersistence, errorAfterPersistence, successWithoutPersistence, readbackUnavailable
}
private enum ProvisioningInterruption: CaseIterable {
    case keyGeneration, keyAddAfterPersistence, databaseBeforeCommit, anchorPromotion, finalLatchClear
}
private enum ProvisioningFixtureError: Error { case interrupted, unexpectedChainAccess, unexpectedMnemonic }

private struct ProvisioningFixture {
    let directory: URL
    let journal: SQLiteJournal
    let operations: ProvisioningOperations
    let effects = ProvisioningEffects()
    let gate: ProvisioningPreparationGate?
    let interruption: ProvisioningInterruption?
    var databasePath: String { directory.appendingPathComponent("journal.sqlite").path }

    init(gate: ProvisioningPreparationGate? = nil, interruption: ProvisioningInterruption? = nil,
         initialMarkerFailure: ProvisioningInitialMarkerFailure? = nil) throws {
        self.gate = gate
        self.interruption = interruption
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("new-wallet-provisioning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path, fault: { point in
            if interruption == .databaseBeforeCommit && point == .beforeCommit {
                throw ProvisioningFixtureError.interrupted
            }
        })
        operations = ProvisioningOperations(interruption: interruption, initialMarkerFailure: initialMarkerFailure)
    }

    func creation(database: (any ContinuityDatabase)? = nil, effects: ProvisioningEffects? = nil) throws -> KeychainNewWalletCreation {
        let effects = effects ?? self.effects
        let keyFailure = interruption == .keyGeneration
        return try KeychainNewWalletCreation(accessGroup: "test.OpalAgent.Service",
            installationID: "installation", walletID: "wallet", database: database ?? journal,
            accounts: ProvisioningAccounts(effects: effects, gate: gate), operations: operations,
            generateKey: { try effects.generateKey(fail: keyFailure) })
    }

    func anchor() throws -> KeychainContinuityAnchorStore {
        try KeychainContinuityAnchorStore(accessGroup: "test.OpalAgent.Service",
            installationID: "installation", walletID: "wallet", operations: operations)
    }
    func databaseBytes() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: databasePath)) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class ProvisioningEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var generatedMnemonics = 0
    private var derivedAccounts = 0
    private var generatedKeys = 0
    var mnemonicGenerations: Int { lock.withLock { generatedMnemonics } }
    var derivations: Int { lock.withLock { derivedAccounts } }
    var keyGenerations: Int { lock.withLock { generatedKeys } }
    func generateMnemonic() -> Data {
        lock.withLock { generatedMnemonics += 1 }
        return provisioningMnemonic
    }
    func derived() { lock.withLock { derivedAccounts += 1 } }
    func generateKey(fail: Bool) throws -> SymmetricKey {
        lock.withLock { generatedKeys += 1 }
        if fail { throw ProvisioningFixtureError.interrupted }
        return SymmetricKey(data: provisioningKey)
    }
}

private struct ProvisioningAccounts: SeedAccountProvider {
    let effects: ProvisioningEffects
    let gate: ProvisioningPreparationGate?
    func generateMnemonic() throws -> Data { effects.generateMnemonic() }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        effects.derived()
        guard mnemonic == provisioningMnemonic else { throw ProvisioningFixtureError.unexpectedMnemonic }
        if let gate { await gate.arriveAndWait() }
        return DerivedSeedAccount(accountID: "synthetic-account", publicDescriptor: Data("synthetic public descriptor".utf8))
    }
}

/// Completion also wakes the observer if a request fails before reaching preparation.
private actor ProvisioningPreparationGate {
    let expected: Int
    private var arrivals = 0
    private var completions = 0
    private var released = false
    private var observers: [CheckedContinuation<Bool, Never>] = []
    private var suspended: [CheckedContinuation<Void, Never>] = []
    init(expected: Int) { self.expected = expected }
    func arriveAndWait() async {
        arrivals += 1
        if arrivals >= expected { notify(true) }
        if !released { await withCheckedContinuation { suspended.append($0) } }
    }
    func waitUntilPrepared() async -> Bool {
        if arrivals >= expected { return true }
        if completions > 0 { return false }
        return await withCheckedContinuation { observers.append($0) }
    }
    func completed() {
        completions += 1
        if arrivals < expected { notify(false) }
    }
    func release() {
        released = true
        let pending = suspended
        suspended.removeAll()
        for continuation in pending { continuation.resume() }
    }
    private func notify(_ ready: Bool) {
        let pending = observers
        observers.removeAll()
        for continuation in pending { continuation.resume(returning: ready) }
    }
}

private func provisioningAttempt(_ control: OwnerWalletControl, gate: ProvisioningPreparationGate) async -> Result<WalletCustodyRecord, any Error> {
    let result: Result<WalletCustodyRecord, any Error>
    do { result = .success(try await control.createNew(network: "mainnet", owner: provisioningOwner, now: 10)) }
    catch { result = .failure(error) }
    await gate.completed()
    return result
}

/// Faults are selected by semantic item/anchor contents rather than operation offsets.
/// All storage is the isolated in-memory model; this never selects native operations.
private final class ProvisioningOperations: KeychainItemOperations, @unchecked Sendable {
    let backend = KeychainTestOperations()
    private let lock = NSLock()
    private let interruption: ProvisioningInterruption?
    private let initialMarkerFailure: ProvisioningInitialMarkerFailure?
    private var blockedService: String?
    private var faultUsed = false
    private var initialMarkerAttempts = 0
    private var initialMarkerData: Data?
    private var markerReadbackShouldFail = false
    init(interruption: ProvisioningInterruption?, initialMarkerFailure: ProvisioningInitialMarkerFailure?) {
        self.interruption = interruption
        self.initialMarkerFailure = initialMarkerFailure
    }
    var initialMarkerAddAttempts: Int { lock.withLock { initialMarkerAttempts } }
    var attemptedInitialMarker: Data? { lock.withLock { initialMarkerData } }
    var writeCount: Int { backend.addCount + backend.updateCount }
    var keyAdds: Int {
        backend.calls.filter {
            if case .add(let attributes) = $0 { attributes[kSecAttrService as String] as? String == provisioningKeyService }
            else { false }
        }.count
    }
    var keyUpdates: Int {
        backend.calls.filter {
            if case .update(let query, _) = $0 { query[kSecAttrService as String] as? String == provisioningKeyService }
            else { false }
        }.count
    }
    func blockReads(service: String) { lock.withLock { blockedService = service } }
    func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?) {
        let attributes = query as NSDictionary as! [String: Any]
        let markerFailure = lock.withLock {
            guard markerReadbackShouldFail,
                  attributes[kSecAttrService as String] as? String == provisioningAnchorService else { return false }
            markerReadbackShouldFail = false
            return true
        }
        if markerFailure { return (errSecNotAvailable, nil) }
        if lock.withLock({ blockedService != nil && blockedService == attributes[kSecAttrService as String] as? String }) {
            return (errSecInteractionNotAllowed, nil)
        }
        return backend.copyMatching(query)
    }
    func add(_ attributes: CFDictionary) -> OSStatus {
        let values = attributes as NSDictionary as! [String: Any]
        if values[kSecAttrService as String] as? String == provisioningAnchorService,
           let initialMarkerFailure {
            lock.withLock {
                initialMarkerAttempts += 1
                initialMarkerData = values[kSecValueData as String] as? Data
            }
            switch initialMarkerFailure {
            case .errorBeforePersistence: return errSecNotAvailable
            case .successWithoutPersistence: return errSecSuccess
            case .errorAfterPersistence:
                _ = backend.add(attributes)
                return errSecNotAvailable
            case .readbackUnavailable:
                let result = backend.add(attributes)
                lock.withLock { markerReadbackShouldFail = true }
                return result
            }
        }
        if values[kSecAttrService as String] as? String == provisioningKeyService,
           takeFault(.keyAddAfterPersistence) {
            _ = backend.add(attributes)
            return errSecNotAvailable
        }
        return backend.add(attributes)
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        let values = attributes as NSDictionary as! [String: Any]
        let scope = query as NSDictionary as! [String: Any]
        if scope[kSecAttrService as String] as? String == provisioningAnchorService,
           let data = values[kSecValueData as String] as? Data,
           let anchor = try? JSONDecoder().decode(ContinuityAnchor.self, from: data),
           anchor.committed != nil && anchor.pending == nil {
            let selected: ProvisioningInterruption = anchor.recovery == nil ? .finalLatchClear : .anchorPromotion
            if takeFault(selected) { return errSecNotAvailable }
        }
        return backend.update(query, attributes: attributes)
    }
    private func takeFault(_ selected: ProvisioningInterruption) -> Bool {
        lock.withLock {
            guard interruption == selected && !faultUsed else { return false }
            faultUsed = true
            return true
        }
    }
}

private final class ProvisioningUnreadableDatabase: ContinuityDatabase {
    func read() throws -> CanonicalState? { throw ContinuityStoreError.unavailable }
    func write(_ state: CanonicalState) throws { throw ProvisioningFixtureError.interrupted }
}
private struct ProvisioningConsent: OwnerConsentProvider {
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        OwnerConsentProof(challenge: challenge, authenticatedAt: 10)
    }
}
private struct ProvisioningClock: PaymentClock {
    func read() -> PaymentClockReading { PaymentClockReading(wall: 10, monotonic: 10) }
}
private struct ProvisioningUnusedChain: AccountChainBoundary {
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        throw ProvisioningFixtureError.unexpectedChainAccess
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        throw ProvisioningFixtureError.unexpectedChainAccess
    }
}

private func provisioningExistingState() -> CanonicalState {
    CanonicalState(installationID: "installation",
        authorization: AuthorizationLedger(walletID: "wallet", network: "mainnet", generation: 1, grants: []),
        commitID: "existing", mode: .restricted, history: .complete)
}
private func provisioningAnchorItem(_ data: Data) -> [String: Any] {
    keychainTestItem(service: provisioningAnchorService, account: "v1:12:installation6:wallet", data: data)
}
private func provisioningContext(walletID: String) -> Data {
    var context = Data("OpalAgentPayload/v1".utf8)
    for value in ["encrypted", walletID] {
        let bytes = Data(value.utf8)
        var count = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &count) { context.append(contentsOf: $0) }
        context.append(bytes)
    }
    return context
}
