public enum ServiceAvailability: String, Codable, Sendable, Equatable {
    case unavailable
    case recoveryRequired
    case restricted
    case enabled
}

public struct ServiceStatus: Codable, Sendable, Equatable {
    public static let currentProtocolVersion = 1
    public let protocolVersion: Int
    public let availability: ServiceAvailability

    public init(protocolVersion: Int = currentProtocolVersion, availability: ServiceAvailability) {
        self.protocolVersion = protocolVersion
        self.availability = availability
    }
}

public enum ClientFailure: Error, Sendable, Equatable {
    case unavailable
    case incompatibleProtocol
}
