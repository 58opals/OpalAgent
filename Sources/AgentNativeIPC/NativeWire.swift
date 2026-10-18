import AgentValues
import CryptoKit
import Foundation

public enum NativeFrameKind: String, Codable, Sendable {
    case hello, helloResponse, authenticate, authenticated, capabilityRequest, capabilityResponse
    case ownerRequest, ownerResponse, consentChallenge, consentProof, problem
}
public struct NativeFrame: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let kind: NativeFrameKind
    public let payload: Data
    public init(requestID: UUID, kind: NativeFrameKind, payload: Data) {
        self.protocolVersion = ServiceStatus.currentProtocolVersion; self.requestID = requestID; self.kind = kind; self.payload = payload
    }
}
public struct NativeHello: Codable, Sendable, Equatable {
    public let channel: NativeChannel
    public let connectionID: String
    public init(channel: NativeChannel, connectionID: String) { self.channel = channel; self.connectionID = connectionID }
}
public struct NativeConsentChallenge: Codable, Sendable, Equatable {
    public let connectionID: String
    public let nonce: UUID
    public let purpose: String
    public let reviewCommitment: Data
    public init(connectionID: String, nonce: UUID, purpose: String, reviewCommitment: Data) {
        self.connectionID = connectionID; self.nonce = nonce; self.purpose = purpose; self.reviewCommitment = reviewCommitment
    }
}
public struct NativeConsentProof: Codable, Sendable, Equatable {
    public let challenge: NativeConsentChallenge
    public let authenticatedAt: Int64
    public init(challenge: NativeConsentChallenge, authenticatedAt: Int64) { self.challenge = challenge; self.authenticatedAt = authenticatedAt }
}
/// Implemented only by the trusted Wallet deputy. No default authentication result is supplied.
public protocol NativeWalletConsentProvider: Sendable {
    func authenticate(_ challenge: NativeConsentChallenge) async throws -> NativeConsentProof
}
public struct NativeOwnerPacket: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let frame: Data
    public let sensitive: Data?
    public init(frame: Data, sensitive: Data? = nil) { self.frame = frame; self.sensitive = sensitive }
    public var description: String { "<native owner packet>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["packet": "<redacted>"]) }
}
public enum NativeWire {
    public static let maximumFrameBytes = 1_048_576
    public static let maximumSensitiveBytes = 4096
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        // Inspect the closed DTO value graph before allocating JSON; the final byte cap
        // remains necessary because escaping and base64 expand its representation.
        var budget = EncodingBudget()
        try budget.inspect(value, depth: 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumFrameBytes else { throw NativeIPCFailure.malformedFrame }; return data
    }
    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumFrameBytes else { throw NativeIPCFailure.malformedFrame }
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            let original = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let canonical = try JSONSerialization.jsonObject(with: encode(decoded), options: [.fragmentsAllowed])
            try knownFields(original, canonical, depth: 0)
            return decoded
        } catch let error as NativeIPCFailure { throw error }
        catch { throw NativeIPCFailure.malformedFrame }
    }
    public static func frame<T: Encodable>(_ value: T, kind: NativeFrameKind, requestID: UUID) throws -> Data {
        try encode(NativeFrame(requestID: requestID, kind: kind, payload: encode(value)))
    }
    public static func unpack(_ bytes: Data, kind: NativeFrameKind? = nil, requestID: UUID? = nil) throws -> NativeFrame {
        let value = try decode(NativeFrame.self, from: bytes)
        guard value.protocolVersion == ServiceStatus.currentProtocolVersion else { throw NativeIPCFailure.incompatibleProtocol }
        guard requestID.map({ value.requestID == $0 }) ?? true else { throw NativeIPCFailure.malformedFrame }
        if value.kind == .problem { throw try decode(ServiceProblem.self, from: value.payload) }
        guard kind.map({ value.kind == $0 }) ?? true else { throw NativeIPCFailure.malformedFrame }
        return value
    }
    public static func problem(_ code: ServiceProblemCode, requestID: UUID) -> Data {
        // This fixed, bounded value has no encoding failure or source-error description to disclose.
        (try? frame(ServiceProblem(code), kind: .problem, requestID: requestID)) ?? Data()
    }
    public static func capabilityRequest(_ request: CapabilityRequest, requestID: UUID) throws -> Data {
        try frame(request, kind: .capabilityRequest, requestID: requestID)
    }
    public static func decodeCapabilityRequest(_ bytes: Data) throws -> (UUID, CapabilityRequest) {
        let value = try unpack(bytes, kind: .capabilityRequest)
        return (value.requestID, try decode(CapabilityRequest.self, from: value.payload))
    }
    public static func capabilityResponse(_ response: CapabilityResponse, requestID: UUID) throws -> Data {
        try frame(response, kind: .capabilityResponse, requestID: requestID)
    }
    public static func decodeCapabilityResponse(_ bytes: Data, requestID: UUID) throws -> CapabilityResponse {
        let value = try unpack(bytes, requestID: requestID)
        guard value.kind == .capabilityResponse else { throw NativeIPCFailure.malformedFrame }
        return try decode(CapabilityResponse.self, from: value.payload)
    }
    public static func reviewCommitment(_ call: OwnerControlCall) throws -> Data {
        switch call {
        case .approveExactPayment(let context), .rejectExactPayment(let context): return Data(SHA256.hash(data: try encode(context)))
        case .authorizeExactRelay(let request): return Data(SHA256.hash(data: try encode(request.context)))
        case .status, .inspectRecovery, .listAccounts, .listPayments, .paymentStatus, .reviewPreview, .reviewRelay, .relayReceipt: return Data()
        default:
            // The fixed correlation ID makes identical requests stable. The separate slot is
            // represented only by a presence marker and digest, never copied into this context.
            let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            let packet = try ownerRequest(OwnerControlRequest(call: call), requestID: zero)
            var hash = SHA256()
            hash.update(data: Data("OpalAgent.NativeOwnerConsent.v1\0".utf8))
            hash.update(data: packet.frame)
            if let sensitive = packet.sensitive {
                hash.update(data: Data([1])); hash.update(data: Data(SHA256.hash(data: sensitive)))
            } else { hash.update(data: Data([0])) }
            return Data(hash.finalize())
        }
    }
    private struct EncodingBudget {
        var nodes = 0
        var bytes = 0
        mutating func inspect(_ value: Any, depth: Int) throws {
            nodes += 1
            guard depth <= 32, nodes <= 16_384 else { throw NativeIPCFailure.malformedFrame }
            if let value = value as? Data {
                guard value.count <= maximumFrameBytes else { throw NativeIPCFailure.malformedFrame }
                bytes += value.count
            } else if let value = value as? String {
                guard value.utf8.count <= maximumFrameBytes else { throw NativeIPCFailure.malformedFrame }
                bytes += value.utf8.count
            } else {
                for child in Mirror(reflecting: value).children { try inspect(child.value, depth: depth + 1) }
            }
            guard bytes <= maximumFrameBytes else { throw NativeIPCFailure.malformedFrame }
        }
    }
    private static func knownFields(_ original: Any, _ canonical: Any, depth: Int) throws {
        guard depth <= 32 else { throw NativeIPCFailure.malformedFrame }
        if let input = original as? [String: Any], let output = canonical as? [String: Any] {
            guard Set(input.keys).isSubset(of: Set(output.keys)) else { throw NativeIPCFailure.malformedFrame }
            for (key, value) in input {
                guard let expected = output[key] else { throw NativeIPCFailure.malformedFrame }
                try knownFields(value, expected, depth: depth + 1)
            }
        } else if let input = original as? [Any], let output = canonical as? [Any] {
            guard input.count == output.count else { throw NativeIPCFailure.malformedFrame }
            for (left, right) in zip(input, output) { try knownFields(left, right, depth: depth + 1) }
        }
    }
}
