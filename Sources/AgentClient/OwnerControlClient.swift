import AgentValues

/// A separate owner endpoint. Its implementation authenticates the native owner peer and obtains fresh consent for sensitive actions.
/// No owner transport or consent fallback is installed by this package.
public protocol OwnerControlTransport: Sendable {
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse
}
public struct UnavailableOwnerControlTransport: OwnerControlTransport {
    public init() {}
    public func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse { throw ClientFailure.unavailable }
}
public struct OwnerControlClient: Sendable {
    private let transport: any OwnerControlTransport
    public init(transport: any OwnerControlTransport = UnavailableOwnerControlTransport()) { self.transport = transport }
    public func call(_ call: OwnerControlCall) async throws -> OwnerControlResult {
        try validateOwnerInput(call)
        let response = try await transport.send(OwnerControlRequest(call: call))
        guard response.protocolVersion == ServiceStatus.currentProtocolVersion else { throw ClientFailure.incompatibleProtocol }
        guard response.result.method == call.method else { throw CapabilityFailure.invalidResponse }
        try validateOwnerResult(response.result, for: call)
        return response.result
    }
}
private func validateOwnerInput(_ call: OwnerControlCall) throws {
    // Expected context is data to compare, never proof of authenticated owner authority.
    switch call {
    case .approveExactPayment(let context), .rejectExactPayment(let context):
        do { try validatePreviewContext(context) } catch { throw CapabilityFailure.invalidRequest }
    case .authorizeExactRelay(let request):
        do { try validateRelayContext(request.context) } catch { throw CapabilityFailure.invalidRequest }
    case .setApprovalPolicy(let request):
        guard request.expectedRevision > 0 else { throw CapabilityFailure.invalidRequest }
    case .rotateGrant(let selector), .revokeGrant(let selector):
        guard validCapabilityIdentifier(selector.grantID) else { throw CapabilityFailure.invalidRequest }
    default: break
    }
}
private func validatePreviewContext(_ context: ExactPreviewReviewContext) throws {
    try requireCapabilityResponse(validCapabilityHex(context.previewContextDigest, byteCount: 32) && context.walletGeneration > 0 &&
        context.policyRevision > 0 && validCapabilityIdentifier(context.originGrantID) && context.originCredentialGeneration > 0)
    try validateCapabilityPreview(context.preview)
}
private func validateRelayContext(_ context: ExactRelayReviewContext) throws {
    try requireCapabilityResponse(validCapabilityHex(context.transactionDigest, byteCount: 32) &&
        validCapabilityHex(context.accountLiabilityContextDigest, byteCount: 32) && context.walletGeneration > 0 && context.policyRevision > 0)
}
private func validateOwnerStatus(_ status: OwnerWalletStatus) throws {
    if let wallet = status.wallet {
        try requireCapabilityResponse(status.walletGeneration.map { $0 > 0 } ?? false)
        try requireCapabilityResponse(status.unresolvedOperations.allSatisfy { $0.account.wallet == wallet })
        if let policy = status.approvalPolicy { try requireCapabilityResponse(policy.wallet == wallet && policy.revision > 0) }
        try requireCapabilityResponse(status.grants.allSatisfy { $0.selector.wallet == wallet })
    } else {
        try requireCapabilityResponse(status.walletGeneration == nil && status.approvalPolicy == nil && status.unresolvedOperations.isEmpty && status.grants.isEmpty && status.custody == .absent)
        try requireCapabilityResponse(status.availability == .unavailable || status.availability == .recoveryRequired)
    }
    if status.availability == .enabled { try requireCapabilityResponse(status.history == .complete && status.wallet != nil) }
    try requireCapabilityResponse(Set(status.unresolvedOperations.map(\.operationID)).count == status.unresolvedOperations.count)
    try requireCapabilityResponse(Set(status.grants.map { $0.selector.grantID }).count == status.grants.count)
    for grant in status.grants { try validateGrant(grant) }
}
private func bindStatus(_ status: OwnerWalletStatus, wallet: WalletScope) throws {
    try validateOwnerStatus(status); try requireCapabilityResponse(status.wallet == wallet)
}
private func validateGrant(_ grant: GrantProjection) throws {
    try requireCapabilityResponse(validCapabilityIdentifier(grant.selector.grantID) && validCapabilityIdentifier(grant.integrationID) &&
        !grant.accountIDs.isEmpty && grant.accountIDs.allSatisfy(validCapabilityIdentifier) && Set(grant.accountIDs).count == grant.accountIDs.count &&
        !grant.scopes.isEmpty && Set(grant.scopes).count == grant.scopes.count && grant.credentialGeneration > 0 &&
        (grant.expiresAt.map { $0 > 0 } ?? true))
}
private func validateReceipt(_ receipt: OwnerRelayReceipt) throws {
    try validateRelayContext(receipt.context)
    try validateCapabilityOperation(.payment(receipt.payment))
    try requireCapabilityResponse(receipt.wallet == receipt.context.operation.account.wallet && receipt.payment.identity.selector == receipt.context.operation)
    switch receipt.outcome {
    case .admitted:
        guard let attempt = receipt.attempt else { throw CapabilityFailure.invalidResponse }
        try validateCapabilityAttempt(attempt)
        try requireCapabilityResponse(attempt.route == .owner && receipt.terminalReason == nil)
    case .noAdmission: try requireCapabilityResponse(receipt.attempt == nil && receipt.terminalReason != nil)
    }
}
private func bindPayment(_ payment: PaymentOperation, operation: OperationSelector) throws {
    try validateCapabilityOperation(.payment(payment)); try requireCapabilityResponse(payment.identity.selector == operation)
}
private func validateOwnerResult(_ result: OwnerControlResult, for call: OwnerControlCall) throws {
    switch (call, result) {
    case (.status, .status(let status)): try validateOwnerStatus(status)
    case (.listAccounts(let wallet), .listAccounts(let directory)):
        try requireCapabilityResponse(directory.wallet == wallet && directory.walletGeneration > 0 &&
            directory.accounts.count <= PageRequest.maximumCount && Set(directory.accounts).count == directory.accounts.count &&
            directory.accounts.allSatisfy { $0.wallet == wallet })
    case (.listPayments(let request), .listPayments(let value)):
        try requireCapabilityResponse(value.wallet == request.wallet && value.walletGeneration > 0 &&
            validCapabilityHex(value.snapshotID, byteCount: 32) &&
            value.page.items.count <= request.page.limit && value.page.items.count <= PageRequest.maximumCount &&
            (value.page.nextCursor.map(validCapabilityIdentifier) ?? true) &&
            Set(value.page.items.map { $0.identity.selector.operationID }).count == value.page.items.count)
        for payment in value.page.items {
            try validateCapabilityOperation(.payment(payment))
            try requireCapabilityResponse(payment.identity.selector.account.wallet == request.wallet)
        }
    case (.inspectRecovery, .inspectRecovery(let recovery)):
        try validateOwnerStatus(recovery.status)
        try requireCapabilityResponse(Set(recovery.availableSources).count == recovery.availableSources.count)
    case (.createWallet(let network), .createWallet(let status)):
        try validateOwnerStatus(status)
        try requireCapabilityResponse(status.wallet?.network == network && status.availability == .restricted && status.history == .complete)
    case (.restoreSeed(let request), .restoreSeed(let status)):
        try validateOwnerStatus(status)
        try requireCapabilityResponse(status.wallet?.network == request.network && status.availability == .restricted)
    case (.exportRecoveryMaterial(let wallet), .exportRecoveryMaterial(let exported)):
        try requireCapabilityResponse(exported.wallet == wallet)
    case (.recoverJournal(let request), .recoverJournal(let status)):
        try validateOwnerStatus(status)
        if let wallet = request.wallet { try requireCapabilityResponse(status.wallet == wallet) }
        try requireCapabilityResponse(status.availability == .restricted)
    case (.discoverPublicAccount(let account), .discoverPublicAccount(let value)):
        try requireCapabilityResponse(value.account == account)
        try validateCapabilityReadiness(value.readiness)
        if let observation = value.observation { try validateCapabilityObservation(observation) }
    case (.enableWallet(let wallet), .enableWallet(let status)):
        try bindStatus(status, wallet: wallet); try requireCapabilityResponse(status.availability == .enabled && status.history == .complete)
    case (.enrollIntegration(let request), .enrollIntegration(let issued)):
        try validateGrant(issued.grant)
        try requireCapabilityResponse(issued.grant.selector.wallet == request.wallet && issued.grant.integrationID == request.integrationID &&
            Set(issued.grant.accountIDs) == Set(request.accountIDs) && Set(issued.grant.scopes) == Set(request.scopes) &&
            issued.grant.expiresAt == request.expiresAt && issued.grant.peerProfile == request.peerProfile && issued.grant.state == .active && issued.credential.withBytes { $0.count == 32 })
    case (.rotateGrant(let selector), .rotateGrant(let issued)):
        try validateGrant(issued.grant)
        try requireCapabilityResponse(issued.grant.selector == selector && issued.grant.state == .active && issued.credential.withBytes { $0.count == 32 })
    case (.revokeGrant(let selector), .revokeGrant(let revoked)):
        try validateGrant(revoked.grant)
        try requireCapabilityResponse(revoked.grant.selector == selector && revoked.grant.state == .revoked && revoked.admittedOperations.allSatisfy { $0.account.wallet == selector.wallet })
    case (.setApprovalPolicy(let request), .setApprovalPolicy(let policy)):
        try requireCapabilityResponse(policy.wallet == request.wallet && policy.approvalRequired == request.approvalRequired &&
            (policy.revision == request.expectedRevision || (request.expectedRevision < UInt64.max && policy.revision == request.expectedRevision + 1)))
    case (.paymentStatus(let operation), .paymentStatus(let payment)): try bindPayment(payment, operation: operation)
    case (.reviewPreview(let operation), .reviewPreview(let context)):
        try validatePreviewContext(context); try requireCapabilityResponse(context.operation == operation)
    case (.approveExactPayment(let context), .approveExactPayment(let payment)), (.rejectExactPayment(let context), .rejectExactPayment(let payment)):
        try bindPayment(payment, operation: context.operation)
        try requireCapabilityResponse(payment.preview == context.preview)
    case (.reviewRelay(let operation), .reviewRelay(let context)):
        try validateRelayContext(context); try requireCapabilityResponse(context.operation == operation)
    case (.authorizeExactRelay(let request), .authorizeExactRelay(let receipt)):
        try validateReceipt(receipt)
        try requireCapabilityResponse(receipt.requestKey == request.requestKey && receipt.context == request.context)
    case (.relayReceipt(let selector), .relayReceipt(let receipt)):
        try validateReceipt(receipt); try requireCapabilityResponse(receipt.wallet == selector.wallet && receipt.requestKey == selector.requestKey)
    default: throw CapabilityFailure.invalidResponse
    }
}
