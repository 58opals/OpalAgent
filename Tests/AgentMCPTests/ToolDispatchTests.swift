import AgentClient
import AgentValues
import Foundation
import OpalDiagnostics
import Testing
@testable import AgentMCP

private actor ToolCalls {
    private(set) var values: [CapabilityCall] = []
    func append(_ call: CapabilityCall) { values.append(call) }
}
private struct ToolTransport: CapabilityTransport {
    let calls: ToolCalls
    let reply: @Sendable (CapabilityRequest) throws -> CapabilityResponse
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        await calls.append(request.call)
        return try reply(request)
    }
}
private struct ToolFixture: Sendable {
    // Successful fixtures must remain inside the BCH monetary range checked by CapabilityClient.
    let maximumMoney: Int64 = 2_100_000_000_000_000
    let account: AccountScope
    let key: RequestKey
    let selector: OperationSelector
    let observation = SnapshotObservation(providerID: "fixture-provider", viewID: "fixture-view", chainTip: "fixture-tip",
        sequence: UInt64.max, observedAt: 1_000, generation: UInt64.max, fresh: true, complete: true)
    init() throws {
        account = try AccountScope(wallet: WalletScope(walletID: "wallet", network: .mainnet), accountID: "account")
        key = try RequestKey(String(repeating: "a", count: 32))
        selector = try OperationSelector(account: account, operationID: "operation")
    }
    var walletValue: MCPValue { .object(["walletID": .string(account.wallet.walletID), "network": .string(account.wallet.network.rawValue)]) }
    var accountValue: MCPValue { .object(["wallet": walletValue, "accountID": .string(account.accountID)]) }
    var selectorValue: MCPValue { .object(["account": accountValue, "operationID": .string(selector.operationID)]) }
    func arguments(_ method: CapabilityMethod) -> [String: MCPValue] {
        switch method {
        case .listWallets: ["limit": .int(2)]
        case .listAccounts: ["wallet": walletValue, "page": .object(["limit": .int(2)])]
        case .getBalance, .getSyncStatus: accountValue.objectValue ?? [:]
        case .listTransactions, .listUTXOs: ["account": accountValue, "page": .object(["limit": .int(2)])]
        case .synchronizeAccount, .createReceiveRequest: ["account": accountValue, "requestKey": .string(key.value)]
        case .preparePayment: ["account": accountValue, "requestKey": .string(key.value), "destinationAddress": .string("fixture-address"),
            "amountSatoshis": .string("1000"), "feeRateSatoshisPerByte": .string("2")]
        case .submitPayment, .cancelOperation: selectorValue.objectValue ?? [:]
        case .getOperation: ["operation": selectorValue]
        }
    }
    func dispatch(_ reply: (@Sendable (CapabilityRequest) throws -> CapabilityResponse)? = nil) -> (ToolDispatch, ToolCalls) {
        let calls = ToolCalls()
        let transport = ToolTransport(calls: calls, reply: reply ?? { try self.response($0) })
        return (ToolDispatch(client: CapabilityClient(transport: transport)), calls)
    }
    private func identity(_ selector: OperationSelector? = nil, key: RequestKey? = nil) -> OperationIdentity {
        OperationIdentity(selector: selector ?? self.selector, requestKey: key ?? self.key)
    }
    private func sync(_ selector: OperationSelector? = nil, key: RequestKey? = nil) -> SyncOperation {
        SyncOperation(identity: identity(selector, key: key), state: .completed, observation: observation)
    }
    private func receive(_ selector: OperationSelector? = nil, key: RequestKey? = nil) -> ReceiveOperation {
        ReceiveOperation(identity: identity(selector, key: key), state: .allocated,
            allocation: .init(address: "fixture-receiving-address", index: 0))
    }
    private func payment(_ selector: OperationSelector? = nil, request: PreparePaymentRequest? = nil, closed: Bool = false) throws -> PaymentOperation {
        let selected = selector ?? self.selector
        let request = try request ?? PreparePaymentRequest(account: selected.account, requestKey: key,
            destinationAddress: "canonical-fixture-address", amountSatoshis: 1_000)
        let preview = PaymentPreviewProjection(canonicalDestinationAddress: "canonical-fixture-address", destinationScriptHex: "51",
            amountSatoshis: request.amountSatoshis, feeSatoshis: 100,
            selectedInputs: [Outpoint(transactionID: String(repeating: "b", count: 64), outputIndex: 1)],
            change: [.init(lockingScriptHex: "51", amountSatoshis: 500)], templateDigest: String(repeating: "c", count: 64), leaseDeadline: 2_000)
        return PaymentOperation(identity: identity(selected, key: request.requestKey), request: request,
            state: closed ? .closed : .prepared, preview: preview, terminalReason: closed ? .cancelled : nil,
            accountRestriction: .clear, evidence: .init(revision: UInt64.max, support: .supported, observation: observation),
            lastReconciliationAt: 1_000, observationSequence: UInt64.max)
    }
    func response(_ request: CapabilityRequest) throws -> CapabilityResponse {
        let result: CapabilityResult
        switch request.call {
        case .listWallets: result = .listWallets(.init(items: [.init(scope: account.wallet, availability: .enabled)]))
        case .listAccounts(let r): result = .listAccounts(.init(wallet: r.wallet, page: .init(items: [.init(scope: account)])))
        case .getBalance(let scope): result = .getBalance(.init(account: scope, totalSatoshis: maximumMoney, observation: observation))
        case .listTransactions(let r): result = .listTransactions(.init(account: r.account, observation: observation,
            page: .init(items: [.init(transactionID: String(repeating: "d", count: 64), deltaSatoshis: -maximumMoney,
                confirmations: nil, height: 100, status: .confirmed)])))
        case .listUTXOs(let r): result = .listUTXOs(.init(account: r.account, observation: observation,
            page: .init(items: [.init(outpoint: .init(transactionID: String(repeating: "e", count: 64), outputIndex: UInt32.max),
                amountSatoshis: maximumMoney, reservation: .otherOperation)])))
        case .getSyncStatus(let scope): result = .getSyncStatus(.init(account: scope, observation: nil))
        case .synchronizeAccount(let r): result = .synchronizeAccount(sync(try OperationSelector(account: r.account, operationID: "operation"), key: r.requestKey))
        case .createReceiveRequest(let r): result = .createReceiveRequest(receive(try OperationSelector(account: r.account, operationID: "operation"), key: r.requestKey))
        case .preparePayment(let r): result = .preparePayment(try payment(try OperationSelector(account: r.account, operationID: "operation"), request: r))
        case .submitPayment(let selected): result = .submitPayment(try payment(selected))
        case .getOperation(.operation(let selected)): result = .getOperation(.payment(try payment(selected)))
        case .getOperation(.request(let scope, let effect, let key)):
            let selected = try OperationSelector(account: scope, operationID: "operation")
            switch effect {
            case .synchronizeAccount: result = .getOperation(.synchronization(sync(selected, key: key)))
            case .createReceiveRequest: result = .getOperation(.receive(receive(selected, key: key)))
            case .preparePayment:
                let r = try PreparePaymentRequest(account: scope, requestKey: key, destinationAddress: "fixture-address", amountSatoshis: 1_000)
                result = .getOperation(.payment(try payment(selected, request: r)))
            }
        case .cancelOperation(let selected): result = .cancelOperation(.payment(try payment(selected, closed: true)))
        }
        return CapabilityResponse(result: result)
    }
}
private func toolObject(_ value: MCPValue?) throws -> [String: MCPValue] { try #require(value?.objectValue) }
private func toolCode(_ result: MCPToolResult) throws -> String {
    let outer = try toolObject(result.structuredContent)
    let error = try toolObject(outer["error"])
    return try #require(error["code"]?.stringValue)
}

@Test(arguments: CapabilityMethod.allCases)
func toolDispatchRoutesEachOfTwelveMethodsThroughCapabilityClient(_ method: CapabilityMethod) async throws {
    let fixture = try ToolFixture(); let (dispatch, calls) = fixture.dispatch()
    let result = await dispatch.call(name: method.rawValue, arguments: fixture.arguments(method))
    #expect(result.isError == false)
    let outer = try toolObject(result.structuredContent)
    #expect(outer["ok"] == .bool(true) && outer["method"] == .string(method.rawValue))
    let recorded = await calls.values
    #expect(recorded.count == 1 && recorded.first?.method == method)
    guard case .text(let text, _, _) = try #require(result.content.first) else { throw CapabilityFailure.invalidResponse }
    #expect(try JSONDecoder().decode(MCPValue.self, from: Data(text.utf8)) == result.structuredContent)
}

@Test func toolDispatchMoneyAndUInt64ContextsNeverPassThroughDouble() async throws {
    let fixture = try ToolFixture(); let (dispatch, _) = fixture.dispatch()
    let balance = try toolObject(try toolObject(await dispatch.call(name: "get_balance", arguments: fixture.arguments(.getBalance)).structuredContent)["result"])
    #expect(balance["totalSatoshis"] == .string(String(fixture.maximumMoney)))
    let observation = try toolObject(balance["observation"])
    #expect(observation["generation"] == .string(String(UInt64.max)) && observation["sequence"] == .string(String(UInt64.max)))
    let history = try toolObject(try toolObject(await dispatch.call(name: "list_transactions", arguments: fixture.arguments(.listTransactions)).structuredContent)["result"])
    let item = try toolObject(try toolObject(history["page"])["items"]?.arrayValue?.first)
    #expect(item["deltaSatoshis"] == .string(String(-fixture.maximumMoney)) && item["confirmations"] == .null)
    let prepared = await dispatch.call(name: "prepare_payment", arguments: fixture.arguments(.preparePayment))
    let payment = try toolObject(try toolObject(prepared.structuredContent)["result"])
    let request = try toolObject(payment["request"]); let preview = try toolObject(payment["preview"])
    #expect(request["amountSatoshis"] == .string("1000") && request["feeRateSatoshisPerByte"] == .string("2"))
    #expect(preview["amountSatoshis"] == .string("1000") && preview["feeSatoshis"] == .string("100"))
    let change = try toolObject(preview["change"]?.arrayValue?.first)
    #expect(change["amountSatoshis"] == .string("500"))
    #expect(try toolObject(payment["evidence"])["revision"] == .string(String(UInt64.max)))
}

@Test(arguments: [MCPValue.int(1), .double(1), .string("1.0"), .string("1e3"), .string("01"), .string("-1"), .string("+1"),
    .string(" 1"), .string("1 "), .string("0"), .string(""), .string("2100000000000001"), .string("9223372036854775808")])
func toolDispatchRejectsNoncanonicalOrOutOfRangeMoneyBeforeTransport(_ amount: MCPValue) async throws {
    let fixture = try ToolFixture(); let (dispatch, calls) = fixture.dispatch()
    var arguments = fixture.arguments(.preparePayment); arguments["amountSatoshis"] = amount
    let result = await dispatch.call(name: "prepare_payment", arguments: arguments)
    let code = try toolCode(result)
    #expect(result.isError == true && code == "invalidRequest")
    #expect(await calls.values.isEmpty)
}

@Test func toolDispatchPreservesExactMaximumInputAndExplicitDefaults() async throws {
    let fixture = try ToolFixture(); let (dispatch, calls) = fixture.dispatch()
    var arguments = fixture.arguments(.preparePayment)
    arguments["amountSatoshis"] = .string("2100000000000000")
    arguments["feeRateSatoshisPerByte"] = .string(String(Int64.max))
    let result = await dispatch.call(name: "prepare_payment", arguments: arguments)
    #expect(result.isError == false)
    let payment = try toolObject(try toolObject(result.structuredContent)["result"])
    let projected = try toolObject(payment["request"])
    #expect(projected["amountSatoshis"] == .string(String(fixture.maximumMoney)))
    #expect(projected["feeRateSatoshisPerByte"] == .string(String(Int64.max)))
    guard case .preparePayment(let request) = try #require(await calls.values.last) else { throw CapabilityFailure.invalidResponse }
    #expect(request.amountSatoshis == 2_100_000_000_000_000 && request.feeRateSatoshisPerByte == Int64.max)
    arguments.removeValue(forKey: "feeRateSatoshisPerByte")
    _ = await dispatch.call(name: "prepare_payment", arguments: arguments)
    guard case .preparePayment(let defaulted) = try #require(await calls.values.last) else { throw CapabilityFailure.invalidResponse }
    #expect(defaulted.feeRateSatoshisPerByte == 1)
    _ = await dispatch.call(name: "list_wallets", arguments: nil)
    guard case .listWallets(let page) = try #require(await calls.values.last) else { throw CapabilityFailure.invalidResponse }
    #expect(page.limit == 40 && page.cursor == nil)
}

@Test func toolDispatchRejectsUnknownNestedFieldsAndUnsupportedSelectors() async throws {
    let fixture = try ToolFixture(); let (dispatch, calls) = fixture.dispatch()
    let invalid: [(String, [String: MCPValue])] = [
        ("owner_approve", [:]),
        ("get_balance", ["wallet": .object(["walletID": .string("wallet"), "network": .string("mainnet"), "owner": .bool(true)]), "accountID": .string("account")]),
        ("get_balance", ["wallet": .object(["walletID": .string("wallet"), "network": .string("MAINNET")]), "accountID": .string("account")]),
        ("get_balance", ["wallet": fixture.walletValue, "accountID": .string("account"), "approved": .bool(true)]),
        ("create_receive_request", ["account": fixture.accountValue, "requestKey": .string(String(repeating: "A", count: 32))]),
        ("create_receive_request", ["account": fixture.accountValue, "requestKey": .string(String(repeating: "a", count: 31))]),
        ("get_operation", ["operation": fixture.selectorValue, "effect": .string("preparePayment"), "account": fixture.accountValue, "requestKey": .string(fixture.key.value)]),
        ("get_operation", ["account": fixture.accountValue, "effect": .string("owner"), "requestKey": .string(fixture.key.value)]),
        ("get_operation", [:]), ("list_wallets", ["limit": .int(41)]), ("list_wallets", ["limit": .double(2)]),
        ("list_wallets", ["cursor": .string(String(repeating: "x", count: 2_049))]),
        ("list_utxos", ["account": fixture.accountValue, "page": .object(["limit": .int(1), "repair": .bool(true)])]),
        ("get_balance", ["wallet": fixture.walletValue, "accountID": .array([])])
    ]
    for (name, arguments) in invalid {
        let result = await dispatch.call(name: name, arguments: arguments)
        let code = try toolCode(result)
    #expect(result.isError == true && code == "invalidRequest")
    }
    #expect(await calls.values.isEmpty)
}

@Test(arguments: EffectKind.allCases)
func toolDispatchRetainsTheExclusiveKeyEffectNamespace(_ effect: EffectKind) async throws {
    let fixture = try ToolFixture(); let (dispatch, calls) = fixture.dispatch()
    let result = await dispatch.call(name: "get_operation", arguments: ["account": fixture.accountValue,
        "effect": .string(effect.rawValue), "requestKey": .string(fixture.key.value)])
    #expect(result.isError == false)
    let operation = try toolObject(try toolObject(result.structuredContent)["result"])
    #expect(operation["effect"] == .string(effect.rawValue) && operation["operation"]?.objectValue != nil)
    guard case .getOperation(.request(let account, let selected, let key)) = try #require(await calls.values.first) else { throw CapabilityFailure.invalidResponse }
    #expect(account == fixture.account && selected == effect && key == fixture.key)
}

private enum ToolPrivateFailure: Error, CustomStringConvertible {
    case fixture
    var description: String { "private-row-and-credential-fixture" }
}
@Test func toolDispatchErrorsAndForeignReservationsExposeNoPrivateRows() async throws {
    let fixture = try ToolFixture()
    let (unavailable, _) = fixture.dispatch { _ in throw ToolPrivateFailure.fixture }
    let failed = await unavailable.call(name: "get_balance", arguments: fixture.arguments(.getBalance))
    let failureCode = try toolCode(failed)
    #expect(failed.isError == true && failureCode == "unavailable")
    #expect(!String(describing: failed).contains("private-row-and-credential-fixture"))
    let (restricted, _) = fixture.dispatch { _ in throw ServiceProblem(.accountRestricted) }
    #expect(try toolCode(await restricted.call(name: "get_balance", arguments: fixture.arguments(.getBalance))) == "accountRestricted")
    let (dispatch, _) = fixture.dispatch()
    let coins = try toolObject(try toolObject(await dispatch.call(name: "list_utxos", arguments: fixture.arguments(.listUTXOs)).structuredContent)["result"])
    let item = try toolObject(try toolObject(coins["page"])["items"]?.arrayValue?.first)
    #expect(try toolObject(item["reservation"]) == ["state": .string("otherOperation")])
    #expect(await ToolDispatch().call(name: "get_balance", arguments: fixture.arguments(.getBalance)).isError == true)
}

@Test func toolDispatchKeepsCapabilityClientResponseGuards() async throws {
    let fixture = try ToolFixture()
    let (dispatch, calls) = fixture.dispatch { _ in
        CapabilityResponse(result: .listWallets(.init(items: Array(repeating: .init(scope: fixture.account.wallet), count: 41))))
    }
    let result = await dispatch.call(name: "list_wallets", arguments: ["limit": .int(40)])
    let code = try toolCode(result)
    #expect(result.isError == true && code == "unavailable")
    #expect(await calls.values.count == 1)
}

@Test func toolDispatchRefusesAClientValidOversizedPreviewBeforeSerialization() async throws {
    let fixture = try ToolFixture()
    let (dispatch, calls) = fixture.dispatch { request in
        guard case .preparePayment(let payment) = try fixture.response(request).result,
              let original = payment.preview else { throw CapabilityFailure.invalidResponse }
        let inputs = (0..<1_000).map { Outpoint(transactionID: String(repeating: "f", count: 64), outputIndex: UInt32($0)) }
        let preview = PaymentPreviewProjection(canonicalDestinationAddress: original.canonicalDestinationAddress,
            destinationScriptHex: original.destinationScriptHex, amountSatoshis: original.amountSatoshis,
            feeSatoshis: original.feeSatoshis, selectedInputs: inputs, change: original.change,
            templateDigest: original.templateDigest, leaseDeadline: original.leaseDeadline)
        return CapabilityResponse(result: .preparePayment(PaymentOperation(identity: payment.identity,
            request: payment.request, state: .prepared, preview: preview)))
    }
    let result = await dispatch.call(name: "prepare_payment", arguments: fixture.arguments(.preparePayment))
    #expect(result.isError == true)
    #expect(try toolCode(result) == "unavailable")
    #expect(await calls.values.count == 1)
    #expect(try JSONEncoder().encode(result).count < 1_024)
    let (normal, _) = fixture.dispatch()
    #expect(await normal.call(name: "prepare_payment", arguments: fixture.arguments(.preparePayment)).isError == false)
}


private let toolCapture = OpalDiagnostics.Configuration(
    subsystem: "com.58opals.agent.tests", categoryFilter: .enabled(["agent.mcp"]),
    bufferPolicy: .enabled(capacity: 3), routingPolicy: .disabled)

private final class DiagnosticDescriptionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func describe() -> String { lock.lock(); defer { lock.unlock() }; count += 1; return "private-error-canary" }
    var evaluations: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private struct DiagnosticPrivateError: Error, CustomStringConvertible {
    let probe: DiagnosticDescriptionProbe
    var description: String { probe.describe() }
}

@Test func diagnosticsKeepActualToolFailuresSilentByDefaultAndNeverDescribeErrors() async throws {
    let probe = DiagnosticDescriptionProbe()
    let fixture = try ToolFixture()
    for enabled in [false, true] {
        let configuration = enabled ? toolCapture : OpalDiagnostics.Configuration()
        try await OpalDiagnostics.withConfiguration(configuration) {
            let (dispatch, calls) = fixture.dispatch { _ in throw DiagnosticPrivateError(probe: probe) }
            let code = try toolCode(await dispatch.call(name: "get_balance", arguments: fixture.arguments(.getBalance)))
            #expect(code == "unavailable")
            #expect(await calls.values.count == 1)
            #expect(OpalDiagnostics.configuration == configuration)
            let records = OpalDiagnostics.recentRecords
            #expect(records.count == (enabled ? 1 : 0))
            if enabled {
                #expect(records.first?.fields == [.publicField("stage", value: "result"), .publicField("reason", value: "unavailable")])
            }
        }
    }
    #expect(probe.evaluations == 0)
}

@Test func diagnosticsBoundMalformedToolInputToTheClosedPublicSchema() async throws {
    let fixture = try ToolFixture(); let (dispatch, calls) = fixture.dispatch()
    let canary = "private-seed-credential-account-request-key-amount-endpoint-canary"
    try await OpalDiagnostics.withConfiguration(toolCapture) {
        try await OpalDiagnostics.withTraceID(.init(publicValue: canary)) {
            for _ in 0..<20 {
                let code = try toolCode(await dispatch.call(name: canary, arguments: [canary: .string(canary)]))
                #expect(code == "invalidRequest")
            }
            let records = OpalDiagnostics.recentRecords
            #expect(records.count == 3)
            #expect(await calls.values.isEmpty)
            for record in records {
                #expect(record.category.rawValue == "agent.mcp" && record.event.rawValue == "tool_failed")
                #expect(record.fields == [.publicField("stage", value: "method"), .publicField("reason", value: "invalidRequest")])
                #expect(record.fields.allSatisfy { $0.privacy == .public && $0.value != "<redacted>" })
                #expect(UUID(uuidString: record.traceID?.rawValue ?? "") != nil)
                #expect(record.traceID?.rawValue != canary)
            }
            #expect(Set(records.compactMap(\.traceID)).count == 3)
            #expect(OpalDiagnostics.configuration == toolCapture)
        }
    }
}

@Test func diagnosticsParallelToolAttemptsKeepTheirScopedCapturesSeparate() async throws {
    let fixture = try ToolFixture()
    @Sendable func capture(method: String, stage: String) async throws -> OpalDiagnostics.TraceID {
        try await OpalDiagnostics.withConfiguration(toolCapture) {
            let (dispatch, calls) = fixture.dispatch()
            #expect(try toolCode(await dispatch.call(name: method, arguments: ["private-field-canary": .string("private-value-canary")])) == "invalidRequest")
            #expect(await calls.values.isEmpty)
            let records = OpalDiagnostics.recentRecords
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.fields == [.publicField("stage", value: stage), .publicField("reason", value: "invalidRequest")])
            return try #require(record.traceID)
        }
    }
    async let method = capture(method: "private-method-canary", stage: "method")
    async let input = capture(method: "get_balance", stage: "input")
    #expect(try await method != input)
}
