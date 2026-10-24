import Foundation
import Testing
@testable import AgentMCP

private func wireJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Test func ownedMCPValuesPreserveJSONScalarIdentityAndExactIntegers() throws {
    let bytes = Data(#"{"array":[true,1,1.25,null,"1"],"maximum":9223372036854775807,"minimum":-9223372036854775808}"#.utf8)
    let values = try JSONDecoder().decode(MCPValue.self, from: bytes)
    let object = try #require(values.objectValue)
    #expect(object["array"] == .array([.bool(true), .int(1), .double(1.25), .null, .string("1")]))
    #expect(object["maximum"] == .int(Int.max))
    #expect(object["minimum"] == .int(Int.min))
    #expect(try wireJSON(values) == String(decoding: bytes, as: UTF8.self))
    #expect(try JSONDecoder().decode(MCPValue.self, from: Data("1.0".utf8)) == .int(1))
    #expect(MCPValue.bool(true) != .int(1))
    #expect(MCPValue.string("1") != .int(1))
}

@Test func ownedMCPValuesKeepMediaSeparateFromWalletCommandStrings() throws {
    let decoder = JSONDecoder()
    let base64 = try decoder.decode(MCPValue.self, from: Data(#""data:text/plain;base64,Zml4dHVyZQ==""#.utf8))
    #expect(base64 == .data(mimeType: "text/plain", Data("fixture".utf8)))
    let percent = try decoder.decode(MCPValue.self, from: Data(#""data:;charset=utf-8,fixture%20value""#.utf8))
    #expect(percent == .data(mimeType: "text/plain;charset=utf-8", Data("fixture value".utf8)))
    let invalid = #""data:text/plain;base64,%%%""#
    #expect(try decoder.decode(MCPValue.self, from: Data(invalid.utf8)) == .string("data:text/plain;base64,%%%"))
    #expect(try wireJSON(MCPValue.data(Data([0, 1, 2]))) == #""data:text/plain;base64,AAEC""#)
    #expect(throws: ToolArgumentError.invalid) {
        try ToolInput.call(.getBalance, arguments: ["wallet": .object(["walletID": base64, "network": "mainnet"]), "accountID": "account"])
    }
    #expect(throws: ToolArgumentError.invalid) { try ToolValueBudget.validate(base64) }
}

@Test func ownedToolCatalogEnvelopeUsesLiteralMCPFieldNamesAndOmitsEmptyHints() throws {
    let tool = MCPTool(name: "fixture", description: "A fixture.",
                       inputSchema: .object(["type": "object"]), outputSchema: .object(["type": "object"]))
    let expected = #"{"description":"A fixture.","inputSchema":{"type":"object"},"name":"fixture","outputSchema":{"type":"object"}}"#
    #expect(try wireJSON(tool) == expected)
    #expect(try JSONDecoder().decode(MCPTool.self, from: Data(expected.utf8)) == tool)
    let minimal = MCPTool(name: "fixture", description: nil, inputSchema: .object([:]))
    #expect(try wireJSON(minimal) == #"{"description":null,"inputSchema":{},"name":"fixture"}"#)
}

@Test func ownedToolResultKeepsTextAndStructuredEnvelopesWithoutEnumTags() throws {
    let result = MCPToolResult(content: [.text(text: #"{"ok":true}"#, annotations: nil, _meta: nil)],
                               structuredContent: .object(["ok": true]), isError: false)
    let expected = #"{"content":[{"text":"{\"ok\":true}","type":"text"}],"isError":false,"structuredContent":{"ok":true}}"#
    #expect(try wireJSON(result) == expected)
    #expect(try JSONDecoder().decode(MCPToolResult.self, from: Data(expected.utf8)) == result)
    #expect(try wireJSON(MCPToolResult()) == #"{"content":[]}"#)
}

@Test func ownedToolContentRejectsAnUnadvertisedMediaKind() throws {
    let image = Data(#"{"type":"image","data":"AAEC","mimeType":"application/octet-stream"}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(MCPToolContent.self, from: image) }
}
