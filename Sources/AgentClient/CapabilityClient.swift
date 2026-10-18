import AgentValues
import Foundation

/// A separately injected capability channel. Implementations must authenticate the service and caller.
/// The transport does not receive caller-asserted owner authority or approval flags.
public protocol CapabilityTransport: Sendable {
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse
}

/// Checks protocol, result shape and request context. This does not replace service authorization,
/// BCH address normalization, snapshot verification or payment approval/admission checks.
public struct CapabilityClient: Sendable {
    private let transport: any CapabilityTransport
    public init(transport: any CapabilityTransport = UnavailableCapabilityTransport()) { self.transport = transport }

    public func call(_ call: CapabilityCall) async throws -> CapabilityResult {
        let response = try await transport.send(CapabilityRequest(call: call))
        guard response.protocolVersion == ServiceStatus.currentProtocolVersion else { throw ClientFailure.incompatibleProtocol }
        guard response.result.method == call.method else { throw CapabilityFailure.invalidResponse }
        try validate(response.result, for: call)
        return response.result
    }
}

public struct UnavailableCapabilityTransport: CapabilityTransport {
    public init() {}
    public func send(_ request: CapabilityRequest) async throws -> CapabilityResponse { throw ClientFailure.unavailable }
}

func requireCapabilityResponse(_ valid: Bool) throws {
    guard valid else { throw CapabilityFailure.invalidResponse }
}
func validCapabilityIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 2048 && !value.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
    })
}
func validCapabilityHex(_ value: String, byteCount: Int? = nil) -> Bool {
    !value.isEmpty && value.utf8.count.isMultiple(of: 2) && value.utf8.count <= 20_000 &&
        (byteCount.map { value.utf8.count == $0 * 2 } ?? true) &&
        value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func validateCapabilityObservation(_ observation: SnapshotObservation) throws {
    try requireCapabilityResponse(observation.observedAt >= 0 && validCapabilityIdentifier(observation.providerID) &&
        validCapabilityIdentifier(observation.viewID) && validCapabilityIdentifier(observation.chainTip))
}
func validateCapabilityReadiness(_ readiness: AccountReadiness) throws {
    try requireCapabilityResponse(Set(readiness.blockers).count == readiness.blockers.count &&
        (readiness.state != .ready || readiness.blockers.isEmpty) && (readiness.state != .blocked || !readiness.blockers.isEmpty))
}
private func validate<Item>(_ page: CapabilityPage<Item>, request: PageRequest) throws {
    try requireCapabilityResponse(page.items.count <= request.limit && page.items.count <= PageRequest.maximumCount)
    try requireCapabilityResponse(page.nextCursor.map(validCapabilityIdentifier) ?? true)
}
private func validate(_ outpoint: Outpoint) throws { try requireCapabilityResponse(validCapabilityHex(outpoint.transactionID, byteCount: 32)) }
func validateCapabilityOperation(_ operation: OperationProjection) throws {
    switch operation {
    case .synchronization(let value):
        if let observation = value.observation { try validateCapabilityObservation(observation) }
        try requireCapabilityResponse((value.state != .completed || value.observation != nil) &&
            ((value.state == .closed) == (value.closeReason != nil)))
    case .receive(let value):
        try requireCapabilityResponse((value.state == .allocated) == (value.allocation != nil) &&
            ((value.state == .closed) == (value.closeReason != nil)))
        if let allocation = value.allocation {
            try requireCapabilityResponse(!allocation.address.isEmpty && allocation.address.utf8.count <= 512 &&
                allocation.address == allocation.address.trimmingCharacters(in: .whitespacesAndNewlines) && allocation.index < 0x8000_0000)
        }
    case .payment(let value):
        try requireCapabilityResponse(value.identity.selector.account == value.request.account && value.identity.requestKey == value.request.requestKey)
        if [.prepared, .pendingApproval, .ready, .submitting, .uncertain, .accepted].contains(value.state) {
            try requireCapabilityResponse(value.preview != nil)
        }
        if let preview = value.preview { try validateCapabilityPreview(preview, amountSatoshis: value.request.amountSatoshis) }
        try requireCapabilityResponse(value.ordinaryAdmissions <= 3 &&
            (value.state != .closed || value.terminalReason != nil) &&
            (value.lastReconciliationAt.map({ $0 >= 0 }) ?? true))
        if let transactionID = value.transactionID { try requireCapabilityResponse(validCapabilityHex(transactionID, byteCount: 32)) }
        if let observation = value.evidence.observation { try validateCapabilityObservation(observation) }
        for closure in value.closures { try requireCapabilityResponse(closure.evidenceRevision <= value.evidence.revision) }
        if let attempt = value.latestAttempt { try validateCapabilityAttempt(attempt) }
        if value.ordinaryAdmissions > 0 { try requireCapabilityResponse(value.latestAttempt != nil) }

    }
}
func validateCapabilityPreview(_ preview: PaymentPreviewProjection, amountSatoshis: Int64? = nil) throws {
    try requireCapabilityResponse((amountSatoshis.map { preview.amountSatoshis == $0 } ?? true) &&
        (1...2_100_000_000_000_000).contains(preview.amountSatoshis) &&
        (0...2_100_000_000_000_000).contains(preview.feeSatoshis) && preview.leaseDeadline > 0 &&
        !preview.canonicalDestinationAddress.isEmpty && preview.canonicalDestinationAddress.utf8.count <= 512 &&
        validCapabilityHex(preview.destinationScriptHex) && validCapabilityHex(preview.templateDigest, byteCount: 32) &&
        !preview.selectedInputs.isEmpty && Set(preview.selectedInputs).count == preview.selectedInputs.count)
    for input in preview.selectedInputs { try validate(input) }
    for change in preview.change {
        try requireCapabilityResponse(validCapabilityHex(change.lockingScriptHex) && (0...2_100_000_000_000_000).contains(change.amountSatoshis))
    }
}
func validateCapabilityAttempt(_ attempt: RelayAttemptProjection) throws {
    try requireCapabilityResponse(validCapabilityIdentifier(attempt.attemptID) && attempt.number > 0 && attempt.admittedAt >= 0 &&
        (attempt.nextEligibleAt.map { $0 >= attempt.admittedAt } ?? true))
}
private func bind(_ operation: OperationProjection, to selector: OperationSelector) throws {
    try validateCapabilityOperation(operation)
    try requireCapabilityResponse(operation.identity.selector == selector)
}
private func bind(_ operation: OperationProjection, to request: KeyedAccountRequest, effect: EffectKind) throws {
    try validateCapabilityOperation(operation)
    try requireCapabilityResponse(operation.identity.selector.account == request.account && operation.identity.requestKey == request.requestKey && operation.effect == effect)
}
private func validate(_ result: CapabilityResult, for call: CapabilityCall) throws {
    switch (call, result) {
    case (.listWallets(let request), .listWallets(let page)):
        try validate(page, request: request)
        try requireCapabilityResponse(Set(page.items.map(\.scope)).count == page.items.count)
    case (.listAccounts(let request), .listAccounts(let value)):
        try requireCapabilityResponse(value.wallet == request.wallet && value.page.items.allSatisfy { $0.scope.wallet == request.wallet })
        try validate(value.page, request: request.page)
        try requireCapabilityResponse(Set(value.page.items.map(\.scope)).count == value.page.items.count)
        for item in value.page.items { try validateCapabilityReadiness(item.readiness) }
    case (.getBalance(let account), .getBalance(let value)):
        try requireCapabilityResponse(value.account == account && (0...2_100_000_000_000_000).contains(value.totalSatoshis))
        try validateCapabilityObservation(value.observation); try validateCapabilityReadiness(value.readiness)
    case (.listTransactions(let request), .listTransactions(let value)):
        try requireCapabilityResponse(value.account == request.account)
        try validateCapabilityObservation(value.observation); try validateCapabilityReadiness(value.readiness); try validate(value.page, request: request.page)
        try requireCapabilityResponse(Set(value.page.items.map(\.transactionID)).count == value.page.items.count)
        for item in value.page.items {
            try requireCapabilityResponse(validCapabilityHex(item.transactionID, byteCount: 32) &&
                (item.deltaSatoshis.map { (-2_100_000_000_000_000...2_100_000_000_000_000).contains($0) } ?? true))
        }
    case (.listUTXOs(let request), .listUTXOs(let value)):
        try requireCapabilityResponse(value.account == request.account)
        try validateCapabilityObservation(value.observation); try validateCapabilityReadiness(value.readiness); try validate(value.page, request: request.page)
        try requireCapabilityResponse(Set(value.page.items.map(\.outpoint)).count == value.page.items.count)
        for item in value.page.items {
            try validate(item.outpoint); try requireCapabilityResponse((0...2_100_000_000_000_000).contains(item.amountSatoshis))
            if case .visibleOperation(let id) = item.reservation { try requireCapabilityResponse(validCapabilityIdentifier(id)) }
        }
    case (.getSyncStatus(let account), .getSyncStatus(let value)):
        try requireCapabilityResponse(value.account == account)
        try validateCapabilityReadiness(value.readiness)
        if let observation = value.observation { try validateCapabilityObservation(observation) }
    case (.synchronizeAccount(let request), .synchronizeAccount(let value)):
        try bind(.synchronization(value), to: request, effect: .synchronizeAccount)
    case (.createReceiveRequest(let request), .createReceiveRequest(let value)):
        try bind(.receive(value), to: request, effect: .createReceiveRequest)
    case (.preparePayment(let request), .preparePayment(let value)):
        try bind(.payment(value), to: KeyedAccountRequest(account: request.account, requestKey: request.requestKey), effect: .preparePayment)
        // Equivalent supported address encodings may replay the same normalized request.
        // Only the authenticated service can prove canonical address/network/script correspondence.
        try requireCapabilityResponse(value.request.amountSatoshis == request.amountSatoshis &&
            value.request.feeRateSatoshisPerByte == request.feeRateSatoshisPerByte && value.request.expiresAt == request.expiresAt)
    case (.submitPayment(let selector), .submitPayment(let value)):
        try bind(.payment(value), to: selector)
    case (.getOperation(let lookup), .getOperation(let value)):
        switch lookup {
        case .operation(let selector): try bind(value, to: selector)
        case .request(let account, let effect, let key): try bind(value, to: KeyedAccountRequest(account: account, requestKey: key), effect: effect)
        }
    case (.cancelOperation(let selector), .cancelOperation(let value)):
        try bind(value, to: selector)
    default: throw CapabilityFailure.invalidResponse
    }
}
