import Foundation
import Testing
@testable import AgentMCP

@Test func toolOutputBudgetAccountsForEscapingAndTheCompleteDoubleRepresentation() throws {
    let boundary = MCPValue.string(String(repeating: "\"", count: 29_999))
    try ToolValueBudget.validate(boundary)
    #expect(throws: ToolArgumentError.invalid) {
        try ToolValueBudget.validate(.string(String(repeating: "\"", count: 30_000)))
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text = String(decoding: try encoder.encode(boundary), as: UTF8.self)
    let result = MCPToolResult(content: [.text(text: text, annotations: nil, _meta: nil)],
        structuredContent: Optional.some(boundary), isError: false)
    // The profile bounds response IDs to 128 bytes; 2 KiB also covers the JSON-RPC envelope.
    #expect(try encoder.encode(result).count + 2_048 <= MCPBounds.outputBytes)
    #expect(throws: ToolArgumentError.invalid) { try ToolValueBudget.validate(.string(String(repeating: "\u{0000}", count: 10_000))) }
    #expect(throws: ToolArgumentError.invalid) { try ToolValueBudget.validate(.string(String(repeating: "\u{007f}", count: 10_000))) }
    #expect(throws: ToolArgumentError.invalid) { try ToolValueBudget.validate(.string(String(repeating: "😀", count: 5_000))) }
}

@Test func toolOutputBudgetBoundsDepthNodesAndRejectsNonintegerValues() throws {
    var nested: MCPValue = .null
    for _ in 0..<ToolValueBudget.maximumDepth { nested = .array([nested]) }
    try ToolValueBudget.validate(nested)
    let tooDeep = MCPValue.array([nested])
    #expect(throws: ToolArgumentError.invalid) { try ToolValueBudget.validate(tooDeep) }
    try ToolValueBudget.validate(.array(Array(repeating: .null, count: ToolValueBudget.maximumNodes - 1)))
    #expect(throws: ToolArgumentError.invalid) {
        try ToolValueBudget.validate(.array(Array(repeating: .null, count: ToolValueBudget.maximumNodes)))
    }
    #expect(throws: ToolArgumentError.invalid) { try ToolValueBudget.validate(.double(1)) }
    #expect(throws: ToolArgumentError.invalid) { try ToolValueBudget.validate(.double(.nan)) }
    #expect(throws: ToolArgumentError.invalid) { try ToolValueBudget.validate(.data(Data([1]))) }
}
