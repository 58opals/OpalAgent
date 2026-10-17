import AgentValues

/// A transport seam. No installed or authenticated transport is provided by this package.
public protocol ServiceTransport: Sendable {
    func status(protocolVersion: Int) async throws -> ServiceStatus
}

public struct ServiceClient: Sendable {
    private let transport: any ServiceTransport

    public init(transport: any ServiceTransport) {
        self.transport = transport
    }

    public func status() async throws -> ServiceStatus {
        let response = try await transport.status(protocolVersion: ServiceStatus.currentProtocolVersion)
        guard response.protocolVersion == ServiceStatus.currentProtocolVersion else {
            throw ClientFailure.incompatibleProtocol
        }
        return response
    }
}

public struct UnavailableTransport: ServiceTransport {
    public init() {}

    public func status(protocolVersion: Int) async throws -> ServiceStatus {
        throw ClientFailure.unavailable
    }
}
