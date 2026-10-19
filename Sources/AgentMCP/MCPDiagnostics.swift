import AgentValues
import OpalDiagnostics

/// Only fixed adapter-owned classifications are eligible for emission.
enum MCPDiagnostics {
    private static let logger = OpalDiagnostics.logger(category: "agent.mcp")
    enum ToolStage: String { case method, input, result }
    enum TransportFailure: String {
        case connection, incompleteFrame, read, frameSize, emptyFrame, capacity, send, write
    }
    static func toolFailed(stage: ToolStage, reason: ServiceProblemCode) {
        record(event: "tool_failed") {
            [.publicField("stage", value: stage.rawValue), .publicField("reason", value: reason.rawValue)]
        }
    }
    static func transportFailed(_ reason: TransportFailure) {
        record(event: "transport_failed") { [.publicField("reason", value: reason.rawValue)] }
    }
    static func protocolRejected(code: Int) {
        record(event: "protocol_rejected") {
            let reason: String
            switch code {
            case -32700: reason = "parse_error"
            case -32600: reason = "invalid_request"
            case -32601: reason = "method_not_found"
            case -32602: reason = "invalid_parameters"
            default: reason = "request_failed"
            }
            return [.publicField("reason", value: reason)]
        }
    }
    private static func record(event: OpalDiagnostics.Event, fields: () -> [OpalDiagnostics.Field]) {
        guard logger.isEnabled(level: .notice) else { return }
        logger.record(event: event, level: .notice, traceID: OpalDiagnostics.TraceID(), fields: fields)
    }
}
