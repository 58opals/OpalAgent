import CryptoKit
import Foundation
import MCP
import Testing

private let expectedTools = [
    "list_wallets", "list_accounts", "get_balance", "list_transactions", "list_utxos", "get_sync_status",
    "synchronize_account", "create_receive_request", "prepare_payment", "submit_payment", "get_operation", "cancel_operation"
]

/// Response inspection uses SDK values and literal public wire contracts, never root models.
private struct ToolReply: Sendable {
    let fields: [String: MCP.Value]
    let isError: Bool
    var payload: [String: MCP.Value] { fields["result"]?.objectValue ?? [:] }
    var operation: [String: MCP.Value] { payload["operation"]?.objectValue ?? payload }
    var operationID: String? { operation["identity"]?.objectValue?["selector"]?.objectValue?["operationID"]?.stringValue }
}

private actor SDKSession {
    let client: MCP.Client
    private(set) var called: Set<String> = []
    init(client: MCP.Client) { self.client = client }

    func call(_ name: String, _ arguments: [String: MCP.Value]) async throws -> ToolReply {
        // All harness requests are small and sequential. The SDK owns their actual wire encoding.
        try #require(try JSONEncoder().encode(arguments).count <= 4096)
        let request = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
        let reply = try await request.value
        called.insert(name)
        try #require(reply.content.count == 1)
        guard case .text(let text, let annotations, let meta) = reply.content[0] else {
            throw AcceptanceFailure.rejected("Expected the public text result fallback")
        }
        try #require(annotations == nil && meta == nil && reply._meta == nil)
        let fields = try JSONDecoder().decode([String: MCP.Value].self, from: Data(text.utf8))
        try #require(reply.structuredContent == .object(fields))
        if reply.isError == true {
            try #require(Set(fields.keys) == ["ok", "error"] && fields["ok"] == .bool(false))
            let error = try #require(fields["error"]?.objectValue)
            try #require(Set(error.keys) == ["code"])
        } else {
            try #require(reply.isError == false)
            try #require(Set(fields.keys) == ["ok", "method", "result"])
            try #require(fields["ok"] == .bool(true) && fields["method"] == .string(name))
        }
        return ToolReply(fields: fields, isError: reply.isError == true)
    }

    func waitForOperation(account: MCP.Value, id: String, state: String) async throws -> ToolReply {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            let reply = try await call("get_operation", ["operation": .object(["account": account, "operationID": .string(id)])])
            try #require(!reply.isError && reply.operationID == id)
            if reply.operation["state"] == .string(state) { return reply }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AcceptanceFailure.rejected("Synthetic operation did not reach its expected state")
    }
}

private func object(_ value: MCP.Value?) throws -> [String: MCP.Value] { try #require(value?.objectValue) }
private func decimal(_ value: MCP.Value?) throws -> String {
    let text = try #require(value?.stringValue)
    try #require(!text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) })
    try #require(text == "0" || text.first != "0")
    return text
}
private func keyed(_ account: MCP.Value, _ key: String) -> [String: MCP.Value] {
    ["account": account, "requestKey": .string(key)]
}
private func payment(_ account: MCP.Value, key: String) -> [String: MCP.Value] {
    ["account": account, "requestKey": .string(key), "amountSatoshis": "10000", "feeRateSatoshisPerByte": "1",
     "destinationAddress": "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"]
}

private func checkCatalog(_ tools: [MCP.Tool]) throws {
    try #require(tools.map(\.name) == expectedTools)
    for tool in tools {
        try #require(tool.description?.isEmpty == false && tool.annotations.isEmpty)
        try #require(tool.title == nil && tool.icons == nil && tool._meta == nil)
        try #require(try object(tool.inputSchema)["type"] == .string("object"))
        let output = try object(tool.outputSchema)
        try #require(output["type"] == .string("object") && output["oneOf"]?.arrayValue?.count == 2)
    }
    let prepare = try #require(tools.first { $0.name == "prepare_payment" })
    let input = try object(try object(prepare.inputSchema)["properties"])
    try #require(try object(input["amountSatoshis"])["type"] == .string("string"))
    try #require(try object(input["amountSatoshis"])["maxLength"] == .int(16))
    try #require(try object(input["feeRateSatoshisPerByte"])["type"] == .string("string"))
    let definitions = try object(try object(prepare.outputSchema)["$defs"])
    let observation = try object(try object(definitions["observation"])["properties"])
    for name in ["sequence", "generation"] { try #require(try object(observation[name])["type"] == .string("string")) }
    let lookup = try #require(tools.first { $0.name == "get_operation" })
    let selectors = try #require(try object(lookup.inputSchema)["oneOf"]?.arrayValue)
    try #require(selectors.count == 2)
    for selector in selectors { try #require(try object(selector)["additionalProperties"] == .bool(false)) }
}

enum RejectedFixtureBinding: String, CaseIterable, Sendable {
    case missing, pathOnly, digestOnly, malformedDigest, wrongName, wrongHash, symlink, writable
}

@Test(arguments: RejectedFixtureBinding.allCases)
func invalidFixtureBindingsFailWithoutLaunchingAChild(_ scenario: RejectedFixtureBinding) throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("opal-mcp-binding-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(scenario == .wrongName ? "WrongFixture" : "AgentProtocolFixture")
    let bytes = Data("Unlaunched synthetic binding fixture\n".utf8)
    try bytes.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    let digest = SHA256.hash(data: bytes).map { byte in
        let hex = String(byte, radix: 16)
        return byte < 16 ? "0" + hex : hex
    }.joined()
    var environment = ["OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE": file.path,
                       "OPAL_AGENT_PROTOCOL_FIXTURE_SHA256": digest]
    switch scenario {
    case .missing: environment = [:]
    case .pathOnly: environment.removeValue(forKey: "OPAL_AGENT_PROTOCOL_FIXTURE_SHA256")
    case .digestOnly: environment.removeValue(forKey: "OPAL_AGENT_PROTOCOL_FIXTURE_EXECUTABLE")
    case .malformedDigest: environment["OPAL_AGENT_PROTOCOL_FIXTURE_SHA256"] = String(repeating: "A", count: 64)
    case .wrongName: break
    case .wrongHash: environment["OPAL_AGENT_PROTOCOL_FIXTURE_SHA256"] = String(repeating: "0", count: 64)
    case .symlink:
        let target = directory.appendingPathComponent("owned-bytes")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    case .writable:
        try FileManager.default.setAttributes([.posixPermissions: 0o720], ofItemAtPath: file.path)
    }
    #expect(throws: AcceptanceFailure.self) { _ = try FixtureExecutable.required(environment: environment) }
}

@Test(.timeLimit(.minutes(2)))
func officialSDKClientAcceptsOwnedStdioToolsWithDisposableSyntheticEffects() async throws {
    let binding = try FixtureExecutable.required() // Required bindings fail before any child launch.
    let child = try OwnedFixture(binding: binding)
    let client = MCP.Client(name: "Opal independent SDK acceptance", version: "1", configuration: .strict)
    let session = SDKSession(client: client)
    let watchdog = child.watchdog(client: client)
    do {
        let initialized = try await client.connect(transport: child.sdkTransport)
        try #require(initialized.protocolVersion == "2025-11-25")
        try #require(initialized.serverInfo.name == "OpalAgent" && initialized.serverInfo.version == "0.1.0")
        try #require(initialized.capabilities.tools != nil && initialized.capabilities.resources == nil
                     && initialized.capabilities.prompts == nil && initialized.capabilities.logging == nil)
        try #require(initialized.instructions == nil && initialized._meta == nil)
        let catalog = try await client.listTools()
        try #require(catalog.nextCursor == nil)
        try checkCatalog(catalog.tools)

        let wallets = try await session.call("list_wallets", [:])
        let walletItems = try #require(wallets.payload["items"]?.arrayValue)
        try #require(walletItems.count == 1 && wallets.payload["nextCursor"] == .null)
        let wallet = try #require(try object(walletItems[0])["scope"])
        try #require(try object(wallet)["network"] == .string("mainnet"))
        let accounts = try await session.call("list_accounts", ["wallet": wallet, "page": .object([:])])
        let accountItems = try #require(try object(accounts.payload["page"])["items"]?.arrayValue)
        try #require(accountItems.count == 1)
        let account = try #require(try object(accountItems[0])["scope"])
        try #require(try object(account)["wallet"] == wallet)

        let missingBalance = try await session.call("get_balance", try object(account))
        try #require(missingBalance.isError && missingBalance.fields == ["ok": false, "error": ["code": "unavailable"]])
        let missingStatus = try await session.call("get_sync_status", try object(account))
        try #require(!missingStatus.isError && missingStatus.payload["observation"] == .null)

        let syncKey = String(repeating: "1", count: 32)
        let sync = try await session.call("synchronize_account", keyed(account, syncKey))
        let syncID = try #require(sync.operationID)
        let completed = try await session.waitForOperation(account: account, id: syncID, state: "completed")
        try #require(completed.payload["effect"] == .string("synchronizeAccount"))
        let observation = try object(completed.operation["observation"])
        try #require(observation["fresh"] == .bool(true) && observation["complete"] == .bool(true))
        _ = try decimal(observation["sequence"])
        _ = try decimal(observation["generation"])
        let syncReplay = try await session.call("synchronize_account", keyed(account, syncKey))
        try #require(syncReplay.operationID == syncID)
        let balance = try await session.call("get_balance", try object(account))
        try #require(!balance.isError && balance.payload["totalSatoshis"] == .string("50000"))
        for method in ["list_transactions", "list_utxos"] {
            let reply = try await session.call(method, ["account": account, "page": .object([:])])
            try #require(!reply.isError && (try object(reply.payload["page"])["items"]?.arrayValue?.count) == 1)
        }

        let receiveKey = String(repeating: "2", count: 32)
        let receive = try await session.call("create_receive_request", keyed(account, receiveKey))
        let receiveID = try #require(receive.operationID)
        let allocated = try await session.waitForOperation(account: account, id: receiveID, state: "allocated")
        let allocation = try object(allocated.operation["allocation"])
        try #require(allocation["address"]?.stringValue?.isEmpty == false && allocation["index"] == .int(0))
        let receiveReplay = try await session.call("create_receive_request", keyed(account, receiveKey))
        try #require(receiveReplay.operationID == receiveID && receiveReplay.operation["allocation"] == .object(allocation))
        let lookup = try await session.call("get_operation", ["account": account, "effect": "createReceiveRequest", "requestKey": .string(receiveKey)])
        try #require(lookup.operationID == receiveID && lookup.operation["allocation"] == .object(allocation))

        let cancellable = try await session.call("prepare_payment", payment(account, key: String(repeating: "3", count: 32)))
        let cancelledID = try #require(cancellable.operationID)
        _ = try await session.waitForOperation(account: account, id: cancelledID, state: "prepared")
        let cancelled = try await session.call("cancel_operation", ["account": account, "operationID": .string(cancelledID)])
        try #require(cancelled.operation["state"] == .string("closed") && cancelled.operation["terminalReason"] == .string("cancelled"))

        let prepared = try await session.call("prepare_payment", payment(account, key: String(repeating: "4", count: 32)))
        let paymentID = try #require(prepared.operationID)
        let ready = try await session.waitForOperation(account: account, id: paymentID, state: "prepared")
        let request = try object(ready.operation["request"])
        try #require(request["amountSatoshis"] == .string("10000") && request["feeRateSatoshisPerByte"] == .string("1"))
        let submitArguments: [String: MCP.Value] = ["account": account, "operationID": .string(paymentID)]
        let submitted = try await session.call("submit_payment", submitArguments)
        try #require(!submitted.isError && submitted.operationID == paymentID)
        let accepted = try await session.waitForOperation(account: account, id: paymentID, state: "accepted")
        try #require(accepted.operation["ordinaryAdmissions"] == .string("1") && accepted.operation["liabilityUnresolved"] == .bool(true))
        let latest = try object(accepted.operation["latestAttempt"])
        // The immutable attempt records admission; later transport evidence sets the operation's accepted state.
        try #require(latest["number"] == .string("1") && latest["route"] == .string("ordinary") && latest["outcome"] == .string("admitted"))
        _ = try decimal(accepted.operation["observationSequence"])
        _ = try decimal(try object(accepted.operation["evidence"])["revision"])
        let replay = try await session.call("submit_payment", submitArguments)
        try #require(replay.operationID == paymentID && replay.operation["ordinaryAdmissions"] == .string("1"))
        try #require(await session.called == Set(expectedTools))

        try await child.finishInputAndWait()
        await client.disconnect()
        watchdog.cancel()
        await watchdog.value
        try await child.checkOutput()
        await child.cleanup()
    } catch {
        watchdog.cancel()
        await client.disconnect()
        await watchdog.value
        await child.cleanup()
        if let problem = child.problem { Issue.record("\(problem)") }
        throw error
    }
}
