import AgentClient
import AgentMCP
import AgentValues
import Foundation
import AgentMCPTestSupport
import OpalBaseCore
import Testing
@testable import AgentProtocolFixture
@testable import AgentServiceCore

private func withProtocolFixture(_ scenario: FixtureScenario,
                                 _ body: (FixtureRuntime, WireSession) async throws -> Void) async throws {
    let directory = fixtureDirectory()
    let runtime = try await FixtureRuntime.make(directory: directory, scenario: scenario)
    let session = try await WireSession.connect(session: runtime.openSession())
    do {
        try await body(runtime, session)
        await session.close()
        await runtime.shutdown()
        try FileManager.default.removeItem(at: directory)
    } catch {
        await session.close()
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
private func assertPublicWireValue(_ value: MCPValue) {
    switch value {
    case .object(let fields):
        let forbidden = Set(["mnemonic", "privateKey", "publicDescriptor", "encryptedMnemonic", "canonicalBytes",
                             "unsignedTemplate", "inputPayloads", "credentialDigest", "rawTransaction", "signingPlan"])
        #expect(Set(fields.keys).isDisjoint(with: forbidden))
        let money = Set(["totalSatoshis", "valueSatoshis", "amountSatoshis", "feeSatoshis", "feeRateSatoshisPerByte", "changeSatoshis"])
        for (key, child) in fields {
            if money.contains(key), child != .null { #expect(child.stringValue != nil) }
            assertPublicWireValue(child)
        }
    case .array(let values): for child in values { assertPublicWireValue(child) }
    default: break
    }
}

@Test func ownedWireAllTwelveToolsReachActualAssemblyBaseAndSQLiteWithoutReadEffects() async throws {
    try await withProtocolFixture(.autonomous) { fixture, wire in
        let tools = try await wire.client.listTools().tools
        #expect(Set(tools.map(\.name)) == Set(["list_wallets", "list_accounts", "get_balance", "list_transactions",
            "list_utxos", "get_sync_status", "synchronize_account", "create_receive_request", "prepare_payment",
            "submit_payment", "get_operation", "cancel_operation"]))
        #expect(!tools.contains { $0.name.contains("owner") || $0.name.contains("approve") || $0.name.contains("seed") })
        let initial = try fixture.reference()
        let queries = fixture.chain.counts
        let keyReads = fixture.keys.reads
        let wallets = try await wire.call("list_wallets", [:])
        #expect(wallets.result["items"]?.arrayValue?.count == 1)
        let accounts = try await wire.call("list_accounts", ["wallet": .object([
            "walletID": .string(fixture.account.wallet.walletID), "network": .string("mainnet")]), "page": .object([:])])
        #expect(accounts.result["page"]?.objectValue?["items"]?.arrayValue?.count == 1)
        let missing = try await wire.call("get_balance", try #require(accountValue(fixture).objectValue))
        #expect(missing.isError == true && missing.errorCode == "unavailable")
        let emptyStatus = try await wire.call("get_sync_status", try #require(accountValue(fixture).objectValue))
        #expect(emptyStatus.result["observation"] == .null)
        #expect(try fixture.reference() == initial)
        #expect(fixture.chain.counts == queries && fixture.keys.reads == keyReads)

        let sync = try await wire.call("synchronize_account", keyed(fixture, 1))
        let syncID = try #require(sync.operationID)
        let completed = try await waitOperation(wire, fixture, syncID, state: "completed")
        #expect(completed.result["effect"]?.stringValue == "synchronizeAccount")
        #expect(completed.operation["observation"]?.objectValue?["fresh"]?.boolValue == true)
        let balance = try await wire.call("get_balance", try #require(accountValue(fixture).objectValue))
        #expect(balance.result["totalSatoshis"]?.stringValue == "50000")
        let transactions = try await wire.call("list_transactions", ["account": accountValue(fixture), "page": .object([:])])
        #expect(transactions.result["page"]?.objectValue?["items"]?.arrayValue?.count == 1)
        let utxos = try await wire.call("list_utxos", ["account": accountValue(fixture), "page": .object([:])])
        #expect(utxos.result["page"]?.objectValue?["items"]?.arrayValue?.count == 1)
        let receive = try await wire.call("create_receive_request", keyed(fixture, 2))
        let receiveID = try #require(receive.operationID)
        let allocated = try await waitOperation(wire, fixture, receiveID, state: "allocated")
        let receiveAddress = try #require(allocated.operation["allocation"]?.objectValue?["address"]?.stringValue)
        let network = try #require(OpalBase.Network.Environment(rawValue: fixture.account.wallet.network.rawValue))
        let decodedAddress = try OpalBase.Address(receiveAddress, network: network)
        #expect(decodedAddress.network == network && decodedAddress.format == .standard)
        // Base returns a canonical CashAddr payload; the account supplies its explicit network.
        #expect(try OpalBase.Address(script: decodedAddress.lockingScript, network: network).string == receiveAddress)

        let cancellable = try await wire.call("prepare_payment", payment(fixture, 3))
        let cancelledID = try #require(cancellable.operationID)
        _ = try await waitOperation(wire, fixture, cancelledID, state: "prepared")
        let cancelled = try await wire.call("cancel_operation", selector(fixture, cancelledID))
        #expect(cancelled.operation["state"]?.stringValue == "closed")
        #expect(cancelled.operation["terminalReason"]?.stringValue == "cancelled")
        let prepared = try await wire.call("prepare_payment", payment(fixture, 4))
        let paymentID = try #require(prepared.operationID)
        _ = try await waitOperation(wire, fixture, paymentID, state: "prepared")
        _ = try await wire.call("submit_payment", selector(fixture, paymentID))
        let accepted = try await waitOperation(wire, fixture, paymentID, state: "accepted")
        #expect(accepted.operation["ordinaryAdmissions"]?.stringValue == "1")
        #expect(fixture.chain.counts.relays == 1)
        let recorded = try #require(try fixture.state().payments.first { $0.id == paymentID })
        #expect(!recorded.canonicalBytes.isEmpty && recorded.ordinaryAdmissions == 1 && recorded.liabilityUnresolved)
        #expect(try fixture.state().gates.contains { $0.liabilityIDs.contains(paymentID) })
        let replay = try await wire.call("submit_payment", selector(fixture, paymentID))
        #expect(replay.operationID == paymentID)
        let held = try await wire.call("prepare_payment", payment(fixture, 5))
        #expect(held.isError == true && held.errorCode == "accountRestricted")

        let beforeReads = try fixture.reference()
        let beforeEffects = fixture.chain.counts
        let beforeKeys = fixture.keys.reads
        for _ in 0..<3 {
            _ = try await operation(wire, fixture, paymentID)
            _ = try await wire.call("get_sync_status", try #require(accountValue(fixture).objectValue))
        }
        #expect(try fixture.reference() == beforeReads && fixture.chain.counts == beforeEffects && fixture.keys.reads == beforeKeys)
        for reply in [wallets, accounts, completed, balance, transactions, utxos, allocated, cancelled, accepted] {
            assertPublicWireValue(.object(reply.fields))
        }
    }
}

@Test func ownedWireApprovalRemainsOutOfBandAndRevocationPreservesTheHeldTransaction() async throws {
    try await withProtocolFixture(.approvalRequired) { fixture, wire in
        let prepared = try await wire.call("prepare_payment", payment(fixture, 10))
        let id = try #require(prepared.operationID)
        _ = try await waitOperation(wire, fixture, id, state: "prepared")
        _ = try await wire.call("submit_payment", selector(fixture, id))
        _ = try await waitOperation(wire, fixture, id, state: "pendingApproval")
        #expect(fixture.chain.counts.relays == 0)
        let forged = try await wire.call("approve_payment", selector(fixture, id))
        #expect(forged.isError == true && forged.errorCode == "invalidRequest")
        var extra = payment(fixture, 11)
        extra["owner"] = .bool(true)
        let asserted = try await wire.call("prepare_payment", extra)
        #expect(asserted.isError == true && asserted.errorCode == "invalidRequest")
        #expect(fixture.chain.counts.relays == 0)
        let selector = try OperationSelector(account: fixture.account, operationID: id)
        guard case .reviewPreview(let review) = try await fixture.ownerClient.call(.reviewPreview(selector)) else {
            throw WireFixtureFailure.invalidReply
        }
        _ = try await fixture.ownerClient.call(.approveExactPayment(review))
        _ = try await waitOperation(wire, fixture, id, state: "accepted")
        let before = try #require(try fixture.state().payments.first { $0.id == id })
        #expect(before.ordinaryAdmissions == 1 && fixture.chain.counts.relays == 1)
        _ = try await fixture.ownerClient.call(.revokeGrant(fixture.grant))
        let revokedReference = try fixture.reference()
        let revokedEffects = fixture.chain.counts
        let revokedKeyReads = fixture.keys.reads
        let denied = try await operation(wire, fixture, id)
        #expect(denied.isError == true && denied.errorCode == "unavailable")
        let deniedEffect = try await wire.call("create_receive_request", keyed(fixture, 12))
        #expect(deniedEffect.isError == true && deniedEffect.errorCode == "unavailable")
        for reply in [denied, deniedEffect] {
            #expect(reply.fields == ["ok": .bool(false), "error": .object(["code": .string("unavailable")])])
        }
        await #expect(throws: AuthorizationFailure.revoked) { try await fixture.openSession() }
        #expect(try fixture.reference() == revokedReference && fixture.chain.counts == revokedEffects && fixture.keys.reads == revokedKeyReads)
        let after = try #require(try fixture.state().payments.first { $0.id == id })
        #expect(after.canonicalBytes == before.canonicalBytes && after.attempts == before.attempts && after.liabilityUnresolved)
        #expect(try fixture.state().gates.contains { $0.liabilityIDs.contains(id) })
        #expect(fixture.chain.counts.relays == 1)
    }
}

@Test func ownedWireLostReceiveReplyReconnectsToOneRetainedAllocation() async throws {
    let directory = fixtureDirectory()
    let fixture = try await FixtureRuntime.make(directory: directory, scenario: .autonomous)
    let first = try await WireSession.connect(session: fixture.openSession(), dropping: "create_receive_request")
    let dropped = Task { try await first.call("create_receive_request", keyed(fixture, 20)) }
    do {
        let drop = try #require(first.drop)
        try await wireEventually("The already-produced tool reply must be dropped") { await drop.didDrop }
        try await wireEventually("The lost receive request must retain its completed allocation") {
            let state = try fixture.state()
            guard let request = state.requests.first(where: { $0.method == "create_receive_request" && $0.key == key(20) }) else { return false }
            return try accountOperationSnapshot(request, in: state).state == .allocated
        }
        let retained = try fixture.state()
        let request = try #require(retained.requests.first { $0.method == "create_receive_request" && $0.key == key(20) })
        let boundAccount = try accountOperationRequest(request)
        let retainedAllocation = try JSONDecoder().decode(ReceiveAllocation.self, from: request.result)
        #expect(boundAccount.accountID == fixture.account.accountID && boundAccount.network == fixture.account.wallet.network.rawValue && boundAccount.requestKey == key(20))
        #expect(request.originGrantID == fixture.grantID && retainedAllocation.operationID == request.id)
        #expect(retainedAllocation.accountID == fixture.account.accountID && retainedAllocation.network == fixture.account.wallet.network.rawValue)
        // The host closes its lost-response channel. The owned wire client fails its pending call.
        await first.client.disconnect()
        await #expect(throws: (any Error).self) { try await dropped.value }
        await first.close()
        #expect(!first.admission.connection.isActive)
        let retiredReference = try fixture.reference()
        let retiredEffects = fixture.chain.counts
        let retiredKeyReads = fixture.keys.reads
        await #expect(throws: ServiceProblem(.unavailable)) {
            try await first.admission.client.call(.listWallets(try PageRequest()))
        }
        await #expect(throws: ServiceProblem(.unavailable)) {
            try await first.admission.client.call(.createReceiveRequest(try KeyedAccountRequest(
                account: fixture.account, requestKey: RequestKey(key(21)))))
        }
        #expect(try fixture.reference() == retiredReference && fixture.chain.counts == retiredEffects && fixture.keys.reads == retiredKeyReads)
        let second = try await WireSession.connect(session: fixture.openSession())
        do {
            #expect(second.admission.connection !== first.admission.connection && second.admission.connection.isActive)
            let reference = try fixture.reference()
            let effects = fixture.chain.counts
            let keyReads = fixture.keys.reads
            let lookup = try await second.call("get_operation", ["account": accountValue(fixture),
                "effect": .string("createReceiveRequest"), "requestKey": .string(key(20))])
            let id = try #require(lookup.operationID)
            let allocation = try await waitOperation(second, fixture, id, state: "allocated")
            #expect(id == request.id && allocation.operationID == id)
            let identity = try #require(allocation.operation["identity"]?.objectValue)
            #expect(identity["requestKey"]?.stringValue == key(20))
            #expect(identity["selector"]?.objectValue?["account"] == accountValue(fixture))
            #expect(allocation.operation["allocation"] == .object([
                "address": .string(retainedAllocation.address), "index": .int(Int(retainedAllocation.index))]))
            let replay = try await second.call("create_receive_request", keyed(fixture, 20))
            #expect(replay.operation["identity"] == allocation.operation["identity"] && replay.operation["allocation"] == allocation.operation["allocation"])
            #expect(try fixture.reference() == reference && fixture.chain.counts == effects && fixture.keys.reads == keyReads)
            let state = try fixture.state()
            #expect(state.requests.filter { $0.method == "create_receive_request" }.count == 1)
            #expect(state.requests == retained.requests && state.allocations == retained.allocations)
            #expect(state.allocations.first { $0.branch == "receiving" }?.issuedIndices == [0])
            #expect(fixture.chain.counts.relays == 0)
            await second.close()
        } catch { await second.close(); throw error }
        await fixture.shutdown()
        try FileManager.default.removeItem(at: directory)
    } catch {
        await first.close()
        _ = await dropped.result
        await fixture.shutdown()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

@Test func ownedWireForeignLookupAndStaleSnapshotCannotAuthorizeAnotherEffect() async throws {
    try await withProtocolFixture(.uncertain) { fixture, wire in
        let prepared = try await wire.call("prepare_payment", payment(fixture, 30))
        let id = try #require(prepared.operationID)
        _ = try await waitOperation(wire, fixture, id, state: "prepared")
        _ = try await wire.call("submit_payment", selector(fixture, id))
        let uncertain = try await waitOperation(wire, fixture, id, state: "uncertain")
        #expect(uncertain.operation["ordinaryAdmissions"]?.stringValue == "1")
        let foreign = try await WireSession.connect(session: fixture.openForeignSession())
        do {
            let unavailable = try await operation(foreign, fixture, id)
            #expect(unavailable.isError == true && unavailable.errorCode == "unavailable")
            let byKey = try await foreign.call("get_operation", ["account": accountValue(fixture),
                "effect": .string("preparePayment"), "requestKey": .string(key(30))])
            #expect(byKey.isError == true && byKey.errorCode == "unavailable")
            await foreign.close()
        } catch { await foreign.close(); throw error }
        let retained = try #require(try fixture.state().payments.first { $0.id == id })
        fixture.chain.setFresh(false)
        let sync = try await wire.call("synchronize_account", keyed(fixture, 31))
        let syncID = try #require(sync.operationID)
        _ = try await waitOperation(wire, fixture, syncID, state: "closed")
        let beforeReads = try fixture.reference()
        let beforeReadEffects = fixture.chain.counts
        let beforeReadKeys = fixture.keys.reads
        let status = try await wire.call("get_sync_status", try #require(accountValue(fixture).objectValue))
        // Preparation's internal refresh does not create a cached public snapshot. The failed
        // explicit sync leaves a provenance-empty placeholder, never a fabricated observation.
        #expect(status.result["observation"] == .null)
        let readiness = try #require(status.result["readiness"]?.objectValue)
        let blockers = try #require(readiness["blockers"]?.arrayValue).compactMap(\.stringValue)
        #expect(readiness["state"]?.stringValue == "blocked")
        #expect(blockers.contains("staleSnapshot") && blockers.contains("accountRestricted"))
        let missingBalance = try await wire.call("get_balance", try #require(accountValue(fixture).objectValue))
        #expect(missingBalance.isError == true && missingBalance.errorCode == "unavailable")
        #expect(try fixture.reference() == beforeReads && fixture.chain.counts == beforeReadEffects && fixture.keys.reads == beforeReadKeys)
        let held = try await wire.call("prepare_payment", payment(fixture, 32))
        #expect(held.isError == true && held.errorCode == "accountRestricted")
        _ = try await wire.call("submit_payment", selector(fixture, id))
        let current = try #require(try fixture.state().payments.first { $0.id == id })
        #expect(current.canonicalBytes == retained.canonicalBytes && current.ordinaryAdmissions == 1 && current.liabilityUnresolved)
        #expect(try fixture.state().gates.contains { $0.liabilityIDs.contains(id) })
        #expect(fixture.chain.counts.relays == 1)
    }
}

@Test func syntheticFixtureRefusesExistingStateAndKeepsItsTraceAllowlisted() async throws {
    let directory = fixtureDirectory()
    let trace = directory.appendingPathComponent("assertions.jsonl")
    let fixture = try await FixtureRuntime.make(directory: directory, scenario: .missingSnapshot, tracePath: trace)
    do {
        await #expect(throws: FixtureFailure.invalidArguments) {
            try await FixtureRuntime.make(directory: directory, scenario: .autonomous)
        }
        let wire = try await WireSession.connect(session: fixture.openSession())
        _ = try await wire.call("list_wallets", [:])
        await wire.close()
        await fixture.shutdown()
        let events = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        #expect(!events.isEmpty)
        for line in events {
            let fields = try JSONDecoder().decode([String: MCPValue].self, from: Data(line.utf8))
            #expect(Set(fields.keys).isSubset(of: ["event", "method", "status", "relayCount"]))
            #expect(["fixture-ready", "capability-call", "fixture-stop"].contains(fields["event"]?.stringValue ?? ""))
        }
        try FileManager.default.removeItem(at: directory)
    } catch {
        await fixture.shutdown()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
