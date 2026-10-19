// AgentAutomationReadTests.swift

import AgentAppIntents
import AgentClient
import AgentValues
import Foundation
import Testing

private let readWallet = try! WalletScope(walletID: "automation-wallet", network: .mainnet)
private let readScope = try! AccountScope(wallet: readWallet, accountID: "authorized-account")
private let readObservation = SnapshotObservation(providerID: "provider", viewID: "view", chainTip: "tip", sequence: 8,
                                                  observedAt: 100, generation: 2, fresh: false, complete: true)

private func readBinding() throws -> AgentAutomationBinding {
    try AgentAutomationBinding(wallet: readWallet, integrationID: "automation-integration", grantID: "automation-grant",
        walletGeneration: 2, credentialGeneration: 1, accountIDs: [readScope.accountID], scopes: [.read])
}

private actor ReadAccess: AgentAutomationAccess {
    let binding: AgentAutomationBinding
    let transport: ReadTransport
    private(set) var opened = 0
    private var unlocked = true
    private var invalid = false
    private var holdUnlockCheck = false
    private var unlockCheckHeld = false
    private var unlockContinuation: CheckedContinuation<Void, Never>?
    init(transport: ReadTransport) throws { self.transport = transport; self.binding = try readBinding() }
    func isKnownUnlocked() async -> Bool {
        let result = unlocked
        if holdUnlockCheck {
            holdUnlockCheck = false; unlockCheckHeld = true
            await withCheckedContinuation { unlockContinuation = $0 }
        }
        return result
    }
    func openSession() async throws -> AgentAutomationSession {
        opened += 1
        return AgentAutomationSession(binding: binding, client: CapabilityClient(transport: transport))
    }
    func validate(binding: AgentAutomationBinding) async throws {
        guard unlocked else { throw AgentAutomationFailure.locked }
        guard binding == self.binding, !invalid else { throw AgentAutomationFailure.staleContext }
    }
    func holdNextUnlockCheck() { holdUnlockCheck = true }
    func waitUntilUnlockCheckHeld() async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
        while !unlockCheckHeld && clock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(unlockCheckHeld)
    }
    func releaseUnlockCheck() { holdUnlockCheck = false; unlockContinuation?.resume(); unlockContinuation = nil }
    func lock() { unlocked = false }
    func revoke() { invalid = true }
}

private actor ReadTransport: CapabilityTransport {
    enum Mismatch: Sendable, Equatable { case none, wallet, account, duplicate }
    let observation: SnapshotObservation?
    let mismatch: Mismatch
    let nextCursor: String?
    let holdBalance: Bool
    private(set) var methods: [CapabilityMethod] = []
    private var held = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    init(observation: SnapshotObservation? = readObservation, mismatch: Mismatch = .none,
         nextCursor: String? = nil, holdBalance: Bool = false) {
        self.observation = observation; self.mismatch = mismatch; self.nextCursor = nextCursor; self.holdBalance = holdBalance
    }
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        methods.append(request.call.method)
        let result: CapabilityResult
        switch request.call {
        case .listAccounts(let value):
            #expect(value.page.limit == 40 && value.page.cursor == nil)
            let wallet = mismatch == .wallet ? try WalletScope(walletID: "foreign-wallet", network: .mainnet) : readWallet
            let account = mismatch == .account ? try AccountScope(wallet: wallet, accountID: "other-account") :
                try AccountScope(wallet: wallet, accountID: readScope.accountID)
            let item = AccountSummary(scope: account)
            result = .listAccounts(AccountList(wallet: wallet,
                page: CapabilityPage(items: mismatch == .duplicate ? [item, item] : [item], nextCursor: nextCursor)))
        case .getSyncStatus(let account):
            result = .getSyncStatus(SyncStatusProjection(account: account, observation: observation,
                readiness: observation == nil ? .unavailable : .init(state: .blocked, blockers: [.staleEvidence])))
        case .getBalance(let account):
            if holdBalance && !released { held = true; await withCheckedContinuation { releaseContinuation = $0 } }
            let observed = try #require(observation)
            result = .getBalance(BalanceProjection(account: account, totalSatoshis: 191, observation: observed,
                readiness: .init(state: .blocked, blockers: [.staleEvidence])))
        default:
            Issue.record("An observational adapter attempted an effect or unrelated read.")
            throw ClientFailure.unavailable
        }
        return CapabilityResponse(result: result)
    }
    func waitUntilHeld() async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
        while !held && clock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(held)
    }
    func release() { released = true; releaseContinuation?.resume(); releaseContinuation = nil }
}

@Test func unavailableAutomationHasNoImplicitNativeFallback() async {
    let reader = AgentAutomationReader()
    await #expect(throws: AgentAutomationFailure.locked) { try await reader.accounts() }
}

@Test func neutralAccountResolutionUsesOneBoundedPageAndNoFinancialRead() async throws {
    let transport = ReadTransport(nextCursor: "next-page")
    let access = try ReadAccess(transport: transport)
    let reader = AgentAutomationReader(access: access)
    let accounts = try await reader.accounts()
    let account = try #require(accounts.first)
    #expect(accounts.count == 1 && account.network == "mainnet" && account.id.count == 64)
    #expect(account.id != readScope.accountID && !account.id.contains("automation"))
    let resolved = try await reader.accounts(identifiers: [account.id])
    #expect(resolved == accounts)
    #expect(try await reader.accounts(identifiers: [String(repeating: "f", count: 64)]).isEmpty)
    let methods = await transport.methods
    #expect(methods == [.listAccounts, .listAccounts, .listAccounts])
}

@Test func cachedInspectionPreservesExactSatoshisAndStaleEvidenceWithoutSync() async throws {
    let transport = ReadTransport(); let access = try ReadAccess(transport: transport)
    let reader = AgentAutomationReader(access: access)
    let accounts = try await reader.accounts()
    let account = try #require(accounts.first)
    let result = try await reader.inspect(accountID: account.id)
    #expect(result.account?.id == account.id && result.amountSatoshis == 191 && result.balanceAvailable)
    #expect(result.fresh == false && result.complete == true && result.observedAt == 100 && result.chainTip == "tip")
    #expect(result.readiness == "blocked" && result.blockers == ["staleEvidence"])
    #expect(result.id.count == 64 && result.id != account.id)
    let methods = await transport.methods
    #expect(methods == [.listAccounts, .listAccounts, .getSyncStatus, .getBalance, .getSyncStatus])
}

@Test func absentObservationRemainsAbsentAndDoesNotLoadBalance() async throws {
    let transport = ReadTransport(observation: nil); let access = try ReadAccess(transport: transport)
    let reader = AgentAutomationReader(access: access)
    let accounts = try await reader.accounts()
    let account = try #require(accounts.first)
    let result = try await reader.inspect(accountID: account.id)
    #expect(!result.balanceAvailable && result.amountSatoshis == nil && result.fresh == nil && result.complete == nil)
    #expect(result.observedAt == nil && result.chainTip == nil && result.readiness == "unavailable")
    let methods = await transport.methods
    #expect(methods == [.listAccounts, .listAccounts, .getSyncStatus])
}

@Test(arguments: [ReadTransport.Mismatch.wallet, .account, .duplicate])
private func foreignOrDuplicateServiceAccountsCannotEscapeTheEnrollment(_ mismatch: ReadTransport.Mismatch) async throws {
    let transport = ReadTransport(mismatch: mismatch); let access = try ReadAccess(transport: transport)
    let reader = AgentAutomationReader(access: access)
    if mismatch == .account {
        await #expect(throws: AgentAutomationFailure.invalidResponse) { try await reader.accounts() }
    } else {
        await #expect(throws: CapabilityFailure.invalidResponse) { try await reader.accounts() }
    }
    let methods = await transport.methods
    #expect(methods == [.listAccounts])
}

private enum ReadInvalidation: Sendable, Equatable { case lock, revoke }
@Test(arguments: [ReadInvalidation.lock, .revoke])
private func lockOrRevocationAfterSuspensionPreventsFinancialDisclosure(_ invalidation: ReadInvalidation) async throws {
    let transport = ReadTransport(holdBalance: true); let access = try ReadAccess(transport: transport)
    let reader = AgentAutomationReader(access: access)
    let accounts = try await reader.accounts()
    let account = try #require(accounts.first)
    let operation = Task { try await reader.inspect(accountID: account.id) }
    do {
        try await transport.waitUntilHeld()
        if invalidation == .lock { await access.lock() } else { await access.revoke() }
        await transport.release()
        let expected: AgentAutomationFailure = invalidation == .lock ? .locked : .staleContext
        await #expect(throws: expected) { try await operation.value }
    } catch {
        await transport.release(); _ = await operation.result; throw error
    }
}

@Test func revocationDuringTheUnlockedCheckIsCaughtByTheFinalSerializedGuard() async throws {
    let transport = ReadTransport(holdBalance: true); let access = try ReadAccess(transport: transport)
    let reader = AgentAutomationReader(access: access)
    let accounts = try await reader.accounts()
    let account = try #require(accounts.first)
    let operation = Task { try await reader.inspect(accountID: account.id) }
    do {
        try await transport.waitUntilHeld()
        await access.holdNextUnlockCheck()
        await transport.release()
        try await access.waitUntilUnlockCheckHeld()
        await access.revoke()
        await access.releaseUnlockCheck()
        await #expect(throws: AgentAutomationFailure.staleContext) { try await operation.value }
    } catch {
        await transport.release(); await access.releaseUnlockCheck()
        _ = await operation.result; throw error
    }
}

@Test func lockedQueryFailsBeforeCredentialSessionAndEmptySnapshotQueryDisclosesNothing() async throws {
    let transport = ReadTransport(); let access = try ReadAccess(transport: transport)
    await access.lock()
    await #expect(throws: AgentAutomationFailure.locked) { try await AgentAutomationReader(access: access).accounts() }
    let opened = await access.opened; let methods = await transport.methods
    #expect(opened == 0 && methods.isEmpty)
    let empty = AgentAccountSnapshot()
    #expect(empty.account == nil && !empty.balanceAvailable && empty.amountSatoshis == nil)
    #expect(empty.fresh == nil && empty.complete == nil && empty.observedAt == nil && empty.chainTip == nil)
    #expect(empty.readiness == "unavailable" && empty.blockers.isEmpty)
    #expect(try await AgentAccountSnapshotQuery().entities(for: ["unknown"]).isEmpty)
    #expect(try await AgentAccountSnapshotQuery().suggestedEntities().isEmpty)
}

@Test func decodedEnrollmentContextCannotBypassBindingValidation() throws {
    let original = try JSONEncoder().encode(readBinding())
    var fields = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    fields["walletGeneration"] = 0
    let invalid = try JSONSerialization.data(withJSONObject: fields)
    #expect(throws: AgentAutomationFailure.invalidReference) { try JSONDecoder().decode(AgentAutomationBinding.self, from: invalid) }
    fields["walletGeneration"] = 2; fields["owner"] = true
    let elevated = try JSONSerialization.data(withJSONObject: fields)
    #expect(throws: AgentAutomationFailure.invalidReference) { try JSONDecoder().decode(AgentAutomationBinding.self, from: elevated) }
}
