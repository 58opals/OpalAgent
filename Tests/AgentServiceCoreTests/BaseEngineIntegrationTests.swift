import AgentNativeIPC
import AgentValues
import CryptoKit
import Foundation
import OpalBaseCore
import Testing
@testable import AgentServiceCore

private final class BCHIntegrationClock: PaymentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var reading = PaymentClockReading(wall: 1_000, monotonic: 100)
    func read() -> PaymentClockReading { lock.withLock { reading } }
    func advance(_ seconds: UInt64) { lock.withLock { reading.wall += Int64(seconds); reading.monotonic += seconds } }
}
private final class BCHIntegrationAnchor: ContinuityAnchorStore, @unchecked Sendable {
    let url: URL
    init(_ url: URL) { self.url = url }
    func read() throws -> ContinuityAnchor? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ContinuityAnchor.self, from: Data(contentsOf: url))
    }
    func write(_ value: ContinuityAnchor) throws { try JSONEncoder().encode(value).write(to: url, options: .atomic) }
}
private final class BCHIntegrationKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    func setAvailable(_ value: Bool) { lock.withLock { available = value } }
    func read() -> WrappingKeyAvailability {
        lock.withLock { available ? .available(SymmetricKey(data: Data(repeating: 0x42, count: 32))) : .missing }
    }
}
enum BCHProofMode: String, CaseIterable { case valid, absent, wrongRoot, staleView, wrongHeight }
/// Raw provider fixtures only: no PaymentObservation or payment result is precomputed here.
private actor BCHIntegrationRelayLatch {
    private var opened = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func close() { opened = false }
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}
private final class BCHPublicChain: @unchecked Sendable {
    private struct Entry { var bytes: Data; var transaction: OpalBase.Transaction; var height: Int }
    private let lock = NSLock()
    private var entries: [Data: Entry] = [:]
    private var unspents: [OpalBase.Transaction.Output.Unspent] = []
    private var sent: [Data] = []
    private var view = "view-A"
    private var proofMode = BCHProofMode.valid
    private var accepted = false
    let relayLatch = BCHIntegrationRelayLatch()
    private let clock: BCHIntegrationClock
    init(clock: BCHIntegrationClock) { self.clock = clock }
    var sentBytes: [Data] { lock.withLock { sent } }
    func setAccepted(_ value: Bool) { lock.withLock { accepted = value } }
    func setView(_ value: String) { lock.withLock { view = value } }
    func setProof(_ value: BCHProofMode) { lock.withLock { proofMode = value } }
    func context() -> BaseChainContext {
        lock.withLock { BaseChainContext(network: "mainnet", source: "raw-fixture", view: view,
            tip: "tip-10", tipHeight: 10, observedAt: clock.read().wall, complete: true, fresh: true) }
    }
    func publish(_ bytes: Data, height: Int, consumeInputs: Bool = true) throws {
        let transaction = try OpalBase.Transaction.decode(from: bytes).transaction
        let hash = Self.hash(bytes)
        lock.withLock {
            entries[hash] = Entry(bytes: bytes, transaction: transaction, height: height)
            if consumeInputs {
                let inputs = transaction.inputs
                unspents.removeAll { utxo in inputs.contains { $0.previousTransactionHash == utxo.previousTransactionHash && $0.previousTransactionOutputIndex == utxo.previousTransactionOutputIndex } }
            }
            for (index, output) in transaction.outputs.enumerated() {
                if !unspents.contains(where: { $0.previousTransactionHash.naturalOrder == hash && $0.previousTransactionOutputIndex == UInt32(index) }) {
                    unspents.append(.init(value: output.value, lockingScript: output.lockingScript,
                        previousTransactionHash: .init(naturalOrder: hash), previousTransactionOutputIndex: UInt32(index)))
                }
            }
        }
    }
    func remove(_ bytes: Data) {
        lock.withLock {
            let hash = Self.hash(bytes); entries.removeValue(forKey: hash)
            unspents.removeAll { $0.previousTransactionHash.naturalOrder == hash }
        }
    }
    private func script(_ address: String) throws -> Data {
        OpalBase.Transaction.Output(value: 0, address: try OpalBase.Address(address)).lockingScript
    }
    private func history(_ address: String, includeUnconfirmed: Bool) throws -> [OpalBase.Network.TransactionHistoryEntry] {
        let target = try script(address)
        return lock.withLock {
            entries.compactMap { hash, entry in
                guard includeUnconfirmed || entry.height > 0 else { return nil }
                let receives = entry.transaction.outputs.contains { $0.lockingScript == target }
                let spends = entry.transaction.inputs.contains { input in
                    guard let previous = entries[input.previousTransactionHash.naturalOrder],
                          Int(input.previousTransactionOutputIndex) < previous.transaction.outputs.count else { return false }
                    return previous.transaction.outputs[Int(input.previousTransactionOutputIndex)].lockingScript == target
                }
                guard receives || spends else { return nil }
                return .init(transactionIdentifier: Self.hex(Data(hash.reversed())), blockHeight: entry.height, fee: nil)
            }
        }
    }
    func operations() -> OpalBase.WalletPublicChainOperations {
        let reader = OpalBase.Network.AddressReader(fetchBalance: { address, _ in
            let target = try self.script(address)
            return self.lock.withLock {
                let outputs = self.unspents.filter { $0.lockingScript == target }
                return .init(confirmed: outputs.reduce(0) { $0 + $1.value }, unconfirmed: 0)
            }
        }, fetchUnspentOutputs: { address, _ in
            let target = try self.script(address)
            return self.lock.withLock { self.unspents.filter { $0.lockingScript == target } }
        }, fetchHistory: { try self.history($0, includeUnconfirmed: $1) }, fetchFirstUse: { _ in nil },
            fetchMempoolTransactions: { try self.history($0, includeUnconfirmed: true).filter { $0.blockHeight == 0 } },
            fetchScriptHash: { $0 }, subscribeToAddress: { _ in AsyncThrowingStream { $0.finish() } })
        let client = OpalBase.Network.TransactionClient(broadcastTransaction: { raw in
            let bytes = try Self.data(raw)
            self.lock.withLock { self.sent.append(bytes) }
            await self.relayLatch.wait()
            if self.lock.withLock({ self.accepted }) { return Self.hex(Data(Self.hash(bytes).reversed())) }
            throw CancellationError() // Request ownership happened; the remote result is unknown.
        }, fetchConfirmations: { _ in nil }, fetchConfirmationStatus: { hash in
            let height = self.lock.withLock { self.entries[hash.naturalOrder]?.height ?? 0 }
            return .init(transactionHash: hash, transactionHeight: height > 0 ? height : nil,
                tipHeight: 10, confirmations: height > 0 ? UInt(11 - height) : 0)
        })
        return .init(addressReader: reader, transactionClient: client,
            transactionReader: .init { hash in
                guard let bytes = self.lock.withLock({ self.entries[hash.naturalOrder]?.bytes }) else { throw PaymentFailure.networkUnavailable }
                return bytes
            })
    }
    func proof(hash: OpalBase.Transaction.Hash, height: UInt32, context: BaseChainContext) -> BaseCanonicalTransactionProof? {
        let mode = lock.withLock { proofMode }
        guard mode != .absent else { return nil }
        var binding = context
        if mode == .staleView { binding.view = "stale-view" }
        let root = mode == .wrongRoot ? Data(repeating: 0x99, count: 32) : hash.naturalOrder
        return BaseCanonicalTransactionProof(context: binding, height: mode == .wrongHeight ? height + 1 : height,
            header: .init(version: 1, previousBlockHash: Data(repeating: 0, count: 32), merkleRoot: root,
                time: 1, bits: 0x1d00ffff, nonce: 0),
            inclusion: .init(blockHeight: height, position: 0, branch: []))
    }
    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: Data(SHA256.hash(data: data)))) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func data(_ hex: String) throws -> Data {
        var bytes = Data(); var offset = hex.startIndex
        while offset < hex.endIndex {
            let next = hex.index(offset, offsetBy: 2)
            guard let value = UInt8(hex[offset..<next], radix: 16) else { throw PaymentFailure.invalidRequest }
            bytes.append(value); offset = next
        }
        return bytes
    }
}
private struct BCHComposedFixture {
    let directory: URL
    let store: DurableWalletStore
    let journal: SQLiteJournal
    let anchor: BCHIntegrationAnchor
    let adapter: BaseBCHAdapter
    let account: OpalBase.Account
    let custody: WalletCustodyRecord
    let vault: WalletSeedVault
    let keys: BCHIntegrationKeys
    let chain: BCHPublicChain
    let clock: BCHIntegrationClock
    let engine: PaymentEngine
    let session: AuthorizationSession
    let peer: PeerEvidence
    let policy: AuthorityPolicy
    let funding: Data
    func state() throws -> CanonicalState { try store.continuity.inspect { $0 } }
    func record(_ id: String) throws -> PaymentRecord { try #require(try state().payments.first { $0.id == id }) }
    func request(_ key: String = String(repeating: "a", count: 32)) throws -> PaymentRequest {
        let destination = try OpalBase.Address("bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a")
        return PaymentRequest(accountID: custody.accountID, network: "mainnet", requestKey: key,
            destinationScript: OpalBase.Transaction.Output(value: 0, address: destination).lockingScript, amount: 10_000)
    }
    func prepare() async throws -> String {
        let result = try await engine.prepare(request(), session: session, connectionID: "connection", peer: peer)
        try await wait(result.payment.id, disposition: .prepared)
        return result.payment.id
    }
    func submit(_ id: String, expected: PaymentDisposition = .uncertain) async throws {
        _ = try await engine.submit(operationID: id, session: session, connectionID: "connection", peer: peer)
        try await wait(id, disposition: expected)
    }
    func wait(_ id: String, disposition: PaymentDisposition) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if try record(id).disposition == disposition { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Expected \(disposition), got \(try record(id).disposition), blocker \(try record(id).blocker ?? "none")")
        throw PaymentFailure.invalidTransition
    }
    func adapterAfterRestart() async throws -> BaseBCHAdapter {
        try await BaseBCHAdapter(account: try await freshBCHAccount(), custody: custody, vault: vault, continuity: store.continuity,
            chain: chain.operations(), clock: clock, context: { chain.context() }, canonicalProof: { hash, height, context in chain.proof(hash: hash, height: height, context: context) })
    }
}
private func bchComposedFixture(funded: Bool = true) async throws -> BCHComposedFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bch-composed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Published, permanently disposable BIP39 vector. No real wallet, network or Keychain is used.
    let mnemonic = try OpalBase.Key.Mnemonic(phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
    let keys = BCHIntegrationKeys()
    let vault = WalletSeedVault(keys: InjectedWrappingKeySource(read: { keys.read() }), accounts: BaseSeedAccountProvider())
    let custody = try await vault.protect(mnemonic: Data(mnemonic.phrase.utf8), walletID: "wallet", network: "mainnet")
    let account = try await BaseSeedAccountProvider().restoreSigningAccount(custody: custody, vault: vault)
    let clock = BCHIntegrationClock(); let chain = BCHPublicChain(clock: clock)
    let receiving = try await account.selectNextDerivedAddress(for: .receiving)
    let funding = try OpalBase.Transaction(version: 2, inputs: [.init(previousTransactionHash: .init(naturalOrder: Data(repeating: 0, count: 32)),
        previousTransactionOutputIndex: UInt32.max, unlockingScript: Data([0xA1]))], outputs: [.init(value: 50_000, address: receiving.address)], lockTime: 0).encode()
    if funded { try chain.publish(funding, height: 1) }
    let bridge = SignedPeerIdentity(teamIdentifier: "fixture", signingIdentifier: "bridge")
    let owner = SignedPeerIdentity(teamIdentifier: "fixture", signingIdentifier: "owner")
    let policy = AuthorityPolicy(bridge: bridge, owner: owner, accountIDs: [custody.accountID],
        capabilities: ["read", "prepare", "submit", "cancel", "receive", "sync"], ownerAuthenticationAge: 10_000)
    let credential = Data(repeating: 0x36, count: 32)
    let ledger = AuthorizationLedger(walletID: "wallet", network: "mainnet", generation: 1,
        grants: [.init(id: "grant", integrationID: "integration", accountIDs: [custody.accountID], capabilities: ["read", "prepare", "submit", "cancel", "receive", "sync"],
            credentialDigest: paymentDigest(credential), credentialGeneration: 1, expiresAt: nil, revoked: false)])
    var state = CanonicalState(installationID: "installation", authorization: ledger, mode: .enabled, history: .complete)
    state.custody = custody
    let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path)
    let anchor = BCHIntegrationAnchor(directory.appendingPathComponent("independent-anchor.json"))
    try journal.write(state); try anchor.write(ContinuityAnchor(committed: state.reference()))
    let store = try DurableWalletStore(directory: directory, anchor: anchor, policy: policy)
    let adapter = try await BaseBCHAdapter(account: account, custody: custody, vault: vault, continuity: store.continuity,
        chain: chain.operations(), clock: clock, context: { chain.context() }, canonicalProof: { hash, height, context in chain.proof(hash: hash, height: height, context: context) })
    let engine = try store.paymentEngine(boundary: adapter, clock: clock)
    let peer = PeerEvidence(identity: bridge, signatureValidated: true)
    let authority = AuthorizationAuthority(ledger: ledger, expectedBridgeIdentity: bridge, trustedOwnerIdentity: owner, maximumOwnerAuthenticationAge: 10_000)
    let session = try authority.authenticate(connectionID: "connection", peer: peer, credential: credential, now: 1_000)
    return BCHComposedFixture(directory: directory, store: store, journal: journal, anchor: anchor, adapter: adapter,
        account: account, custody: custody, vault: vault, keys: keys, chain: chain, clock: clock, engine: engine,
        session: session, peer: peer, policy: policy, funding: funding)
}

@Suite(.serialized) struct BaseEngineIntegrationTests {
    @Test func serviceAssemblyBindsActualBaseAdapterToProvisionedCustodyAndReopensDurableOperations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("base-service-assembly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let operations = KeychainTestOperations(), seeds = BCHAssemblySeeds(), endpoints = BCHAssemblyEndpoints()
        let clock = BCHIntegrationClock(), chain = BCHPublicChain(clock: clock)
        let factory = BCHAssemblyEffects(chain: chain, clock: clock)
        let policy = AuthorityPolicy(bridge: .init(teamIdentifier: "synthetic", signingIdentifier: "bridge"),
            owner: .init(teamIdentifier: "synthetic", signingIdentifier: "owner"), accountIDs: [],
            capabilities: Set(IntegrationScope.allCases.map(\.rawValue)), ownerAuthenticationAge: 30)
        let expectedAccount = try await freshBCHAccount()
        let funded = try await expectedAccount.selectNextDerivedAddress(for: .receiving)
        let funding = try integrationFunding(address: funded.address, byte: 0xB7)
        try chain.publish(funding, height: 1)
        let consent = BCHAssemblyConsent(clock: clock)
        let assembly = try ServiceAssembly.initializeNew(directory: directory, accessGroup: "test.OpalAgent.Service",
            accounts: seeds, operations: operations, policy: policy, effects: { try await factory.bind($0) },
            endpoints: { endpoints.make($0, handlers: $1) }, clock: clock, generateKey: { seeds.key() })
        try await assembly.start()
        #expect(factory.bindings.isEmpty)
        let owner = try await endpoints.handlers(.owner).connect(connectionID: "base-owner",
            peer: .init(identity: policy.owner, signatureValidated: true))
        guard case .createWallet(let created) = try await endpoints.handlers(.owner).owner(
            .init(call: .createWallet(network: .mainnet)), connection: owner, consent: consent).result,
              let wallet = created.wallet else { throw BCHAssemblyFailure.unexpectedResult }
        #expect(created.availability == .restricted && created.grants.isEmpty)
        let provisioned = try factory.state(directory)
        let custody = try #require(provisioned.custody)
        let account = try AccountScope(wallet: wallet, accountID: custody.accountID)
        #expect(factory.bindings == [.init(installationID: provisioned.installationID, custody: custody)])
        _ = try await endpoints.handlers(.owner).owner(.init(call: .enableWallet(wallet)),
            connection: owner, consent: consent)
        let enrollment = try EnrollmentRequest(wallet: wallet, integrationID: "base-assembly",
            accountIDs: [custody.accountID], scopes: IntegrationScope.allCases)
        guard case .enrollIntegration(let issued) = try await endpoints.handlers(.owner).owner(
            .init(call: .enrollIntegration(enrollment)), connection: owner, consent: consent).result else {
            throw BCHAssemblyFailure.unexpectedResult
        }
        let integration = try endpoints.handlers(.integration)
        let bridge = try await integration.connect(connectionID: "base-bridge",
            peer: .init(identity: policy.bridge, signatureValidated: true))
        let credential = issued.credential.withBytes { $0 }
        try await integration.authenticate(credential, connection: bridge)
        guard case .synchronizeAccount(let sync) = try await integration.capability(.init(call: .synchronizeAccount(
            .init(account: account, requestKey: RequestKey(String(repeating: "a", count: 32))))), connection: bridge).result else {
            throw BCHAssemblyFailure.unexpectedResult
        }
        _ = try await bchAssemblyOperation(sync.identity.selector, handlers: integration, connection: bridge) {
            if case .synchronization(let value) = $0 { return value.state == .completed }; return false
        }
        guard case .getBalance(let balance) = try await integration.capability(.init(call: .getBalance(account)),
            connection: bridge).result else { throw BCHAssemblyFailure.unexpectedResult }
        #expect(balance.totalSatoshis == 50_000 && balance.observation.providerID == "raw-fixture")
        let receiveRequest = KeyedAccountRequest(account: account, requestKey: try RequestKey(String(repeating: "b", count: 32)))
        guard case .createReceiveRequest(let pendingReceive) = try await integration.capability(
            .init(call: .createReceiveRequest(receiveRequest)), connection: bridge).result else {
            throw BCHAssemblyFailure.unexpectedResult
        }
        guard case .receive(let receive) = try await bchAssemblyOperation(pendingReceive.identity.selector,
            handlers: integration, connection: bridge, completed: {
                if case .receive(let value) = $0 { return value.state == .allocated }; return false
            }) else { throw BCHAssemblyFailure.unexpectedResult }
        // Confirmed history bounds eligibility; only retained service issuance advances high-water.
        #expect(receive.allocation?.index == 0 && receive.allocation?.address == funded.address.string)
        let prepare = try PreparePaymentRequest(account: account, requestKey: RequestKey(String(repeating: "c", count: 32)),
            destinationAddress: "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a", amountSatoshis: 10_000)
        guard case .preparePayment(let pendingPayment) = try await integration.capability(.init(call: .preparePayment(prepare)),
            connection: bridge).result else { throw BCHAssemblyFailure.unexpectedResult }
        guard case .payment(let payment) = try await bchAssemblyOperation(pendingPayment.identity.selector,
            handlers: integration, connection: bridge, completed: {
                if case .payment(let value) = $0 { return value.state == .prepared }; return false
            }) else { throw BCHAssemblyFailure.unexpectedResult }
        #expect(payment.preview?.amountSatoshis == 10_000)
        let naturalFundingHash = BCHPublicChain.hash(funding)
        let expectedFundingID = BCHPublicChain.hex(Data(naturalFundingHash.reversed()))
        #expect(naturalFundingHash != Data(naturalFundingHash.reversed()))
        let expectedOutpoint = Outpoint(transactionID: expectedFundingID, outputIndex: 0)
        #expect(payment.preview?.selectedInputs == [expectedOutpoint])
        guard case .listTransactions(let history) = try await integration.capability(.init(call: .listTransactions(
            .init(account: account, page: PageRequest()))), connection: bridge).result,
              case .listUTXOs(let coins) = try await integration.capability(.init(call: .listUTXOs(
                .init(account: account, page: PageRequest()))), connection: bridge).result else {
            throw BCHAssemblyFailure.unexpectedResult
        }
        #expect(history.page.items.map(\.transactionID) == [expectedFundingID])
        #expect(coins.page.items.map(\.outpoint) == [expectedOutpoint])
        #expect(coins.page.items.map(\.reservation) == [.visibleOperation(payment.identity.selector.operationID)])
        _ = try await integration.capability(.init(call: .cancelOperation(payment.identity.selector)), connection: bridge)
        let original = try factory.state(directory)
        #expect(original.allocations.first?.issuedHighWater == 0 && original.allocations.first?.issuedIndices == [0])
        #expect(original.allocations.first?.confirmedHistoryHorizon == 0 && original.payments.count == 1)
        #expect(seeds.generated == 1 && seeds.keys == 1 && factory.bindings.count == 1 && chain.sentBytes.isEmpty)
        let custodyWrites = operations.addCount
        await assembly.shutdown()
        await #expect(throws: ServiceProblem(.unavailable)) {
            try await integration.capability(.init(call: .getBalance(account)), connection: bridge)
        }

        let reopened = try ServiceAssembly.reopen(directory: directory, accessGroup: "test.OpalAgent.Service",
            accounts: seeds, operations: operations, policy: policy, effects: { try await factory.bind($0) },
            endpoints: { endpoints.make($0, handlers: $1) }, clock: clock)
        try await reopened.start()
        #expect(factory.bindings == Array(repeating: .init(installationID: original.installationID, custody: custody), count: 2))
        let reconnected = try endpoints.handlers(.integration)
        let newBridge = try await reconnected.connect(connectionID: "base-bridge-reopened",
            peer: .init(identity: policy.bridge, signatureValidated: true))
        try await reconnected.authenticate(credential, connection: newBridge)
        guard case .createReceiveRequest(let replay) = try await reconnected.capability(
            .init(call: .createReceiveRequest(receiveRequest)), connection: newBridge).result else {
            throw BCHAssemblyFailure.unexpectedResult
        }
        #expect(replay == receive)
        let retained = try factory.state(directory)
        #expect(retained.installationID == original.installationID && retained.custody == custody)
        #expect(retained.authorization == original.authorization && retained.allocations == original.allocations)
        #expect(retained.payments == original.payments && retained.requests == original.requests)
        #expect(seeds.generated == 1 && seeds.keys == 1 && operations.addCount == custodyWrites && chain.sentBytes.isEmpty)
        await reopened.shutdown()
    }

    @Test func publishedReceiveSurvivesCancelAndReopenWhileSpentHistoryStillAdvancesFrontier() async throws {
        var fixture: BCHComposedFixture? = try await bchComposedFixture(funded: false)
        let directory = try #require(fixture).directory
        defer { try? FileManager.default.removeItem(at: directory) }
        let custody = try #require(fixture).custody
        let vault = try #require(fixture).vault
        let chain = try #require(fixture).chain
        let clock = try #require(fixture).clock
        let policy = try #require(fixture).policy
        let anchor = try #require(fixture).anchor
        let peer = try #require(fixture).peer
        let published: ReceiveAllocation
        var pendingAllocationCount = -1
        let request = ReceiveRequest(accountID: custody.accountID, network: custody.network,
            requestKey: String(repeating: "b", count: 32))
        do {
            let initial = try #require(fixture)
            let held = AllocationLifecycleBoundary(adapter: initial.adapter)
            let receiver = try initial.store.receiveEngine(boundary: held, clock: clock)
            let cancelledRequest = ReceiveRequest(accountID: custody.accountID, network: custody.network,
                requestKey: String(repeating: "c", count: 32))
            let pending = Task { try await receiver.create(cancelledRequest, session: initial.session,
                connectionID: "connection", peer: peer) }
            do {
                try await held.waitUntilEntered()
                let snapshot = try await receiver.lookup(request: .init(accountID: custody.accountID, network: custody.network,
                    requestKey: cancelledRequest.requestKey), effect: .receive, session: initial.session,
                    connectionID: "connection", peer: peer)
                let cancelled = try await receiver.cancel(id: snapshot.operationID, accountID: custody.accountID,
                    network: custody.network, session: initial.session, connectionID: "connection", peer: peer)
                #expect(cancelled.state == .closed && cancelled.closeReason == .cancelled && cancelled.allocation == nil)
                await held.release()
                // Compatibility create awaits the actual retained worker, including its late completion.
                await #expect(throws: PaymentFailure.invalidTransition) { try await pending.value }
                let pendingAddressCalls = await held.addressCalls
                pendingAllocationCount = try initial.state().allocations.count
                #expect(pendingAllocationCount == 0 && pendingAddressCalls == 0)
            } catch {
                pending.cancel()
                await held.release()
                _ = await pending.result
                throw error
            }
            published = try await receiver.create(request, session: initial.session, connectionID: "connection", peer: peer)
            #expect(published.index == 0)
            let beforeCancel = try initial.state().reference()
            await #expect(throws: PaymentFailure.invalidTransition) {
                try await receiver.cancel(id: published.operationID, accountID: custody.accountID, network: custody.network,
                    session: initial.session, connectionID: "connection", peer: peer)
            }
            #expect(try initial.state().reference() == beforeCancel)
            let beforeReplay = await held.counts()
            #expect(try await receiver.create(request, session: initial.session, connectionID: "connection", peer: peer) == published)
            #expect(await held.counts() == beforeReplay)
            #expect(try initial.state().allocations.first?.issuedIndices == [0])
            #expect(try initial.state().allocations.first?.issuedHighWater == 0)
        }
        try await #require(fixture).engine.cancelLocalTransport()
        fixture = nil // All initial receive workers were joined before dropping the actual writer lease.
        let store = try DurableWalletStore(directory: directory, anchor: anchor, policy: policy)
        let account = try await BaseSeedAccountProvider().restoreSigningAccount(custody: custody, vault: vault)
        let adapter = try await BaseBCHAdapter(account: account, custody: custody, vault: vault, continuity: store.continuity,
            chain: chain.operations(), clock: clock, context: { chain.context() })
        let session = try store.integrationAuthority().authenticate(connectionID: "reopened-allocation", peer: peer,
            credential: Data(repeating: 0x36, count: 32), now: clock.read().wall)
        let receiver = try store.receiveEngine(boundary: adapter, clock: clock)
        #expect(try await receiver.create(request, session: session, connectionID: "reopened-allocation", peer: peer) == published)
        let next = try await receiver.create(.init(accountID: custody.accountID, network: custody.network,
            requestKey: String(repeating: "d", count: 32)), session: session, connectionID: "reopened-allocation", peer: peer)
        #expect(next.index == 1 && next.address != published.address)
        #expect(try store.continuity.inspect { $0.allocations.first?.issuedIndices } == [0, 1])
        #expect(try store.continuity.inspect { $0.allocations.first?.issuedHighWater } == 1)
        let deposit = try integrationFunding(address: OpalBase.Address(published.address), byte: 0xE1)
        try chain.publish(deposit, height: 2)
        let external = try OpalBase.Address("bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a")
        let spent = try OpalBase.Transaction(version: 2, inputs: [.init(
            previousTransactionHash: .init(naturalOrder: BCHPublicChain.hash(deposit)),
            previousTransactionOutputIndex: 0, unlockingScript: Data([0x51]))],
            outputs: [.init(value: 49_000, address: external)], lockTime: 0).encode()
        try chain.publish(spent, height: 3)
        chain.setView("published-address-spent")
        let publicAccount = try await BaseSeedAccountProvider().restorePublicAccount(custody: custody)
        let recovered = try await ordinaryBCHRecovery(publicAccount, chain: chain)
        let frontier = try await publicAccount.refreshConfirmedAddressFrontier(network: .mainnet, using: chain.operations())
        #expect(recovered.balance.uint64 == 0 && recovered.history.count == 2)
        #expect(frontier.receivingHighestIndex == 0 && frontier.changeHighestIndex == -1)
        let unspent = try await chain.operations().addressReader.fetchUnspentOutputs(for: published.address, tokenFilter: .include)
        let spentHistory = try await chain.operations().addressReader.fetchHistory(for: published.address, includeUnconfirmed: false)
        #expect(unspent.isEmpty && spentHistory.count == 2)
        #expect(chain.sentBytes.isEmpty)
        let retainedHighWater = try #require(store.continuity.inspect { $0.allocations.first?.issuedHighWater })
        #expect(retainedHighWater == 1)
        let finalReplay = try await receiver.create(request, session: session, connectionID: "reopened-allocation", peer: peer)
        #expect(finalReplay == published)
        try writeRecoveryStorageReceipt(name: "c3-allocation", contents: [
            "scenario": "C3", "pendingAllocationCount": pendingAllocationCount,
            "publishedIndex": published.index, "nextIndex": next.index,
            "retainedHighWater": retainedHighWater,
            "receivingConfirmedFrontier": frontier.receivingHighestIndex,
            "balanceSatoshis": recovered.balance.uint64, "historyCount": recovered.history.count,
            "unspentCount": unspent.count, "relayCount": chain.sentBytes.count,
            "sameKeyAllocationRetained": finalReplay == published
        ])
    }


    @Test func actualBaseEmptyTwentyThenConfirmedNineteenRecoversThroughThirtyNine() async throws {
        let f = try await bchComposedFixture(funded: false); defer { try? FileManager.default.removeItem(at: f.directory) }
        let receiver = try f.store.receiveEngine(boundary: f.adapter, clock: f.clock)
        var addresses: [String] = []
        for index in 0..<20 {
            let allocation = try await receiver.create(.init(accountID: f.custody.accountID, network: "mainnet",
                requestKey: String(format: "%032x", index + 1)), session: f.session, connectionID: "connection", peer: f.peer)
            #expect(allocation.index == UInt32(index)); addresses.append(allocation.address)
        }
        #expect(Set(addresses).count == 20)
        await #expect(throws: PaymentFailure.accountRestricted) {
            try await receiver.create(.init(accountID: f.custody.accountID, network: "mainnet", requestKey: String(repeating: "f", count: 32)),
                session: f.session, connectionID: "connection", peer: f.peer)
        }
        let emptyRecovery = try await freshBCHAccount()
        let empty = try await ordinaryBCHRecovery(emptyRecovery, chain: f.chain)
        #expect(empty.balance.uint64 == 0 && empty.history.isEmpty)
        let at19 = try integrationFunding(address: OpalBase.Address(addresses[19]), byte: 0xB1)
        try f.chain.publish(at19, height: 2)
        let onlyNineteenAccount = try await freshBCHAccount()
        let onlyNineteen = try await ordinaryBCHRecovery(onlyNineteenAccount, chain: f.chain)
        #expect(onlyNineteen.balance.uint64 == 50_000 && onlyNineteen.history.count == 1)
        let onlyNineteenAddresses = await onlyNineteenAccount.listDerivedAddresses(for: .receiving)
        #expect(onlyNineteenAddresses[19].address.string == addresses[19])
        for index in 20..<40 {
            let allocation = try await receiver.create(.init(accountID: f.custody.accountID, network: "mainnet",
                requestKey: String(format: "%032x", index + 1)), session: f.session, connectionID: "connection", peer: f.peer)
            #expect(allocation.index == UInt32(index)); addresses.append(allocation.address)
        }
        await #expect(throws: PaymentFailure.accountRestricted) {
            try await receiver.create(.init(accountID: f.custody.accountID, network: "mainnet", requestKey: String(repeating: "e", count: 32)),
                session: f.session, connectionID: "connection", peer: f.peer)
        }
        let before = try await f.account.refreshConfirmedAddressFrontier(network: .mainnet, using: f.chain.operations())
        #expect(before.receivingHighestIndex == 19 && before.changeHighestIndex == -1)
        let at3 = try integrationFunding(address: OpalBase.Address(addresses[3]), byte: 0xB2)
        let at39 = try integrationFunding(address: OpalBase.Address(addresses[39]), byte: 0xB3)
        try f.chain.publish(at3, height: 3); try f.chain.publish(at39, height: 4)
        let recoveredAccount = try await freshBCHAccount()
        let recovered = try await ordinaryBCHRecovery(recoveredAccount, chain: f.chain)
        #expect(recovered.balance.uint64 == 150_000 && recovered.history.count == 3)
        let restoredAddresses = await recoveredAccount.listDerivedAddresses(for: .receiving)
        #expect(restoredAddresses[39].address.string == addresses[39])
        let frontier = try await recoveredAccount.refreshConfirmedAddressFrontier(network: .mainnet, using: f.chain.operations())
        #expect(frontier.receivingHighestIndex == 39 && frontier.changeHighestIndex == -1)
        f.chain.remove(at19); f.chain.remove(at3); f.chain.setView("bridge-removed")
        let request = try f.request(String(repeating: "d", count: 32))
        await #expect(throws: PaymentFailure.accountRestricted) {
            try await f.adapter.prepare(.init(operationID: "reorg-denied", accountID: request.accountID,
                network: request.network, destinationScript: request.destinationScript, amount: request.amount,
                feeRate: request.feeRate, expiresAt: nil))
        }
        #expect(try f.state().allocations.first?.issuedHighWater == 39)
        #expect(try await f.chain.operations().addressReader.fetchUnspentOutputs(for: addresses[39], tokenFilter: .include).count == 1)
        #expect(f.chain.sentBytes.isEmpty)
    }

    @Test func ordinaryRecoveryMissesOffByOneAndMempoolDoesNotOpenConfirmedGap() async throws {
        let account = try await freshBCHAccount(); let clock = BCHIntegrationClock(); let chain = BCHPublicChain(clock: clock)
        for _ in 0...20 { _ = try await account.reserveNextReceivingDerivedAddress() }
        let addresses = await account.listDerivedAddresses(for: .receiving)
        let at20 = try integrationFunding(address: addresses[20].address, byte: 0xC1)
        try chain.publish(at20, height: 2)
        let fresh = try await freshBCHAccount()
        let missed = try await ordinaryBCHRecovery(fresh, chain: chain)
        #expect(missed.balance.uint64 == 0 && missed.history.isEmpty)
        let at19 = try integrationFunding(address: addresses[19].address, byte: 0xC2)
        try chain.publish(at19, height: 0)
        let mempoolFrontier = try await fresh.refreshConfirmedAddressFrontier(network: .mainnet, using: chain.operations())
        #expect(mempoolFrontier.receivingHighestIndex == -1)
        await #expect(throws: OpalBase.BCHSubmissionError.addressAllocationBlocked) {
            try await fresh.boundedReceivingAddress(at: 20, frontier: mempoolFrontier)
        }
        try chain.publish(at19, height: 3)
        let bridged = try await ordinaryBCHRecovery(try await freshBCHAccount(), chain: chain)
        #expect(bridged.balance.uint64 == 100_000 && bridged.history.count == 2)
        let bridgeFrontier = try await fresh.refreshConfirmedAddressFrontier(network: .mainnet, using: chain.operations())
        chain.remove(at19)
        let afterReorg = try await freshBCHAccount()
        let limited = try await ordinaryBCHRecovery(afterReorg, chain: chain)
        #expect(limited.balance.uint64 == 0 && limited.history.isEmpty)
        // A previously known directed address still has public funds, but the seed-only
        // ordinary scan cannot cross the removed bridge. No complete recovery is claimed.
        #expect(try await chain.operations().addressReader.fetchUnspentOutputs(for: addresses[20].address.string, tokenFilter: .include).count == 1)
        let contracted = try await fresh.refreshConfirmedAddressFrontier(network: .mainnet, using: chain.operations())
        #expect(contracted.receivingHighestIndex == -1)
        await #expect(throws: OpalBase.BCHSubmissionError.addressAllocationBlocked) {
            try await fresh.boundedReceivingAddress(at: 20, frontier: contracted)
        }
        await #expect(throws: OpalBase.BCHSubmissionError.staleFrontier) {
            try await fresh.boundedReceivingAddress(at: 39, frontier: bridgeFrontier)
        }
    }

    @Test func changeBranchCancellationReuseNoChangeAndSeedRecoveryStayIndependent() async throws {
        let f = try await bchComposedFixture(funded: false); defer { try? FileManager.default.removeItem(at: f.directory) }
        let receiving = await f.account.listDerivedAddresses(for: .receiving)
        try f.chain.publish(integrationFunding(address: receiving[19].address, byte: 0xD0), height: 2)
        _ = try await f.adapter.refresh(accountID: f.custody.accountID, network: "mainnet")
        let initial = try await f.account.refreshConfirmedAddressFrontier(network: .mainnet, using: f.chain.operations())
        #expect(initial.receivingHighestIndex == 19 && initial.changeHighestIndex == -1)
        let destination = try OpalBase.Address("bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a")
        for _ in 0..<25 {
            let plan = try await f.account.prepareBoundedSpend(.init(recipients: [.init(address: destination, amount: .init(10_000))]), frontier: initial)
            let review = try await plan.review(network: .mainnet)
            #expect(review.change?.derivedAddress.derivationPath.index == 0)
            try await plan.cancelReservation()
        }
        let noChange = try await f.account.prepareBoundedSpend(.init(recipients: [.init(address: destination, amount: .init(49_700))],
            shouldAllowDustDonation: true), frontier: initial)
        #expect(try await noChange.review(network: .mainnet).change == nil)
        try await noChange.cancelReservation()
        let restart = try await freshBCHAccount()
        _ = try await ordinaryBCHRecovery(restart, chain: f.chain)
        let restartFrontier = try await restart.refreshConfirmedAddressFrontier(network: .mainnet, using: f.chain.operations())
        let restartedPlan = try await restart.prepareBoundedSpend(.init(recipients: [.init(address: destination, amount: .init(10_000))]), frontier: restartFrontier)
        #expect(try await restartedPlan.review(network: .mainnet).change?.derivedAddress.derivationPath.index == 0)
        try await restartedPlan.cancelReservation()
        let changeAddresses = await f.account.listDerivedAddresses(for: .change)
        let at19 = try integrationFunding(address: changeAddresses[19].address, byte: 0xD1)
        try f.chain.publish(at19, height: 4)
        let recovered = try await freshBCHAccount()
        let snapshot = try await ordinaryBCHRecovery(recovered, chain: f.chain)
        #expect(snapshot.balance.uint64 == 100_000)
        let frontier = try await recovered.refreshConfirmedAddressFrontier(network: .mainnet, using: f.chain.operations())
        #expect(frontier.receivingHighestIndex == 19 && frontier.changeHighestIndex == 19)
        let next = try await recovered.prepareBoundedSpend(.init(recipients: [.init(address: destination, amount: .init(10_000))]), frontier: frontier)
        #expect(try await next.review(network: .mainnet).change?.derivedAddress.derivationPath.index == 20)
        try await next.cancelReservation()
        let owner = OwnerAuthenticationEvidence(peer: .init(identity: f.policy.owner, signatureValidated: true),
            authenticationSucceeded: true, authenticatedAt: f.clock.read().wall)
        let restoredDirectory = f.directory.appendingPathComponent("lost-journal")
        let restoredAnchor = BCHIntegrationAnchor(restoredDirectory.appendingPathComponent("independent-anchor.json"))
        let restoredStore = try DurableWalletStore(directory: restoredDirectory, anchor: restoredAnchor, policy: f.policy)
        let restored = try await restoredStore.ownerControl.restoreSeed(
            mnemonic: Data("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8),
            vault: f.vault, network: "mainnet", owner: owner, now: f.clock.read().wall, walletID: "restored-wallet")
        #expect(restored.mode == .restricted && restored.history == .incomplete)
        let restoredCustody = try #require(restored.custody)
        f.keys.setAvailable(false)
        let publicAccount = try await BaseSeedAccountProvider().restorePublicAccount(custody: restoredCustody)
        let publicBoundary = try await BaseBCHAdapter(account: publicAccount, custody: restoredCustody, vault: f.vault,
            continuity: restoredStore.continuity, chain: f.chain.operations(), clock: f.clock, context: { f.chain.context() })
        let discovery = try await restoredStore.ownerControl.discover(accountID: restoredCustody.accountID, network: restoredCustody.network,
            boundary: publicBoundary, owner: owner, now: f.clock.read().wall)
        #expect(discovery.balance == 100_000 && discovery.receivingHorizon == 19 && discovery.changeHorizon == 19)
        #expect(try await publicAccount.makeChainStateSnapshot().history.count == 2)
        let afterDiscovery = try restoredStore.continuity.inspect { $0 }
        #expect(afterDiscovery.mode == .restricted && afterDiscovery.history == .incomplete)
        #expect(afterDiscovery.authorization.grants.isEmpty && afterDiscovery.allocations.isEmpty)
        #expect(afterDiscovery.requests.isEmpty && afterDiscovery.payments.isEmpty)
        #expect(throws: PayloadProtectionError.wrappingKeyMissing) { try f.vault.requireAvailable(restoredCustody) }
        f.keys.setAvailable(true)
        #expect(throws: ContinuityError.incompleteHistory) {
            try restoredStore.ownerControl.enable(vault: f.vault, owner: owner, now: f.clock.read().wall)
        }
    }

    @Test func engineRejectsChangedPreparedViewBeforeAnyAllowance() async throws {
        let f = try await bchComposedFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try await f.prepare(); f.chain.setView("view-B")
        _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
        try await f.wait(id, disposition: .closed)
        #expect(try f.record(id).ordinaryAdmissions == 0 && f.record(id).attempts.isEmpty)
        #expect(f.chain.sentBytes.isEmpty)
    }

    @Test func realBaseUnsignedPreviewSigningSQLiteRetryAndRestoredBytes() async throws {
        let f = try await bchComposedFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try await f.prepare(); let prepared = try f.record(id)
        let preview = try #require(prepared.preview)
        #expect(prepared.canonicalBytes.isEmpty && f.chain.sentBytes.isEmpty)
        #expect(!preview.inputPayloads.isEmpty && !preview.unsignedTemplate.isEmpty && !preview.change.isEmpty)
        #expect(preview.selectedInputs == ["\(BCHPublicChain.hex(Data(BCHPublicChain.hash(f.funding).reversed()))):0"])
        #expect(preview.templateDigest == BCHPublicChain.hash(preview.unsignedTemplate))
        try await f.submit(id)
        let first = try f.record(id); let bytes = first.canonicalBytes
        #expect(!bytes.isEmpty && first.ordinaryAdmissions == 1 && first.attempts.count == 1)
        #expect(f.chain.sentBytes == [bytes])
        let signed = try OpalBase.Transaction.decode(from: bytes).transaction
        let unsigned = try OpalBase.Transaction.decode(from: preview.unsignedTemplate).transaction
        #expect(signed.outputs == unsigned.outputs)
        #expect(signed.inputs.allSatisfy { !$0.unlockingScript.isEmpty })
        f.clock.advance(31); await f.engine.continuePending()
        try await waitForSent(f.chain, count: 2)
        try await f.wait(id, disposition: .uncertain)
        #expect(f.chain.sentBytes == [bytes, bytes])
        let restored = try await f.adapterAfterRestart()
        let record = try f.record(id)
        _ = try await restored.observe(record)
        let payment = SignedPayment(operationID: id, bytes: bytes, digest: record.transactionDigest, transactionID: record.transactionID)
        try await restored.preflight(payment); try restored.validateAdmission(payment)
        let invocation = try await restored.handoff(payment) { actual in try actual() }
        _ = await invocation.result()
        #expect(f.chain.sentBytes == [bytes, bytes, bytes])
        #expect(try SQLiteJournal(path: f.directory.appendingPathComponent("journal.sqlite").path).read()?.payments.first?.canonicalBytes == bytes)
        #expect(try f.anchor.read()?.committed == (try f.state().reference()))
        #expect(throws: (any Error).self) { try f.store.paymentEngine(boundary: restored, clock: f.clock) }
    }

    @Test func rawExactHistoryRequiresConsistentSpentInputsAndTrackedChange() async throws {
        let f = try await bchComposedFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try await f.prepare(); f.chain.setAccepted(true); try await f.submit(id, expected: .accepted)
        let bytes = try f.record(id).canonicalBytes
        try f.chain.publish(bytes, height: 0, consumeInputs: false)
        try await f.engine.reconcile(operationID: id)
        #expect(try f.record(id).liabilityUnresolved)
        #expect(try f.record(id).terminalReason != "reconciledAccepted")
        try f.chain.publish(bytes, height: 0)
        try await f.engine.reconcile(operationID: id)
        #expect(try f.record(id).terminalReason == "reconciledAccepted")
        #expect(try !f.record(id).liabilityUnresolved)
        f.chain.remove(bytes); f.chain.setView("view-reorg")
        try await f.engine.reconcile(operationID: id)
        #expect(try f.record(id).liabilityUnresolved)
        #expect(try !f.record(id).evidenceSupported)
        #expect(try f.state().gates.contains { $0.accountID == f.custody.accountID && !$0.liabilityIDs.isEmpty })
    }

    @Test(arguments: BCHProofMode.allCases) func canonicalConflictNeedsTypedMatchingInclusionProof(_ mode: BCHProofMode) async throws {
        let f = try await bchComposedFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try await f.prepare(); try await f.submit(id)
        let record = try f.record(id)
        let sent = try OpalBase.Transaction.decode(from: record.canonicalBytes).transaction
        let destination = try OpalBase.Address("bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a")
        let conflict = try OpalBase.Transaction(version: 2, inputs: sent.inputs,
            outputs: [.init(value: 49_000, address: destination)], lockTime: 0).encode()
        try f.chain.publish(conflict, height: 5); f.chain.setProof(mode)
        try await f.engine.reconcile(operationID: id)
        let after = try f.record(id)
        #expect((after.terminalReason == "reconciledConflict") == (mode == .valid))
        #expect(after.liabilityUnresolved == (mode != .valid))
        #expect(after.canonicalBytes == record.canonicalBytes && after.ordinaryAdmissions == 1)
    }

    @Test func acceptedReceiptSurvivesFailedActualBaseCleanupAndGateStaysHeld() async throws {
        let f = try await bchComposedFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try await f.prepare(); f.chain.setAccepted(true); await f.chain.relayLatch.close()
        _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
        try await waitForSent(f.chain, count: 1)
        let bytes = try f.record(id).canonicalBytes
        try f.chain.publish(bytes, height: 0)
        _ = try await f.adapter.refresh(accountID: f.custody.accountID, network: "mainnet")
        await f.chain.relayLatch.open()
        try await f.wait(id, disposition: .accepted)
        #expect(try f.record(id).evidenceSupported && f.record(id).liabilityUnresolved)
        try await f.engine.reconcile(operationID: id)
        #expect(try f.record(id).disposition == .accepted)
        #expect(try f.record(id).blocker == "leaseCleanupFailed")
        #expect(try f.record(id).liabilityUnresolved)
        #expect(try f.state().gates.contains { $0.liabilityIDs.contains(id) })
        await #expect(throws: PaymentFailure.networkUnavailable) { try await f.adapter.dispose(operationID: id) }
        // A new account object has no process-local lease. Startup still needs the
        // retained bytes and a fresh positive observation before any durable release.
        let restartedAccount = try await freshBCHAccount()
        let restarted = try await BaseBCHAdapter(account: restartedAccount, custody: f.custody, vault: f.vault,
            continuity: f.store.continuity, chain: f.chain.operations(), clock: f.clock, context: { f.chain.context() })
        let observation = try await restarted.observe(f.record(id))
        let selected = try f.record(id).selectedInputs
        #expect(observation.exactTransactionBytes == bytes && Set(observation.spentConsistently) == Set(selected))
        try await restarted.dispose(operationID: id)
        #expect(try f.record(id).liabilityUnresolved) // Adapter restart alone never releases the durable gate.
    }

    @Test(arguments: [1, 3]) func ordinaryUnknownAndExhaustedRelaysCloseOnLaterPositiveEvidence(_ admissions: Int) async throws {
        let f = try await bchComposedFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try await f.prepare(); try await f.submit(id)
        let bytes = try f.record(id).canonicalBytes
        if admissions == 3 {
            f.clock.advance(31); await f.engine.continuePending(); try await waitForSent(f.chain, count: 2)
            try await f.wait(id, disposition: .uncertain)
            f.clock.advance(121); await f.engine.continuePending(); try await waitForSent(f.chain, count: 3)
            try await f.wait(id, disposition: .uncertain)
            #expect(try f.record(id).blocker == "automaticRelayBudgetExhausted")
        }
        try f.chain.publish(bytes, height: 0)
        try await f.engine.reconcile(operationID: id)
        let after = try f.record(id)
        #expect(after.terminalReason == "reconciledAccepted" && !after.liabilityUnresolved)
        #expect(after.ordinaryAdmissions == UInt64(admissions) && after.attempts.count == admissions)
        #expect(f.chain.sentBytes.allSatisfy { $0 == bytes } && f.chain.sentBytes.count == admissions)
        #expect(try f.state().gates.allSatisfy { !$0.liabilityIDs.contains(id) })
    }

    @Test func storeRestartReconcilesFailedCleanupAndRetainsReceiveHighWater() async throws {
        var original: BCHComposedFixture? = try await bchComposedFixture()
        let directory = try #require(original).directory
        defer { try? FileManager.default.removeItem(at: directory) }
        let issued = try await issueBCHFixtureReceives(try #require(original))
        let id = try await #require(original).prepare()
        let chain = try #require(original).chain
        chain.setAccepted(true); await chain.relayLatch.close()
        _ = try await #require(original).engine.submit(operationID: id, session: #require(original).session,
            connectionID: "connection", peer: #require(original).peer)
        try await waitForSent(chain, count: 1)
        let bytes = try #require(original).record(id).canonicalBytes
        try chain.publish(bytes, height: 0)
        _ = try await #require(original).adapter.refresh(accountID: #require(original).custody.accountID, network: "mainnet")
        await chain.relayLatch.open()
        try await #require(original).wait(id, disposition: .accepted)
        let retained = try #require(original).record(id)
        try await #require(original).engine.reconcile(operationID: id)
        #expect(try #require(original).record(id).blocker == "leaseCleanupFailed")
        let custody = try #require(original).custody
        let vault = try #require(original).vault
        let clock = try #require(original).clock
        let policy = try #require(original).policy
        let anchor = try #require(original).anchor
        let peer = try #require(original).peer
        try await #require(original).engine.cancelLocalTransport()
        original = nil
        await Task.yield()
        let store = try DurableWalletStore(directory: directory, anchor: anchor, policy: policy)
        let account = try await BaseSeedAccountProvider().restoreSigningAccount(custody: custody, vault: vault)
        let adapter = try await BaseBCHAdapter(account: account, custody: custody, vault: vault, continuity: store.continuity,
            chain: chain.operations(), clock: clock, context: { chain.context() })
        let engine = try store.paymentEngine(boundary: adapter, clock: clock)
        try await engine.reconcile(operationID: id)
        let after = try store.continuity.inspect { state in try #require(state.payments.first { $0.id == id }) }
        #expect(after.canonicalBytes == retained.canonicalBytes && after.transactionDigest == retained.transactionDigest)
        #expect(after.terminalReason == "reconciledAccepted" && !after.liabilityUnresolved)
        #expect(after.attempts == retained.attempts && chain.sentBytes.count == 1)
        let authority = try store.integrationAuthority()
        let session = try authority.authenticate(connectionID: "reconnected", peer: peer,
            credential: Data(repeating: 0x36, count: 32), now: clock.read().wall)
        let receiver = try store.receiveEngine(boundary: adapter, clock: clock)
        let next = try await receiver.create(.init(accountID: custody.accountID, network: custody.network,
            requestKey: String(repeating: "f", count: 32)), session: session, connectionID: "reconnected", peer: peer)
        #expect(next.index == 2 && !issued.contains(next.address))
        #expect(try store.continuity.inspect { $0.allocations.first?.issuedHighWater } == 2)
    }

    @Test func contradictoryExactMempoolAndCanonicalConflictCannotReleaseLiability() async throws {
        let f = try await bchComposedFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try await f.prepare(); try await f.submit(id)
        let record = try f.record(id)
        try f.chain.publish(record.canonicalBytes, height: 0)
        let sent = try OpalBase.Transaction.decode(from: record.canonicalBytes).transaction
        let destination = try OpalBase.Address("bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a")
        let conflict = try OpalBase.Transaction(version: 2, inputs: sent.inputs,
            outputs: [.init(value: 49_000, address: destination)], lockTime: 0).encode()
        try f.chain.publish(conflict, height: 5)
        await #expect(throws: PaymentFailure.networkUnavailable) { try await f.engine.reconcile(operationID: id) }
        #expect(try f.record(id).liabilityUnresolved && !f.record(id).evidenceSupported)
        #expect(try f.record(id).blocker == "networkUnavailable")
    }

    @Test func wrappingKeyAndProviderViewAreCheckedBeforeAdmissionAndAtActualHandoff() async throws {
        let f = try await bchComposedFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try await f.prepare()
        f.keys.setAvailable(false)
        _ = try await f.engine.submit(operationID: id, session: f.session, connectionID: "connection", peer: f.peer)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try f.record(id).ordinaryAdmissions == 0)
        #expect(f.chain.sentBytes.isEmpty)
        f.keys.setAvailable(true)
        let preview = try #require(try f.record(id).preview)
        let signed = try await f.adapter.sign(preview)
        try await f.adapter.preflight(signed)
        f.chain.setView("view-B")
        #expect(throws: PaymentFailure.staleContext) { try f.adapter.validateAdmission(signed) }
        await #expect(throws: PaymentFailure.staleContext) { try await f.adapter.preflight(signed) }
        #expect(try f.record(id).ordinaryAdmissions == 0 && f.chain.sentBytes.isEmpty)
        f.chain.setView("view-A")
        try await f.adapter.preflight(signed)
        await #expect(throws: PaymentFailure.noHandoff) {
            try await f.adapter.handoff(signed) { actual in
                f.chain.setView("view-B")
                return try actual()
            }
        }
        #expect(f.chain.sentBytes.isEmpty)
        f.chain.setView("view-A")
        try await f.adapter.preflight(signed)
        await #expect(throws: PaymentFailure.staleContext) {
            try await f.adapter.handoff(signed) { actual in
                var invocation = try actual()
                invocation.id = "invalid-returned-handle"
                return invocation
            }
        }
        try await waitForSent(f.chain, count: 1)
        // An invocation that already began cannot be reported as affirmative no-handoff.
        #expect(f.chain.sentBytes == [signed.bytes])
    }
}
private func waitForSent(_ chain: BCHPublicChain, count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
        if chain.sentBytes.count >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Missing transport invocation \(count)"); throw PaymentFailure.unavailable
}

private func freshBCHAccount() async throws -> OpalBase.Account {
    let mnemonic = try OpalBase.Key.Mnemonic(phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
    let wallet = try OpalBase.Wallet(mnemonic: mnemonic, passphrase: "", purpose: .bip44, coinType: .bitcoinCash)
    try await wallet.addAccount(unhardenedIndex: 0)
    return try await wallet.fetchAccount(at: 0)
}
private func ordinaryBCHRecovery(_ account: OpalBase.Account, chain: BCHPublicChain) async throws -> OpalBase.Account.ChainStateSnapshot {
    let sync = OpalBase.WalletBlockchainSyncInteractor(readOnlyAccount: account, publicChain: chain.operations())
    _ = try await sync.refreshBalances(includeUnconfirmedHistory: false)
    _ = try await sync.refreshTransactionHistory(includeUnconfirmed: false)
    _ = try await sync.refreshUTXOSet()
    _ = try await sync.refreshTransactionConfirmations()
    return try await account.makeChainStateSnapshot()
}
private func integrationFunding(address: OpalBase.Address, byte: UInt8) throws -> Data {
    try OpalBase.Transaction(version: 2, inputs: [.init(previousTransactionHash: .init(naturalOrder: Data(repeating: 0, count: 32)),
        previousTransactionOutputIndex: UInt32.max, unlockingScript: Data([byte]))], outputs: [.init(value: 50_000, address: address)], lockTime: 0).encode()
}

private func issueBCHFixtureReceives(_ fixture: BCHComposedFixture) async throws -> [String] {
    let receiver = try fixture.store.receiveEngine(boundary: fixture.adapter, clock: fixture.clock)
    var addresses: [String] = []
    for index in 0..<2 {
        let allocation = try await receiver.create(.init(accountID: fixture.custody.accountID, network: fixture.custody.network,
            requestKey: String(format: "%032x", index + 1)), session: fixture.session, connectionID: "connection", peer: fixture.peer)
        addresses.append(allocation.address)
    }
    return addresses
}

/// Holds one refresh before delegating to the actual Base adapter; no snapshot,
/// address or allocation outcome is supplied by this synchronization helper.
private actor AllocationLifecycleBoundary: AccountChainBoundary {
    let adapter: BaseBCHAdapter
    private var entered = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var refreshCalls = 0
    private(set) var addressCalls = 0
    init(adapter: BaseBCHAdapter) { self.adapter = adapter }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        refreshCalls += 1
        if !opened {
            entered = true
            await withCheckedContinuation { waiter = $0 }
        }
        return try await adapter.refresh(accountID: accountID, network: network)
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        addressCalls += 1
        return try await adapter.receivingAddress(at: index, accountID: accountID, network: network)
    }
    func release() { opened = true; let saved = waiter; waiter = nil; saved?.resume() }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered {
            guard ContinuousClock.now < deadline else { throw PaymentFailure.invalidTransition }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func counts() -> [Int] { [refreshCalls, addressCalls] }
}

private enum BCHAssemblyFailure: Error { case unexpectedResult, timeout }

/// The fixed published BIP39 vector supplies entropy only; Base derives and reopens custody.
private final class BCHAssemblySeeds: SeedAccountProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var generationCount = 0
    private var keyCount = 0
    var generated: Int { lock.withLock { generationCount } }
    var keys: Int { lock.withLock { keyCount } }
    func generateMnemonic() throws -> Data {
        lock.withLock { generationCount += 1 }
        return Data("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8)
    }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        try await BaseSeedAccountProvider().deriveAccount(mnemonic: mnemonic, network: network)
    }
    func key() -> SymmetricKey {
        lock.withLock { keyCount += 1 }
        return SymmetricKey(data: Data(repeating: 0xB7, count: 32))
    }
}

private struct BCHAssemblyConsent: OwnerConsentProvider {
    let clock: BCHIntegrationClock
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        .init(challenge: challenge, authenticatedAt: clock.read().wall)
    }
}

/// Records values and a weak reader; assertions never compete with the live SQLite writer.
private final class BCHAssemblyEffects: @unchecked Sendable {
    struct Binding: Equatable { let installationID: String; let custody: WalletCustodyRecord }
    let chain: BCHPublicChain
    let clock: BCHIntegrationClock
    private let lock = NSLock()
    private var recorded: [Binding] = []
    private weak var continuity: ContinuityCoordinator?
    var bindings: [Binding] { lock.withLock { recorded } }
    init(chain: BCHPublicChain, clock: BCHIntegrationClock) { self.chain = chain; self.clock = clock }
    func state(_ directory: URL) throws -> CanonicalState {
        if let coordinator = lock.withLock({ continuity }) { return try coordinator.inspect { $0 } }
        return try bchAssemblyState(directory)
    }
    func bind(_ context: ServiceCustodyContext) async throws -> ServiceEffectBoundaries {
        let binding = try context.continuity.inspect { state in
            guard state.custody == context.custody,
                  state.authorization.walletID == context.custody.walletID else {
                throw BCHAssemblyFailure.unexpectedResult
            }
            return Binding(installationID: state.installationID, custody: context.custody)
        }
        let account = try await BaseSeedAccountProvider().restoreSigningAccount(custody: context.custody, vault: context.vault)
        let adapter = try await BaseBCHAdapter(account: account, custody: context.custody, vault: context.vault,
            continuity: context.continuity, chain: chain.operations(), clock: clock, context: { [chain] in chain.context() },
            canonicalProof: { [chain] hash, height, view in chain.proof(hash: hash, height: height, context: view) })
        lock.withLock { recorded.append(binding); continuity = context.continuity }
        return ServiceEffectBoundaries(payments: adapter, chain: adapter)
    }
}

/// Captures shared dispatch handlers without constructing or qualifying any native listener.
private final class BCHAssemblyEndpoints: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NativeChannel: ServiceEndpointHandlers] = [:]
    func make(_ channel: NativeChannel, handlers: ServiceEndpointHandlers) -> any ServiceEndpointHost {
        lock.withLock { values[channel] = handlers }
        return BCHAssemblyEndpoint()
    }
    func handlers(_ channel: NativeChannel) throws -> ServiceEndpointHandlers {
        try lock.withLock { try #require(values[channel]) }
    }
}
private struct BCHAssemblyEndpoint: ServiceEndpointHost {
    func activate() throws {}
    func invalidate() {}
}

private func bchAssemblyState(_ directory: URL) throws -> CanonicalState {
    let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path, createIfMissing: false)
    return try #require(try journal.read())
}

private func bchAssemblyOperation(_ selector: OperationSelector, handlers: ServiceEndpointHandlers,
                                  connection: ServiceConnection,
                                  completed: (OperationProjection) -> Bool) async throws -> OperationProjection {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
        guard case .getOperation(let operation) = try await handlers.capability(
            .init(call: .getOperation(.operation(selector))), connection: connection).result else {
            throw BCHAssemblyFailure.unexpectedResult
        }
        if completed(operation) { return operation }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Composed Base operation did not finish before its deadline")
    throw BCHAssemblyFailure.timeout
}
