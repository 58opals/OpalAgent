import Testing
import AgentValues
import AgentClient

private struct FixedTransport: ServiceTransport {
    let version: Int
    func status(protocolVersion: Int) async throws -> ServiceStatus {
        ServiceStatus(protocolVersion: version, availability: .restricted)
    }
}

@Test func missingProductionTransportFailsClosed() async {
    await #expect(throws: ClientFailure.unavailable) {
        try await ServiceClient(transport: UnavailableTransport()).status()
    }
}

@Test func incompatibleResponsesCannotBecomeReady() async {
    await #expect(throws: ClientFailure.incompatibleProtocol) {
        try await ServiceClient(transport: FixedTransport(version: 2)).status()
    }
    let status = try? await ServiceClient(transport: FixedTransport(version: 1)).status()
    #expect(status?.availability == .restricted)
}
