import Foundation

/// JSON values used by the bounded stdio adapter. Wallet quantities remain explicit strings.
public enum MCPValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(mimeType: String? = nil, Data)
    case array([MCPValue])
    case object([String: MCPValue])

    public var isNull: Bool { self == .null }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var intValue: Int? { if case .int(let value) = self { value } else { nil } }
    public var doubleValue: Double? { if case .double(let value) = self { value } else { nil } }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var arrayValue: [MCPValue]? { if case .array(let value) = self { value } else { nil } }
    public var objectValue: [String: MCPValue]? { if case .object(let value) = self { value } else { nil } }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let integer = try? value.decode(Int.self) { self = .int(integer) }
        else if let number = try? value.decode(Double.self) { self = .double(number) }
        else if let string = try? value.decode(String.self) {
            // Preserve the previous adapter's data-URL distinction: binary media is not
            // accepted where ToolInput requires an ordinary wallet-command string.
            self = Self.mediaValue(string) ?? .string(string)
        } else if let array = try? value.decode([MCPValue].self) { self = .array(array) }
        else if let object = try? value.decode([String: MCPValue].self) { self = .object(object) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .int(let item): try value.encode(item)
        case .double(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .data(let mimeType, let item):
            try value.encode("data:" + (mimeType ?? "text/plain") + ";base64," + item.base64EncodedString())
        case .array(let items): try value.encode(items)
        case .object(let items): try value.encode(items)
        }
    }

    private static func mediaValue(_ string: String) -> MCPValue? {
        guard string.hasPrefix("data:"), let comma = string.firstIndex(of: ",") else { return nil }
        let header = String(string[string.index(string.startIndex, offsetBy: 5)..<comma])
        let parts = header.components(separatedBy: ";")
        var charset: String?
        switch parts.count {
        case 1: break
        case 2 where parts[1] == "base64": break
        case 2 where parts[1].hasPrefix("charset=") && parts[1].count > 8:
            charset = String(parts[1].dropFirst(8))
        case 3 where parts[1].hasPrefix("charset=") && parts[1].count > 8 && parts[2] == "base64":
            charset = String(parts[1].dropFirst(8))
        default: return nil
        }
        let payload = String(string[string.index(after: comma)...])
        guard !payload.contains(where: \.isNewline) else { return nil }
        var mimeType = parts[0].isEmpty ? "text/plain" : parts[0]
        if let charset, mimeType.hasPrefix("text/") { mimeType += ";charset=" + charset }
        let bytes: Data?
        if string.contains(";base64,") { bytes = Data(base64Encoded: payload) }
        else { bytes = payload.removingPercentEncoding?.data(using: .utf8) }
        guard let bytes else { return nil }
        return .data(mimeType: mimeType, bytes)
    }
}

extension MCPValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension MCPValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension MCPValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension MCPValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension MCPValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension MCPValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MCPValue...) { self = .array(elements) }
}
extension MCPValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, MCPValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, value in value }))
    }
}

/// Discovery fields for Opal's fixed, unannotated integration-tool catalog.
public struct MCPTool: Hashable, Sendable, Codable {
    public let name: String
    public let description: String?
    public let inputSchema: MCPValue
    public let outputSchema: MCPValue?
    public let annotations: [String: MCPValue]

    public init(name: String, description: String?, inputSchema: MCPValue,
                outputSchema: MCPValue? = nil, annotations: [String: MCPValue] = [:]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }

    private enum CodingKeys: String, CodingKey { case name, description, inputSchema, outputSchema, annotations }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        name = try fields.decode(String.self, forKey: .name)
        description = try fields.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try fields.decode(MCPValue.self, forKey: .inputSchema)
        outputSchema = try fields.decodeIfPresent(MCPValue.self, forKey: .outputSchema)
        annotations = try fields.decodeIfPresent([String: MCPValue].self, forKey: .annotations) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(name, forKey: .name)
        try fields.encode(description, forKey: .description)
        try fields.encode(inputSchema, forKey: .inputSchema)
        try fields.encodeIfPresent(outputSchema, forKey: .outputSchema)
        if !annotations.isEmpty { try fields.encode(annotations, forKey: .annotations) }
    }
}

/// The adapter exposes text plus a structured JSON value, not arbitrary media content.
public enum MCPToolContent: Hashable, Sendable, Codable {
    case text(text: String, annotations: MCPValue?, _meta: MCPValue?)

    private enum CodingKeys: String, CodingKey { case type, text, annotations, _meta }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard try fields.decode(String.self, forKey: .type) == "text" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: fields, debugDescription: "Unsupported tool content")
        }
        self = .text(text: try fields.decode(String.self, forKey: .text),
                     annotations: try fields.decodeIfPresent(MCPValue.self, forKey: .annotations),
                     _meta: try fields.decodeIfPresent(MCPValue.self, forKey: ._meta))
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let annotations, let meta):
            try fields.encode("text", forKey: .type)
            try fields.encode(text, forKey: .text)
            try fields.encodeIfPresent(annotations, forKey: .annotations)
            try fields.encodeIfPresent(meta, forKey: ._meta)
        }
    }
}

public struct MCPToolResult: Hashable, Sendable, Codable {
    public let content: [MCPToolContent]
    public let structuredContent: MCPValue?
    public let isError: Bool?
    public let _meta: MCPValue?

    public init(content: [MCPToolContent] = [], structuredContent: MCPValue? = nil,
                isError: Bool? = nil, _meta: MCPValue? = nil) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
        self._meta = _meta
    }
}
