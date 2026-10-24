import CoreFoundation
import Foundation

/// The single profile, initialization-handoff and request-admission state machine.
actor ProfileTransport: MCPTransport {
    static let versions: Set<String> = ["2025-11-25", "2025-06-18"]
    private enum Phase { case initialize, initializing(String), initializedNotification, ready, closed }
    private var phase: Phase = .initialize
    private let base: any MCPTransport
    private var reader: Task<Void, Never>?
    private var active: Set<String> = []
    private var usedIDs: Set<String> = []
    private var sendingResponses = 0
    private var outputWaiter: CheckedContinuation<Void, Never>?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(base: any MCPTransport) {
        self.base = base
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(MCPBounds.concurrentRequests))
    }
    func connect() async throws {
        try await base.connect()
        reader = Task {
            do {
                for try await frame in await base.receive() {
                    try Task.checkCancellation()
                    await process(frame)
                    if case .closed = phase { break }
                }
            } catch { /* Closing a transport never projects an arbitrary error. */ }
            continuation.finish()
        }
    }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }
    func disconnect() async {
        phase = .closed
        outputWaiter?.resume(); outputWaiter = nil
        continuation.finish()
        reader?.cancel()
        await base.disconnect()
        await reader?.value
        reader = nil
    }
    func send(_ data: Data) async throws {
        if case .closed = phase { throw MCPTransportError.connectionClosed }
        try await sendOpen(data)
    }
    private func sendOpen(_ data: Data) async throws {
        guard data.count <= MCPBounds.outputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = Self.idKey(object["id"]) else { throw MCPTransportError.connectionClosed }
        // Protocol failures never reflect developer descriptions or supplied fields.
        let safe: Data
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? -32603
            safe = try Self.error(id: object["id"], code: code)
        } else { safe = data }
        sendingResponses += 1
        defer {
            sendingResponses -= 1
            if sendingResponses == 0 { outputWaiter?.resume(); outputWaiter = nil }
        }
        do {
            try await base.send(safe)
            if case .initializing(let initializingID) = phase, initializingID == key {
                if object["result"] != nil { phase = .initializedNotification }
                else { phase = .initialize }
            }
            active.remove(key)
        } catch { await close(); throw MCPTransportError.connectionClosed }
    }
    private func process(_ frame: Data) async {
        // Await the observable response handoff before admitting the next frame. The lower
        // transports retain only bounded queues while this single reader is suspended.
        if sendingResponses > 0 { await withCheckedContinuation { outputWaiter = $0 } }
        if Task.isCancelled { return }
        if case .closed = phase { return }
        guard frame.count <= MCPBounds.inputBytes else { await close(); return }
        var object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                try await rejectEnvelope(code: -32600); return
            }
            object = decoded
        } catch { try? await rejectEnvelope(code: -32700); return }
        let id = object["id"]
        let requestKey = Self.idKey(id)
        guard Set(object.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
              object["jsonrpc"] as? String == "2.0", let method = object["method"] as? String,
              method.utf8.count <= 128, id == nil || requestKey != nil else {
            if id == nil, object["jsonrpc"] as? String == "2.0", object["method"] is String {
                return // An id-less notification remains silent even with invalid fields.
            }
            if requestKey != nil { try? await reject(id, code: -32600) }
            else { try? await rejectEnvelope(code: -32600) }
            return
        }
        if let requestKey {
            // MCP requires session-unique IDs. Bound their retention and require reconnect
            // at the session limit rather than risking handler-map aliasing.
            guard usedIDs.count < 4096, usedIDs.insert(requestKey).inserted else {
                try? await reject(id, code: -32600); await close(); return
            }
        }
        let params = object["params"] as? [String: Any]
        guard object["params"] == nil || params != nil else { try? await reject(id, code: -32602); return }
        do {
            if method == "initialize" {
                guard case .initialize = phase, let requestKey else { try await reject(id, code: -32600); return }
                guard let parameters = params,
                      Set(parameters.keys).isSubset(of: ["protocolVersion", "capabilities", "clientInfo", "_meta"]),
                      let version = parameters["protocolVersion"] as? String,
                      let capabilities = parameters["capabilities"] as? [String: Any],
                      let info = parameters["clientInfo"] as? [String: Any],
                      Self.validClientInfo(info), Self.validKnownCapabilities(capabilities),
                      parameters["_meta"] == nil || parameters["_meta"] is [String: Any] else {
                    try await reject(id, code: -32602); return
                }
                guard Self.versions.contains(version) else {
                    try await reject(id, code: -32602, supportedVersions: true)
                    await close()
                    return
                }
                // The former typed SDK decoder rejected malformed optional metadata with
                // a sanitized internal error. Keep that wire contract without its decoder.
                guard Self.validOptionalClientInfo(info) else {
                    try await reject(id, code: -32603); return
                }
                phase = .initializing(requestKey)
            } else if method == "notifications/initialized" {
                guard id == nil, case .initializedNotification = phase, Self.onlyMetadata(params) else {
                    try await reject(id, code: -32600); return
                }
                phase = .ready
            } else if method == "ping" {
                guard requestKey != nil, Self.onlyMetadata(params) else { try await reject(id, code: -32602); return }
            } else {
                guard case .ready = phase else { try await reject(id, code: -32600); return }
                switch method {
                case "tools/list":
                    guard requestKey != nil, Self.onlyMetadata(params) else { try await reject(id, code: -32602); return }
                case "tools/call":
                    guard requestKey != nil, let params,
                          Set(params.keys).isSubset(of: ["name", "arguments", "_meta"]),
                          let name = params["name"] as? String, name.utf8.count <= 128,
                          params["arguments"] == nil || params["arguments"] is [String: Any],
                          params["_meta"] == nil || params["_meta"] is [String: Any] else {
                        try await reject(id, code: -32602); return
                    }
                case "notifications/cancelled":
                    guard id == nil, let params, Set(params.keys).isSubset(of: ["requestId", "reason", "_meta"]),
                          params["_meta"] == nil || params["_meta"] is [String: Any],
                          Self.idKey(params["requestId"]) != nil,
                          params["reason"] == nil || params["reason"] is String else { return }
                    // Cancelled requests need not reply. Retain their slot until reconnect,
                    // preventing repeated cancellation from admitting unbounded handler tasks.
                default:
                    if id != nil { try await reject(id, code: -32601) }
                    return
                }
            }
            if let requestKey {
                guard active.count < MCPBounds.concurrentRequests, active.insert(requestKey).inserted else {
                    try await reject(id, code: -32600); await close(); return
                }
            }
            let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            switch continuation.yield(encoded) {
            case .enqueued: break
            case .dropped, .terminated: await close()
            @unknown default: await close()
            }
        } catch { await close() }
    }
    private func close() async {
        phase = .closed
        outputWaiter?.resume(); outputWaiter = nil
        continuation.finish()
        await base.disconnect()
    }
    private func reject(_ id: Any?, code: Int, supportedVersions: Bool = false) async throws {
        // A recognized id-less notification never receives a response, including on error.
        guard let id else { return }
        try await base.send(Self.error(id: id, code: code, supportedVersions: supportedVersions))
        MCPDiagnostics.protocolRejected(code: code)
    }
    private func rejectEnvelope(code: Int) async throws {
        try await base.send(Self.error(id: nil, code: code))
        MCPDiagnostics.protocolRejected(code: code)
    }
    private static func error(id: Any?, code: Int, supportedVersions: Bool = false) throws -> Data {
        let message: String
        switch code {
        case -32700: message = "Parse error"
        case -32600: message = "Invalid request"
        case -32601: message = "Method not found"
        case -32602: message = "Invalid parameters"
        default: message = "Request failed"
        }
        var error: [String: Any] = ["code": code, "message": message]
        if supportedVersions { error["data"] = ["supportedVersions": versions.sorted()] }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error], options: [.sortedKeys])
    }
    private static func idKey(_ value: Any?) -> String? {
        if let string = value as? String, string.utf8.count <= 128 { return "s:" + string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite, abs(number.doubleValue) <= 9_007_199_254_740_991,
           number.doubleValue.rounded(.towardZero) == number.doubleValue { return "n:" + String(number.int64Value) }
        return nil
    }
    // Common protocol metadata is informational; it never supplies wallet authority.
    // This catalog is returned in one page, so no continuation cursor is issued or accepted.
    private static func onlyMetadata(_ params: [String: Any]?) -> Bool {
        guard let params else { return true }
        return Set(params.keys).isSubset(of: ["_meta"]) && (params["_meta"] == nil || params["_meta"] is [String: Any])
    }
    private static func validClientInfo(_ info: [String: Any]) -> Bool {
        guard let name = info["name"] as? String, let version = info["version"] as? String,
              !name.isEmpty, name.utf8.count <= 256, version.utf8.count <= 128 else { return false }
        // Implementation metadata never identifies a principal.
        return true
    }
    private static func validOptionalClientInfo(_ info: [String: Any]) -> Bool {
        func optional(_ value: Any?, matches predicate: (Any) -> Bool) -> Bool {
            guard let value, !(value is NSNull) else { return true }
            return predicate(value)
        }
        for key in ["title", "description", "websiteUrl"] {
            guard optional(info[key], matches: { $0 is String }) else { return false }
        }
        return optional(info["icons"]) { value in
            guard let icons = value as? [[String: Any]] else { return false }
            return icons.allSatisfy { icon in
                guard icon["src"] is String,
                      optional(icon["mimeType"], matches: { $0 is String }),
                      optional(icon["sizes"], matches: { $0 is [String] }),
                      optional(icon["theme"], matches: { ($0 as? String).map { ["light", "dark"].contains($0) } == true }) else {
                    return false
                }
                return true
            }
        }
    }
    private static func validKnownCapabilities(_ caps: [String: Any]) -> Bool {
        func emptyObjects(_ value: Any, keys: Set<String>) -> Bool {
            guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else { return false }
            return object.values.allSatisfy { ($0 as? [String: Any])?.isEmpty == true }
        }
        if let roots = caps["roots"] {
            guard let object = roots as? [String: Any], Set(object.keys).isSubset(of: ["listChanged"]) else { return false }
            if let value = object["listChanged"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            }
        }
        if let sampling = caps["sampling"], !emptyObjects(sampling, keys: ["tools", "context"]) { return false }
        if let elicitation = caps["elicitation"], !emptyObjects(elicitation, keys: ["form", "url"]) { return false }
        if let experimental = caps["experimental"] {
            guard let object = experimental as? [String: Any], object.values.allSatisfy({ $0 is String }) ||
                    (!object.isEmpty && object.values.allSatisfy({ $0 is [String: Any] })) else { return false }
        }
        return true
    }
}
