import Foundation
import Testing
import AgentValues

@Test(arguments: CapabilityMethod.allCases)
func capabilityRequestsRoundTripEveryIntegrationMethod(_ method: CapabilityMethod) throws {
    let (call, _) = try capabilityFixture(method)
    let request = CapabilityRequest(call: call)
    let encoded = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(CapabilityRequest.self, from: encoded) == request)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["method"] as? String == method.rawValue)
    #expect(object["protocolVersion"] as? Int == ServiceStatus.currentProtocolVersion)
    #expect(Set(object.keys) == ["method", "protocolVersion", "parameters"])
}

@Test(arguments: CapabilityMethod.allCases)
func capabilityRequestsRejectForgedAuthorityInEveryPayload(_ method: CapabilityMethod) throws {
    let (call, _) = try capabilityFixture(method)
    var object = try requestObject(call)
    var parameters = try #require(object["parameters"] as? [String: Any])
    parameters["approved"] = true
    object["parameters"] = parameters
    #expect(throws: CapabilityFailure.invalidRequest) { try decodeRequest(object) }
}

@Test(arguments: ["envelope", "account", "wallet", "page", "lookup"])
func capabilityRequestsRejectNestedUnknownWalletFields(_ position: String) throws {
    let (call, _) = try capabilityFixture(position == "page" ? .listTransactions : .preparePayment)
    var object = try requestObject(call)
    var parameters = try #require(object["parameters"] as? [String: Any])
    switch position {
    case "envelope": object["owner"] = true
    case "account":
        var account = try #require(parameters["account"] as? [String: Any]); account["owner"] = true; parameters["account"] = account
    case "wallet":
        var account = try #require(parameters["account"] as? [String: Any])
        var wallet = try #require(account["wallet"] as? [String: Any]); wallet["approved"] = true
        account["wallet"] = wallet; parameters["account"] = account
    case "page":
        var page = try #require(parameters["page"] as? [String: Any]); page["owner"] = true; parameters["page"] = page
    default:
        let account = try capabilityAccount()
        object = try requestObject(.getOperation(.operation(try OperationSelector(account: account, operationID: "op"))))
        parameters = try #require(object["parameters"] as? [String: Any])
        var operation = try #require(parameters["operation"] as? [String: Any]); operation["approved"] = true; parameters["operation"] = operation
    }
    if position != "envelope" { object["parameters"] = parameters }
    #expect(throws: CapabilityFailure.invalidRequest) { try decodeRequest(object) }
}

@Test(arguments: ["", "ABCDEF0123456789abcdef0123456789", "0123456789abcdef0123456789abcdeg", "0123456789abcdef0123456789abcdef ", "0123", "0123456789abcdef0123456789abcdef00"])
func capabilityKeysRejectMalformedOrNormalizedAlternatives(_ value: String) {
    #expect(throws: CapabilityFailure.invalidRequest) { try RequestKey(value) }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(RequestKey.self, from: JSONEncoder().encode(value)) }
}

@Test(arguments: [0, -1, 41, Int.max])
func capabilityPagesRejectUnboundedRequests(_ limit: Int) {
    #expect(throws: CapabilityFailure.invalidRequest) { try PageRequest(limit: limit) }
    #expect(throws: CapabilityFailure.invalidRequest) {
        try JSONDecoder().decode(PageRequest.self, from: Data("{\"limit\":\(limit)}".utf8))
    }
}

@Test func capabilityRequestsRejectNonintegerSatoshisAndUnknownVersionsOrMethods() throws {
    var object = try requestObject(capabilityFixture(.preparePayment).0)
    var parameters = try #require(object["parameters"] as? [String: Any])
    parameters["amountSatoshis"] = 1.5
    object["parameters"] = parameters
    #expect(throws: (any Error).self) { try decodeRequest(object) }
    parameters["amountSatoshis"] = "500"
    object["parameters"] = parameters
    #expect(throws: (any Error).self) { try decodeRequest(object) }
    object = try requestObject(capabilityFixture(.getBalance).0)
    object["protocolVersion"] = ServiceStatus.currentProtocolVersion + 1
    #expect(throws: ClientFailure.incompatibleProtocol) { try decodeRequest(object) }
    object["protocolVersion"] = ServiceStatus.currentProtocolVersion
    object["method"] = "approve_payment"
    #expect(throws: (any Error).self) { try decodeRequest(object) }
}

@Test func capabilityLookupUsesExactlyOneSelectorAndRetainsEffectNamespace() throws {
    let account = try capabilityAccount()
    let key = try RequestKey(String(repeating: "01", count: 16))
    let call = CapabilityCall.getOperation(.request(account: account, effect: .createReceiveRequest, key: key))
    #expect(try JSONDecoder().decode(CapabilityRequest.self, from: JSONEncoder().encode(CapabilityRequest(call: call))).call == call)
    var object = try requestObject(call)
    var parameters = try #require(object["parameters"] as? [String: Any])
    parameters["operation"] = ["account": try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)), "operationID": "op"]
    object["parameters"] = parameters
    #expect(throws: CapabilityFailure.invalidRequest) { try decodeRequest(object) }
}

@Test func capabilityNetworksAreExplicitAndMissingSnapshotStaysMissing() throws {
    #expect(Set(WalletNetwork.allCases.map(\.rawValue)) == ["mainnet", "testnet", "chipnet"])
    #expect(throws: (any Error).self) { try JSONDecoder().decode(WalletNetwork.self, from: Data("\"regtest\"".utf8)) }
    let projection = SyncStatusProjection(account: try capabilityAccount(), observation: nil)
    #expect(try JSONDecoder().decode(SyncStatusProjection.self, from: JSONEncoder().encode(projection)).observation == nil)
}

private func requestObject(_ call: CapabilityCall) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(CapabilityRequest(call: call))) as? [String: Any])
}
private func decodeRequest(_ object: [String: Any]) throws -> CapabilityRequest {
    try JSONDecoder().decode(CapabilityRequest.self, from: JSONSerialization.data(withJSONObject: object))
}
