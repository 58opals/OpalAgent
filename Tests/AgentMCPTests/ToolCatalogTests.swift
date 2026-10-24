import AgentValues
import Testing
@testable import AgentMCP

private func schemaObject(_ value: MCPValue?) throws -> [String: MCPValue] { try #require(value?.objectValue) }
private func schemaProperties(_ value: MCPValue?) throws -> [String: MCPValue] { try schemaObject(try schemaObject(value)["properties"]) }
private func schemaSuccessResult(_ tool: MCPTool) throws -> MCPValue {
    let branches = try #require(try schemaObject(tool.outputSchema)["oneOf"]?.arrayValue)
    return try #require(try schemaProperties(branches.first)["result"])
}
private func visitSchema(_ value: MCPValue, _ inspect: (String, MCPValue) throws -> Void) rethrows {
    switch value {
    case .object(let fields):
        for (key, child) in fields { try inspect(key, child); try visitSchema(child, inspect) }
    case .array(let children): for child in children { try visitSchema(child, inspect) }
    default: break
    }
}

@Test func toolCatalogDeclaresExactlyTwelveStrictBoundedPublicCapabilities() throws {
    let tools = ToolCatalog.tools()
    #expect(tools.map(\.name) == CapabilityMethod.allCases.map(\.rawValue))
    #expect(Set(tools.map(\.name)).count == 12)
    for tool in tools {
        #expect(try schemaObject(tool.inputSchema)["type"] == .string("object"))
        #expect(tool.outputSchema != nil && tool.annotations.isEmpty)
        let method = try #require(CapabilityMethod(rawValue: tool.name))
        #expect(tool.description?.contains("Requires current service scope: " + method.requiredScope.rawValue) == true)
        let definitions = try schemaObject(try schemaObject(tool.outputSchema)["$defs"])
        try visitSchema(try #require(tool.outputSchema)) { key, value in
            if key == "$ref" {
                let path = try #require(value.stringValue)
                #expect(path.hasPrefix("#/$defs/") && definitions[String(path.dropFirst(8))] != nil)
            }
        }
        for schema in [tool.inputSchema, try #require(tool.outputSchema)] {
            try visitSchema(schema) { key, value in
                if key == "properties" {
                    let properties = try schemaObject(value)
                    #expect(Set(properties.keys).isDisjoint(with: ["role", "owner", "approved", "authenticationSucceeded", "mnemonic", "canonicalBytes", "signedBytes", "credential"]))
                }
            }
        }
    }
    for name in ["list_wallets", "list_accounts", "list_transactions", "list_utxos"] {
        let tool = try #require(tools.first { $0.name == name })
        var result = try schemaSuccessResult(tool)
        if name != "list_wallets" { result = try #require(try schemaProperties(result)["page"]) }
        let items = try schemaObject(try schemaProperties(result)["items"])
        #expect(items["maxItems"] == .int(PageRequest.maximumCount))
    }
}

@Test func toolCatalogMonetaryAndWideCounterSchemasMatchLosslessWireContract() throws {
    let tool = try #require(ToolCatalog.tools().first { $0.name == "prepare_payment" })
    let input = try schemaProperties(tool.inputSchema)
    #expect(try schemaObject(input["amountSatoshis"])["type"] == .string("string"))
    #expect(try schemaObject(input["feeRateSatoshisPerByte"])["type"] == .string("string"))
    #expect(try schemaObject(input["amountSatoshis"])["maxLength"] == .int(16))
    let definitions = try schemaObject(try schemaObject(tool.outputSchema)["$defs"])
    let payment = try schemaProperties(definitions["payment"])
    let request = try schemaProperties(payment["request"])
    #expect(try schemaObject(request["amountSatoshis"])["type"] == .string("string"))
    #expect(try schemaObject(request["feeRateSatoshisPerByte"])["type"] == .string("string"))
    let observation = try schemaProperties(definitions["observation"])
    #expect(try schemaObject(observation["generation"])["type"] == .string("string"))
    #expect(try schemaObject(observation["sequence"])["type"] == .string("string"))
    #expect(try schemaObject(payment["ordinaryAdmissions"])["pattern"] == .string("^[0-3]$"))
    let lookup = try #require(ToolCatalog.tools().first { $0.name == "get_operation" })
    let branches = try #require(try schemaObject(lookup.inputSchema)["oneOf"]?.arrayValue)
    #expect(branches.count == 2)
    for branch in branches { #expect(try schemaObject(branch)["additionalProperties"] == .bool(false)) }
    #expect(Set(try schemaProperties(branches[0]).keys) == ["operation"])
    #expect(Set(try schemaProperties(branches[1]).keys) == ["account", "effect", "requestKey"])
}
