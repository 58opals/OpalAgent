import AgentClient
import AgentValues
import Foundation
import MCP

/// A thin protocol adapter. The injected capability channel owns authenticated service access.
public struct ToolDispatch: Sendable {
    private let client: CapabilityClient
    public init(client: CapabilityClient = CapabilityClient()) { self.client = client }

    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let method = CapabilityMethod(rawValue: name) else { return Self.failure(.invalidRequest) }
        let call: CapabilityCall
        do { call = try ToolInput.call(method, arguments: arguments) }
        catch { return Self.failure(.invalidRequest) }
        do {
            let result = try await client.call(call)
            return try Self.result(ToolOutput.success(result), isError: false)
        } catch let problem as ServiceProblem { return Self.failure(problem.code) }
        catch { return Self.failure(.unavailable) }
    }
    private static func failure(_ code: ServiceProblemCode) -> CallTool.Result {
        // This fixed shape always encodes; no error description, arguments or service row is reflected.
        (try? result(ToolOutput.failure(code), isError: true)) ?? CallTool.Result(content: [], isError: true)
    }
    private static func result(_ value: Value, isError: Bool) throws -> CallTool.Result {
        try ToolValueBudget.validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(value), as: UTF8.self)
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: Optional.some(value), isError: isError)
    }
}
