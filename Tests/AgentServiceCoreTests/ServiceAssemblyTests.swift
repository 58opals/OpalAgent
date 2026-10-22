import AgentNativeIPC
import AgentValues
import CryptoKit
import Foundation
import Security
import Testing
@testable import AgentServiceCore

// These hosts never construct a native listener. Real SQLite and the shared assembly own
// the behavior; only custody operations, peer/consent evidence and network work are injected.
struct ServiceAssemblyTests {
    @Test func ownerProvisioningRoleSeparatedAvailabilityAndRestartShareOneDurableWallet() async throws {
        let f = AssemblyFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        #expect(await assembly.phase == .running)
        #expect(f.hosts.channels == [.owner, .integration, .appleAutomation])
        let owner = try await f.connect(.owner)
        let bridge = try await f.connect(.integration)
        await #expect(throws: (any Error).self) {
            try await f.handlers(.integration).authenticate(Data(repeating: 1, count: 32), connection: bridge)
        }
        await #expect(throws: (any Error).self) {
            try await f.handlers(.integration).connect(connectionID: "wrong-role", peer: f.peer(.owner))
        }
        let wallet = try await f.createEnabled(owner)
        let mcp = try await f.enroll(wallet, owner: owner)
        let apple = try await f.enroll(wallet, owner: owner, profile: .appleAutomation)
        try await f.handlers(.integration).authenticate(mcp.credential.withBytes { $0 }, connection: bridge)
        let automation = try await f.connect(.appleAutomation)
        await #expect(throws: (any Error).self) {
            try await f.handlers(.appleAutomation).authenticate(mcp.credential.withBytes { $0 }, connection: automation)
        }
        try await f.handlers(.appleAutomation).authenticate(apple.credential.withBytes { $0 }, connection: automation)
        for channel in [NativeChannel.integration, .appleAutomation] {
            let connection = channel == .integration ? bridge : automation
            guard case .listWallets(let page) = try await f.capability(.listWallets(PageRequest()),
                connection: connection, channel: channel) else { throw AssemblyFailure.unexpectedResult }
            #expect(page.items.map(\.scope) == [wallet])
        }
        await #expect(throws: (any Error).self) {
            try await f.handlers(.owner).owner(.init(call: .status), connection: bridge, consent: f.consent)
        }
        await #expect(throws: (any Error).self) {
            try await f.handlers(.appleAutomation).capability(.init(call: .listWallets(PageRequest())), connection: bridge)
        }
        let account = try AccountScope(wallet: wallet, accountID: "assembly-account")
        guard case .synchronizeAccount(let sync) = try await f.capability(.synchronizeAccount(
            KeyedAccountRequest(account: account, requestKey: f.key("d"))), connection: bridge) else {
            throw AssemblyFailure.unexpectedResult
        }
        try await assemblyEventually {
            try f.state().requests.first { $0.id == sync.identity.selector.operationID }?.disposition == .closed
        }
        let readEffects = f.effects.counts, keyReads = f.operations.wrappingKeyReads, derivations = f.seeds.derived
        for readiness in [AccountReadiness(state: .ready), .init(state: .blocked, blockers: [.keyUnavailable]),
                          .init(state: .blocked, blockers: [.networkUnavailable])] {
            f.readiness.set(readiness)
            guard case .listAccounts(let accounts) = try await f.capability(.listAccounts(
                WalletPageRequest(wallet: wallet, page: PageRequest())), connection: bridge),
                  case .getSyncStatus(let syncStatus) = try await f.capability(.getSyncStatus(account), connection: bridge),
                  case .getBalance(let balance) = try await f.capability(.getBalance(account), connection: bridge) else {
                throw AssemblyFailure.unexpectedResult
            }
            #expect(accounts.page.items.map(\.readiness) == [readiness])
            #expect(syncStatus.readiness == readiness && balance.readiness == readiness)
            #expect(balance.totalSatoshis == 0 && syncStatus.observation?.fresh == true)
        }
        #expect(f.effects.counts == readEffects && f.operations.wrappingKeyReads == keyReads && f.seeds.derived == derivations)
        f.readiness.set(.unavailable)
        guard case .createReceiveRequest(let receive) = try await f.capability(.createReceiveRequest(
            KeyedAccountRequest(account: account, requestKey: f.key("a"))), connection: bridge) else {
            throw AssemblyFailure.unexpectedResult
        }
        try await assemblyEventually { try f.state().allocations.first?.issuedHighWater == 0 }
        let original = try f.state()
        let oldHandlers = try f.handlers(.integration)
        let custody = try #require(original.custody)
        #expect(f.seeds.generated == 1 && f.seeds.keys == 1)
        await assembly.shutdown()
        #expect(await assembly.phase == .stopped)
        #expect(f.hosts.invalidations.allSatisfy { $0 == 1 })
        await #expect(throws: (any Error).self) { try await assembly.start() }
        await #expect(throws: (any Error).self) {
            try await oldHandlers.capability(.init(call: .listWallets(PageRequest())), connection: bridge)
        }

        let reopened = try f.reopen()
        try await reopened.start()
        let newOwner = try await f.connect(.owner)
        guard case .status(let status) = try await f.owner(.status, connection: newOwner) else {
            throw AssemblyFailure.unexpectedResult
        }
        let expectedGrants = [mcp.grant.selector, apple.grant.selector].sorted { $0.grantID < $1.grantID }
        #expect(status.wallet == wallet && status.grants.map(\.selector) == expectedGrants)
        await #expect(throws: (any Error).self) {
            try await f.owner(.createWallet(network: .mainnet), connection: newOwner)
        }
        let newBridge = try await f.connect(.integration)
        try await f.handlers(.integration).authenticate(mcp.credential.withBytes { $0 }, connection: newBridge)
        await #expect(throws: (any Error).self) {
            try await f.handlers(.integration).capability(.init(call: .listWallets(PageRequest())), connection: bridge)
        }
        guard case .getOperation(.receive(let retained)) = try await f.capability(.getOperation(.operation(
            OperationSelector(account: account, operationID: receive.identity.selector.operationID))), connection: newBridge) else {
            throw AssemblyFailure.unexpectedResult
        }
        #expect(retained.identity == receive.identity && retained.state == .allocated && retained.allocation?.index == 0)
        let after = try f.state()
        #expect(after.installationID == original.installationID && after.custody == custody)
        #expect(after.authorization == original.authorization && after.allocations == original.allocations)
        #expect(f.seeds.generated == 1 && f.seeds.keys == 1)
        #expect(f.effects.counts.sign == 0 && f.effects.counts.handoff == 0)
        await reopened.shutdown()
    }

    @Test(arguments: AssemblyStartFailure.allCases)
    private func partialStartInvalidatesEveryConstructedHostAndReleasesItsWriter(_ failure: AssemblyStartFailure) async throws {
        let f = AssemblyFixture(failure: failure)
        defer { f.remove() }
        let assembly = try f.fresh()
        await #expect(throws: AssemblyFailure.injected) { try await assembly.start() }
        #expect(await assembly.phase == .stopped)
        #expect(f.hosts.channels == failure.expectedFactories)
        #expect(f.hosts.invalidations == Array(repeating: 1, count: failure.constructedHosts))
        for host in f.hosts.constructed {
            await #expect(throws: (any Error).self) {
                try await host.handlers.connect(connectionID: "after-failure", peer: f.peer(host.channel))
            }
        }
        let retainedFiles = try f.files()
        #expect(f.operations.backend.calls.isEmpty && f.seeds.generated == 0 && f.seeds.keys == 0)
        #expect(throws: DurableWalletStoreError.initializationExists) { try f.fresh() }
        #expect(try f.files() == retainedFiles)
        let lease = try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
        withExtendedLifetime(lease) {}
        await assembly.shutdown()
        #expect(f.hosts.invalidations.allSatisfy { $0 == 1 })
    }

    @Test func failedCustodyReopenConstructsNoEndpointsAndNeverRegeneratesAKey() async throws {
        let f = AssemblyFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let owner = try await f.connect(.owner)
        _ = try await f.createEnabled(owner)
        await assembly.shutdown()
        let files = try f.files()
        let hostCount = f.hosts.channels.count
        let writes = f.operations.backend.addCount + f.operations.backend.updateCount
        f.operations.hideWrappingKey()
        #expect(throws: (any Error).self) { try f.reopen() }
        #expect(f.hosts.channels.count == hostCount)
        #expect(try f.files() == files)
        #expect(f.operations.backend.addCount + f.operations.backend.updateCount == writes)
        #expect(f.seeds.generated == 1 && f.seeds.keys == 1)
    }

    @Test func asynchronousOwnedEffectFactoryBindsOnceAcrossProvisioningAndConcurrentAuthentication() async throws {
        let f = AssemblyFixture()
        defer { f.remove() }
        let factory = AssemblyFactory(effects: f.effects)
        await factory.gate.arm()
        defer { Task { await factory.gate.release() } }
        let assembly = try f.fresh(factory: factory)
        try await assembly.start()
        let owner = try await f.connect(.owner)
        let creation = Task { try await f.owner(.createWallet(network: .mainnet), connection: owner) }
        try await assemblyEventually { await factory.gate.hasEntered }
        let custody = try #require(try f.state().custody)
        let wallet = try WalletScope(walletID: custody.walletID, network: .mainnet)
        _ = try await f.owner(.enableWallet(wallet), connection: owner)
        let issued = try await f.enroll(wallet, owner: owner)
        let first = try await f.connect(.integration), second = try await f.connect(.integration)
        let wrappingReads = f.operations.wrappingKeyReads
        let firstAuthentication = Task {
            try await f.handlers(.integration).authenticate(issued.credential.withBytes { $0 }, connection: first)
        }
        let secondAuthentication = Task {
            try await f.handlers(.integration).authenticate(issued.credential.withBytes { $0 }, connection: second)
        }
        // Each auth has passed its owned-custody read and is waiting on the still-paused
        // factory. This proves overlap rather than merely launching two later callers.
        try await assemblyEventually { f.operations.wrappingKeyReads >= wrappingReads + 2 }
        #expect(factory.custodies == [custody])
        #expect(f.effects.counts == AssemblyEffects.Counts())
        await factory.gate.release()
        guard case .createWallet(let created) = try await creation.value else { throw AssemblyFailure.unexpectedResult }
        #expect(created.wallet == wallet)
        try await firstAuthentication.value; try await secondAuthentication.value
        for connection in [first, second] {
            guard case .listWallets(let wallets) = try await f.capability(.listWallets(PageRequest()), connection: connection) else {
                throw AssemblyFailure.unexpectedResult
            }
            #expect(wallets.items.map(\.scope) == [wallet])
        }
        #expect(factory.custodies == [custody] && f.seeds.generated == 1 && f.seeds.keys == 1)
        await assembly.shutdown()
    }

    @Test(arguments: [AssemblyBindingOutcome.stop, .failure])
    private func pendingReopenFactoryRetainsWriterAndCannotPublishAfterStopOrFailure(_ outcome: AssemblyBindingOutcome) async throws {
        let f = AssemblyFixture()
        defer { f.remove() }
        let original = try f.fresh()
        try await original.start()
        let owner = try await f.connect(.owner)
        _ = try await f.createEnabled(owner)
        await original.shutdown()
        let state = try f.state(), files = try f.files(), hosts = f.hosts.channels.count
        let effects = f.effects.counts
        let factory = AssemblyFactory(effects: f.effects, fail: outcome == .failure)
        await factory.gate.arm()
        defer { Task { await factory.gate.release() } }
        let reopened = try f.reopen(factory: factory)
        let starting = Task { try await reopened.start() }
        try await assemblyEventually { await factory.gate.hasEntered }
        #expect(await reopened.phase == .starting)
        #expect(factory.custodies == [try #require(state.custody)])
        #expect(f.hosts.channels.count == hosts)
        #expect(throws: StoreLockFailure.busy) {
            try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
        }
        if outcome == .stop {
            let done = AssemblyFlag()
            let stop = Task { await reopened.shutdown(); done.set() }
            try await assemblyEventually { await reopened.phase == .stopping }
            starting.cancel()
            #expect(!done.value)
            await factory.gate.release()
            await stop.value
            #expect(done.value)
            // Stop completion itself proves drainage, before joining the start caller.
            let lease = try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
            withExtendedLifetime(lease) {}
            await #expect(throws: (any Error).self) { try await starting.value }
        } else {
            await factory.gate.release()
            await #expect(throws: AssemblyFailure.injected) { try await starting.value }
        }
        #expect(await reopened.phase == .stopped)
        await #expect(throws: ServiceProblem(.unavailable)) { try await reopened.start() }
        #expect(factory.custodies.count == 1 && f.hosts.channels.count == hosts)
        #expect(f.effects.counts == effects && f.seeds.generated == 1 && f.seeds.keys == 1)
        #expect(try f.state() == state && f.files() == files)
        let lease = try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
        withExtendedLifetime(lease) {}
    }

    @Test func shutdownInvalidatesSuspendedOwnerConsentAndEveryConcurrentStopWaitsForDrain() async throws {
        let f = AssemblyFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let owner = try await f.connect(.owner)
        await f.consent.gate.arm()
        let pending = Task { try await f.owner(.createWallet(network: .mainnet), connection: owner) }
        defer { Task { await f.consent.gate.release() } }
        try await assemblyEventually { await f.consent.gate.hasEntered }
        let firstDone = AssemblyFlag(), secondDone = AssemblyFlag()
        let first = Task { await assembly.shutdown(); firstDone.set() }
        try await assemblyEventually { await assembly.phase == .stopping }
        let second = Task { await assembly.shutdown(); secondDone.set() }
        second.cancel()
        #expect(!firstDone.value && !secondDone.value)
        #expect(throws: StoreLockFailure.busy) {
            try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
        }
        await #expect(throws: (any Error).self) { try await f.connect(.owner) }
        await #expect(throws: (any Error).self) { try await assembly.start() }
        await f.consent.gate.release()
        await #expect(throws: ServiceProblem(.unavailable)) { try await pending.value }
        await first.value; await second.value
        #expect(firstDone.value && secondDone.value)
        #expect(await assembly.phase == .stopped)
        #expect(f.seeds.generated == 0 && f.seeds.keys == 0 && f.operations.backend.addCount == 0)
        #expect(f.hosts.invalidations.allSatisfy { $0 == 1 })
        let lease = try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
        withExtendedLifetime(lease) {}
    }

    @Test func physicalInvalidationRetiresConsentedOwnerBeforeSuspendedDerivationResumes() async throws {
        let f = AssemblyFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let owner = try await f.connect(.owner)
        let originalFiles = try f.files()
        await f.seeds.derivation.arm()
        let pending = Task { try await f.owner(.createWallet(network: .mainnet), connection: owner) }
        defer { Task { await f.seeds.derivation.release() } }
        try await assemblyEventually { await f.seeds.derivation.hasEntered }
        #expect(f.seeds.generated == 1 && f.seeds.keys == 0)
        // Model the native adapter's synchronous invalidation. The assembly actor has
        // deliberately not received its later map-removal message yet, and this seed
        // provider ignores cancellation, so task cancellation alone cannot fence custody.
        owner.invalidate()
        pending.cancel()
        await f.seeds.derivation.release()
        await #expect(throws: ServiceProblem(.unavailable)) { try await pending.value }
        #expect(try SQLiteJournal(path: f.directory.appendingPathComponent("journal.sqlite").path,
            createIfMissing: false).read() == nil)
        #expect(f.operations.backend.addCount == 0 && f.operations.backend.updateCount == 0)
        #expect(f.operations.backend.storedItems.isEmpty && f.seeds.keys == 0)
        #expect(try f.files() == originalFiles)
        #expect(await assembly.phase == .running)
        try await f.handlers(.owner).disconnect(owner)
        await assembly.shutdown()
        let retainedFiles = try f.files()
        #expect(throws: (any Error).self) { try f.reopen() }
        #expect(throws: DurableWalletStoreError.initializationExists) { try f.fresh() }
        #expect(try f.files() == retainedFiles)
        #expect(f.operations.backend.addCount == 0 && f.operations.backend.updateCount == 0)
        #expect(f.seeds.generated == 1 && f.seeds.keys == 0)
    }

    @Test(arguments: [AssemblyBackground.preparation, .receive, .address])
    private func shutdownRetainsWriterUntilEngineBackgroundWorkEndsAndRejectsNewPublicAdmission(_ background: AssemblyBackground) async throws {
        let f = AssemblyFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let owner = try await f.connect(.owner)
        let wallet = try await f.createEnabled(owner)
        let issued = try await f.enroll(wallet, owner: owner)
        let bridge = try await f.connect(.integration)
        try await f.handlers(.integration).authenticate(issued.credential.withBytes { $0 }, connection: bridge)
        let account = try AccountScope(wallet: wallet, accountID: "assembly-account")
        let gate: AssemblyGate
        switch background {
        case .preparation: gate = f.effects.preparation
        case .receive: gate = f.effects.refresh
        case .address: gate = f.effects.address
        }
        await gate.arm()
        defer { Task { await gate.release() } }
        let operationID: String
        if background == .preparation {
            guard case .preparePayment(let operation) = try await f.capability(.preparePayment(f.payment(account)), connection: bridge) else {
                throw AssemblyFailure.unexpectedResult
            }
            operationID = operation.identity.selector.operationID
        } else {
            guard case .createReceiveRequest(let operation) = try await f.capability(.createReceiveRequest(
                KeyedAccountRequest(account: account, requestKey: f.key("b"))), connection: bridge) else {
                throw AssemblyFailure.unexpectedResult
            }
            operationID = operation.identity.selector.operationID
        }
        try await assemblyEventually { await gate.hasEntered }
        let done = AssemblyFlag()
        let stop = Task { await assembly.shutdown(); done.set() }
        try await assemblyEventually { await assembly.phase == .stopping }
        #expect(!done.value)
        #expect(throws: StoreLockFailure.busy) {
            try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
        }
        await #expect(throws: (any Error).self) {
            try await f.capability(.getSyncStatus(account), connection: bridge)
        }
        await gate.release()
        await stop.value
        #expect(done.value)
        #expect(await assembly.phase == .stopped)
        #expect(f.effects.counts.sign == 0 && f.effects.counts.handoff == 0)
        // Assembly .stopping closes public admission first. Already admitted work can
        // finish before its engine reaches terminal closure; either factual result stays.
        let addresses = f.effects.counts.address
        #expect(addresses <= (background == .preparation ? 0 : 1))
        if background == .address { #expect(addresses == 1) }
        let before = try f.state()
        #expect(before.requests.contains { $0.id == operationID || $0.paymentID == operationID })
        if addresses == 1 { #expect(before.allocations.first?.issuedHighWater == 0) }
        let reopened = try f.reopen()
        try await reopened.start()
        let after = try f.state()
        #expect(after.authorization == before.authorization && after.custody == before.custody)
        #expect(after.allocations == before.allocations)
        #expect(after.requests.contains { $0.id == operationID || $0.paymentID == operationID })
        #expect(f.seeds.generated == 1 && f.seeds.keys == 1)
        #expect(f.effects.counts.address == addresses)
        await reopened.shutdown()
    }

    @Test(arguments: [AssemblyRelayStage.handoffReturn, .result])
    private func shutdownDrainsHandedOffResultAndRestartPreservesItsAmbiguousLiability(_ stage: AssemblyRelayStage) async throws {
        let f = AssemblyFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        try await assembly.start()
        let owner = try await f.connect(.owner)
        let wallet = try await f.createEnabled(owner)
        let issued = try await f.enroll(wallet, owner: owner)
        let bridge = try await f.connect(.integration)
        try await f.handlers(.integration).authenticate(issued.credential.withBytes { $0 }, connection: bridge)
        let account = try AccountScope(wallet: wallet, accountID: "assembly-account")
        guard case .preparePayment(let prepared) = try await f.capability(.preparePayment(f.payment(account)), connection: bridge) else {
            throw AssemblyFailure.unexpectedResult
        }
        let id = prepared.identity.selector.operationID
        try await assemblyEventually { try f.state().payments.first { $0.id == id }?.disposition == .prepared }
        await f.effects.result.arm()
        defer { Task { await f.effects.result.release() } }
        if stage == .handoffReturn { await f.effects.handoffReturn.arm() }
        defer { Task { await f.effects.handoffReturn.release() } }
        _ = try await f.capability(.submitPayment(OperationSelector(account: account, operationID: id)), connection: bridge)
        if stage == .handoffReturn {
            try await assemblyEventually { await f.effects.handoffReturn.hasEntered }
            #expect(await f.effects.result.hasEntered == false)
        } else {
            try await assemblyEventually { await f.effects.result.hasEntered }
        }
        let admitted = try #require(try f.state().payments.first { $0.id == id })
        #expect(admitted.attempts.count == 1 && admitted.liabilityUnresolved && !admitted.canonicalBytes.isEmpty)
        let done = AssemblyFlag()
        let stop = Task { await assembly.shutdown(); done.set() }
        try await assemblyEventually { await assembly.phase == .stopping }
        #expect(!done.value)
        #expect(throws: StoreLockFailure.busy) {
            try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
        }
        if stage == .handoffReturn {
            // A handed-off invocation returns late and installs a new background result
            // task while shutdown is already draining. Both must keep the writer alive.
            await f.effects.handoffReturn.release()
            try await assemblyEventually { await f.effects.result.hasEntered }
            #expect(!done.value)
            #expect(throws: StoreLockFailure.busy) {
                try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
            }
        }
        await f.effects.result.release()
        await stop.value
        let before = try f.state()
        let uncertain = try #require(before.payments.first { $0.id == id })
        #expect(uncertain.disposition == .uncertain && uncertain.liabilityUnresolved)
        #expect(uncertain.attempts == admitted.attempts)
        #expect(uncertain.evidence.contains { $0.source == "synthetic-assembly" && $0.valid })
        #expect(uncertain.canonicalBytes == admitted.canonicalBytes && uncertain.transactionDigest == admitted.transactionDigest)
        #expect(before.gates.contains { $0.accountID == account.accountID && $0.liabilityIDs.contains(id) })
        #expect(f.effects.counts.sign == 1 && f.effects.counts.handoff == 1)
        let observations = f.effects.counts.observe
        let reopened = try f.reopen()
        try await reopened.start()
        try await reopened.continuePending()
        let after = try f.state()
        let resumed = try #require(after.payments.first { $0.id == id })
        #expect(resumed.id == uncertain.id && resumed.request == uncertain.request)
        #expect(resumed.canonicalBytes == uncertain.canonicalBytes && resumed.transactionDigest == uncertain.transactionDigest)
        #expect(resumed.attempts == uncertain.attempts && resumed.liabilityUnresolved && resumed.disposition == .uncertain)
        #expect(resumed.observationSequence > uncertain.observationSequence && resumed.evidence.count > uncertain.evidence.count)
        #expect(f.effects.counts.observe > observations && after.gates == before.gates)
        #expect(after.authorization == before.authorization && after.custody == before.custody)
        #expect(f.effects.counts.sign == 1 && f.effects.counts.handoff == 1)
        f.clock.advance(30)
        try await reopened.continuePending()
        try await assemblyEventually {
            guard let payment = try f.state().payments.first(where: { $0.id == id }) else { return false }
            return payment.attempts.count == 2 && payment.disposition == .uncertain
        }
        try await reopened.continuePending()
        #expect(f.effects.counts.handoff == 2)
        f.clock.advance(120)
        try await reopened.continuePending()
        try await assemblyEventually {
            guard let payment = try f.state().payments.first(where: { $0.id == id }) else { return false }
            return payment.attempts.count == 3 && payment.disposition == .uncertain
        }
        f.clock.advance(1_000)
        try await reopened.continuePending()
        let bounded = try #require(try f.state().payments.first { $0.id == id })
        #expect(bounded.attempts.count == 3 && bounded.ordinaryAdmissions == 3 && bounded.liabilityUnresolved)
        #expect(bounded.canonicalBytes == uncertain.canonicalBytes && bounded.transactionDigest == uncertain.transactionDigest)
        #expect(f.effects.counts.sign == 1 && f.effects.counts.handoff == 3)
        #expect(f.seeds.generated == 1 && f.seeds.keys == 1)
        await reopened.shutdown()
    }

    @Test func cancelledStartPublishesNoHostsAndCannotBeRestarted() async throws {
        let f = AssemblyFixture()
        defer { f.remove() }
        let assembly = try f.fresh()
        let start = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await assembly.start()
        }
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(await assembly.phase == .stopped)
        #expect(f.hosts.channels.isEmpty && f.operations.backend.calls.isEmpty)
        await #expect(throws: ServiceProblem(.unavailable)) { try await assembly.start() }
        let lease = try StoreLock(path: f.directory.appendingPathComponent("writer.lock").path, createIfMissing: false)
        withExtendedLifetime(lease) {}
    }
}

private enum AssemblyFailure: Error { case injected, unexpectedResult, timeout }
private enum AssemblyBindingOutcome: Equatable, Sendable { case stop, failure }
private enum AssemblyBackground: Equatable, Sendable { case preparation, receive, address }
private enum AssemblyRelayStage: Equatable, Sendable { case handoffReturn, result }
private enum AssemblyStartFailure: CaseIterable, Equatable, Sendable {
    case integrationFactory, integrationActivation, appleFactory, appleActivation
    var channel: NativeChannel {
        switch self { case .integrationFactory, .integrationActivation: .integration; default: .appleAutomation }
    }
    var factory: Bool { self == .integrationFactory || self == .appleFactory }
    var expectedFactories: [NativeChannel] { channel == .integration ? [.owner, .integration] : [.owner, .integration, .appleAutomation] }
    var constructedHosts: Int { expectedFactories.count - (factory ? 1 : 0) }
}

private final class AssemblyFixture: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("service-assembly-\(UUID().uuidString)")
    let operations = AssemblyOperations()
    let seeds = AssemblySeeds()
    let clock = AssemblyClock()
    let effects: AssemblyEffects
    let readiness = AssemblyReadiness()
    let liveState = AssemblyLiveState()
    let consent = AssemblyConsent()
    let hosts: AssemblyHosts
    let policy = AuthorityPolicy(bridge: .init(teamIdentifier: "synthetic", signingIdentifier: "bridge"),
        owner: .init(teamIdentifier: "synthetic", signingIdentifier: "owner"), accountIDs: [],
        capabilities: Set(IntegrationScope.allCases.map(\.rawValue)), ownerAuthenticationAge: 30,
        appleIntegration: .init(teamIdentifier: "synthetic", signingIdentifier: "apple"))
    init(failure: AssemblyStartFailure? = nil) {
        hosts = AssemblyHosts(failure: failure)
        effects = AssemblyEffects(clock: clock)
    }
    func fresh() throws -> ServiceAssembly {
        try ServiceAssembly.initializeNew(directory: directory, accessGroup: "test.OpalAgent.Service", accounts: seeds,
            operations: operations, policy: policy, effects: { [effects, readiness, liveState] context in
                liveState.bind(context.continuity)
                return ServiceEffectBoundaries(payments: effects, chain: effects, availability: { _ in readiness.value })
            },
            endpoints: { [hosts] in try hosts.make($0, handlers: $1) }, clock: clock,
            generateKey: { [seeds] in seeds.key() })
    }
    func reopen() throws -> ServiceAssembly {
        try ServiceAssembly.reopen(directory: directory, accessGroup: "test.OpalAgent.Service", accounts: seeds,
            operations: operations, policy: policy, effects: { [effects, readiness, liveState] context in
                liveState.bind(context.continuity)
                return ServiceEffectBoundaries(payments: effects, chain: effects, availability: { _ in readiness.value })
            }, endpoints: { [hosts] in try hosts.make($0, handlers: $1) }, clock: clock)
    }
    func fresh(factory: AssemblyFactory) throws -> ServiceAssembly {
        try ServiceAssembly.initializeNew(directory: directory, accessGroup: "test.OpalAgent.Service", accounts: seeds,
            operations: operations, policy: policy, effects: { [liveState] context in
                liveState.bind(context.continuity)
                return try await factory.make(context)
            },
            endpoints: { [hosts] in try hosts.make($0, handlers: $1) }, clock: clock,
            generateKey: { [seeds] in seeds.key() })
    }
    func reopen(factory: AssemblyFactory) throws -> ServiceAssembly {
        try ServiceAssembly.reopen(directory: directory, accessGroup: "test.OpalAgent.Service", accounts: seeds,
            operations: operations, policy: policy, effects: { [liveState] context in
                liveState.bind(context.continuity)
                return try await factory.make(context)
            },
            endpoints: { [hosts] in try hosts.make($0, handlers: $1) }, clock: clock)
    }
    func peer(_ channel: NativeChannel) -> PeerEvidence {
        let identity: SignedPeerIdentity
        switch channel { case .owner: identity = policy.owner; case .integration: identity = policy.bridge
        case .appleAutomation: identity = policy.appleIntegration! }
        return .init(identity: identity, signatureValidated: true)
    }
    func handlers(_ channel: NativeChannel) throws -> ServiceEndpointHandlers { try hosts.handlers(channel) }
    func connect(_ channel: NativeChannel) async throws -> ServiceConnection {
        try await handlers(channel).connect(connectionID: UUID().uuidString, peer: peer(channel))
    }
    func owner(_ call: OwnerControlCall, connection: ServiceConnection) async throws -> OwnerControlResult {
        try await handlers(.owner).owner(.init(call: call), connection: connection, consent: consent).result
    }
    func capability(_ call: CapabilityCall, connection: ServiceConnection,
                    channel: NativeChannel = .integration) async throws -> CapabilityResult {
        try await handlers(channel).capability(.init(call: call), connection: connection).result
    }
    func createEnabled(_ connection: ServiceConnection) async throws -> WalletScope {
        guard case .createWallet(let status) = try await owner(.createWallet(network: .mainnet), connection: connection),
              let wallet = status.wallet else { throw AssemblyFailure.unexpectedResult }
        #expect(status.availability == .restricted && status.grants.isEmpty)
        _ = try await owner(.enableWallet(wallet), connection: connection)
        return wallet
    }
    func enroll(_ wallet: WalletScope, owner: ServiceConnection,
                profile: IntegrationPeerProfile = .mcp) async throws -> OwnerIssuedCredential {
        let request = try EnrollmentRequest(wallet: wallet, integrationID: "assembly-\(profile.rawValue)",
            accountIDs: ["assembly-account"], scopes: IntegrationScope.allCases, peerProfile: profile)
        guard case .enrollIntegration(let credential) = try await self.owner(.enrollIntegration(request), connection: owner) else {
            throw AssemblyFailure.unexpectedResult
        }
        return credential
    }
    func key(_ value: String) throws -> RequestKey { try RequestKey(String(repeating: value, count: 32)) }
    func payment(_ account: AccountScope) throws -> PreparePaymentRequest {
        try PreparePaymentRequest(account: account, requestKey: key("c"),
            destinationAddress: "1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu", amountSatoshis: 1_000)
    }
    func state() throws -> CanonicalState {
        // Live assertions share the actual writer's coordinator lock. Opening another
        // read/write journal or holding an independent read snapshot can itself make a
        // zero-timeout SQLite COMMIT fail and strand its anchored handshake.
        if let continuity = liveState.current { return try continuity.inspect { $0 } }
        let journal = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path, createIfMissing: false)
        return try #require(try journal.read())
    }
    func files() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class AssemblyHosts: @unchecked Sendable {
    private let lock = NSLock()
    private let failure: AssemblyStartFailure?
    private var factories: [NativeChannel] = []
    private var values: [AssemblyHost] = []
    init(failure: AssemblyStartFailure?) { self.failure = failure }
    var channels: [NativeChannel] { lock.withLock { factories } }
    var constructed: [AssemblyHost] { lock.withLock { values } }
    var invalidations: [Int] { constructed.map(\.invalidations) }
    func make(_ channel: NativeChannel, handlers: ServiceEndpointHandlers) throws -> any ServiceEndpointHost {
        try lock.withLock {
            factories.append(channel)
            if let failure, failure.channel == channel, failure.factory { throw AssemblyFailure.injected }
            let host = AssemblyHost(channel: channel, handlers: handlers,
                failActivation: failure?.channel == channel && failure?.factory == false)
            values.append(host)
            return host
        }
    }
    func handlers(_ channel: NativeChannel) throws -> ServiceEndpointHandlers {
        try lock.withLock {
            guard let value = values.last(where: { $0.channel == channel }) else { throw AssemblyFailure.unexpectedResult }
            return value.handlers
        }
    }
}
private final class AssemblyHost: ServiceEndpointHost, @unchecked Sendable {
    let channel: NativeChannel
    let handlers: ServiceEndpointHandlers
    let failActivation: Bool
    private let lock = NSLock()
    private var invalidationCount = 0
    var invalidations: Int { lock.withLock { invalidationCount } }
    init(channel: NativeChannel, handlers: ServiceEndpointHandlers, failActivation: Bool) {
        self.channel = channel; self.handlers = handlers; self.failActivation = failActivation
    }
    func activate() throws { if failActivation { throw AssemblyFailure.injected } }
    func invalidate() { lock.withLock { invalidationCount += 1 } }
}

private actor AssemblyGate {
    private var armed = false
    private(set) var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func arm() { armed = true; hasEntered = false }
    func wait() async {
        guard armed else { return }
        armed = false; hasEntered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private final class AssemblyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
private final class AssemblyReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var cached = AccountReadiness.unavailable
    var value: AccountReadiness { lock.withLock { cached } }
    func set(_ value: AccountReadiness) { lock.withLock { cached = value } }
}
private final class AssemblyLiveState: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: ContinuityCoordinator?
    var current: ContinuityCoordinator? { lock.withLock { value } }
    func bind(_ continuity: ContinuityCoordinator) { lock.withLock { value = continuity } }
}
private final class AssemblyFactory: @unchecked Sendable {
    let gate = AssemblyGate()
    private let effects: AssemblyEffects
    private let fail: Bool
    private let lock = NSLock()
    private var observed: [WalletCustodyRecord] = []
    var custodies: [WalletCustodyRecord] { lock.withLock { observed } }
    init(effects: AssemblyEffects, fail: Bool = false) { self.effects = effects; self.fail = fail }
    func make(_ context: ServiceCustodyContext) async throws -> ServiceEffectBoundaries {
        guard try context.continuity.inspect({ $0.custody }) == context.custody else { throw AssemblyFailure.unexpectedResult }
        lock.withLock { observed.append(context.custody) }
        await gate.wait()
        if fail { throw AssemblyFailure.injected }
        return ServiceEffectBoundaries(payments: effects, chain: effects)
    }
}
private final class AssemblyClock: PaymentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Int64 = 1_000
    private var monotonic: UInt64 = 100
    func read() -> PaymentClockReading { lock.withLock { .init(wall: wall, monotonic: monotonic) } }
    func advance(_ seconds: Int64) { lock.withLock { wall += seconds; monotonic += UInt64(seconds) } }
}
private struct AssemblyConsent: OwnerConsentProvider {
    let gate = AssemblyGate()
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        await gate.wait()
        return .init(challenge: challenge, authenticatedAt: 1_000)
    }
}
private final class AssemblySeeds: SeedAccountProvider, @unchecked Sendable {
    let derivation = AssemblyGate()
    private let lock = NSLock()
    private var generationCount = 0
    private var derivationCount = 0
    private var keyCount = 0
    var generated: Int { lock.withLock { generationCount } }
    var derived: Int { lock.withLock { derivationCount } }
    var keys: Int { lock.withLock { keyCount } }
    func key() -> SymmetricKey {
        lock.withLock { keyCount += 1 }
        return SymmetricKey(data: Data(repeating: 0x73, count: 32))
    }
    func generateMnemonic() throws -> Data {
        lock.withLock { generationCount += 1 }
        return Data("synthetic assembly material".utf8)
    }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        lock.withLock { derivationCount += 1 }
        await derivation.wait()
        guard mnemonic == Data("synthetic assembly material".utf8) else { throw AssemblyFailure.unexpectedResult }
        return .init(accountID: "assembly-account", publicDescriptor: Data("synthetic descriptor".utf8))
    }
}
private final class AssemblyOperations: KeychainItemOperations, @unchecked Sendable {
    let backend = KeychainTestOperations()
    private let lock = NSLock()
    private var hidden = false
    var wrappingKeyReads: Int {
        backend.calls.reduce(into: 0) { count, call in
            if case .copyMatching(let query) = call,
               query[kSecAttrService as String] as? String == "com.58opals.OpalAgent.wrapkey" { count += 1 }
        }
    }
    func hideWrappingKey() { lock.withLock { hidden = true } }
    func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?) {
        let values = query as NSDictionary as! [String: Any]
        if values[kSecAttrService as String] as? String == "com.58opals.OpalAgent.wrapkey", lock.withLock({ hidden }) {
            return (errSecItemNotFound, nil)
        }
        return backend.copyMatching(query)
    }
    func add(_ attributes: CFDictionary) -> OSStatus { backend.add(attributes) }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus { backend.update(query, attributes: attributes) }
}
private final class AssemblyEffects: PaymentExecutionBoundary, AccountChainBoundary, @unchecked Sendable {
    struct Counts: Equatable { var sign = 0; var handoff = 0; var address = 0; var observe = 0; var refresh = 0 }
    let preparation = AssemblyGate(), refresh = AssemblyGate(), address = AssemblyGate()
    let handoffReturn = AssemblyGate(), result = AssemblyGate()
    let clock: AssemblyClock
    private let lock = NSLock()
    private var observed = Counts()
    var counts: Counts { lock.withLock { observed } }
    init(clock: AssemblyClock) { self.clock = clock }
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview {
        await preparation.wait()
        return .init(operationID: request.operationID, accountID: request.accountID, network: request.network,
            destinationScript: request.destinationScript, amount: request.amount, fee: 100,
            selectedInputs: [String(repeating: "11", count: 32) + ":0"], change: Data(),
            templateDigest: paymentDigest(try paymentEncoding(request)), leaseDeadline: 2_000)
    }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment {
        lock.withLock { observed.sign += 1 }
        let bytes = try paymentEncoding(preview)
        return .init(operationID: preview.operationID, bytes: bytes, digest: paymentDigest(bytes),
            transactionID: String(repeating: "22", count: 32))
    }
    func preflight(_ payment: SignedPayment) async throws {}
    func validateAdmission(_ payment: SignedPayment) throws {}
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        let invocation = try admission {
            lock.withLock { observed.handoff += 1 }
            return .init(id: UUID().uuidString, result: { [result] in
                await result.wait()
                return .unknown(source: "synthetic-assembly")
            }, cancel: {})
        }
        await handoffReturn.wait()
        return invocation
    }
    func dispose(operationID: String) async throws {}
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation {
        lock.withLock { observed.observe += 1 }
        return .init(source: "synthetic", view: "view", chainTip: "tip", observedAt: clock.read().wall, complete: true, fresh: true)
    }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        lock.withLock { observed.refresh += 1 }
        await refresh.wait()
        return .init(accountID: accountID, network: network, providerID: "synthetic", viewID: "view", chainTip: "tip",
            observedAt: clock.read().wall, complete: true, fresh: true, balance: 0, snapshot: Data("{}".utf8), receivingHorizon: -1, changeHorizon: -1)
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        lock.withLock { observed.address += 1 }
        let value = "synthetic-assembly-address-\(index)"
        await address.wait()
        return value
    }
}

private func assemblyEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw AssemblyFailure.timeout
}
