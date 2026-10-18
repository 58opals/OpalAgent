import AgentValues
import Foundation

private struct OwnerBody: Codable { let method: String; let payload: Data }
private struct EmptyBody: Codable {}
private struct RecoveryInput: Codable { let wallet: WalletScope?; let source: RecoverySourceHandle? }
private struct EnrollmentInput: Codable { let wallet: WalletScope; let integrationID: String; let accountIDs: [String]; let scopes: [IntegrationScope]; let expiresAt: Int64? }
private struct PolicyInput: Codable { let wallet: WalletScope; let expectedRevision: UInt64; let approvalRequired: Bool }
private struct RelayInput: Codable { let requestKey: RequestKey; let context: ExactRelayReviewContext }
private struct ReceiptInput: Codable { let wallet: WalletScope; let requestKey: RequestKey }
private struct RecoveryOutput: Codable { let status: OwnerWalletStatus; let availableSources: [RecoverySourceHandle] }
private struct RevocationOutput: Codable { let grant: GrantProjection; let admittedOperations: [OperationSelector] }
private struct RelayOutput: Codable {
    let wallet: WalletScope; let requestKey: RequestKey; let context: ExactRelayReviewContext
    let attempt: RelayAttemptProjection?; let outcome: OwnerRelayOutcome; let terminalReason: ServiceProblemCode?; let payment: PaymentOperation
}

public extension NativeWire {
    static func ownerRequest(_ request: OwnerControlRequest, requestID: UUID) throws -> NativeOwnerPacket {
        guard request.protocolVersion == ServiceStatus.currentProtocolVersion else { throw NativeIPCFailure.incompatibleProtocol }
        var sensitive: Data?
        let payload: Data
        switch request.call {
        case .status, .inspectRecovery: payload = try encode(EmptyBody())
        case .listAccounts(let wallet): payload = try encode(wallet)
        case .listPayments(let request): payload = try encode(request)
        case .createWallet(let network): payload = try encode(network)
        case .restoreSeed(let input): payload = try encode(input.network); sensitive = input.mnemonic.withBytes { $0 }
        case .exportRecoveryMaterial(let wallet), .enableWallet(let wallet): payload = try encode(wallet)
        case .recoverJournal(let input): payload = try encode(RecoveryInput(wallet: input.wallet, source: input.source))
        case .discoverPublicAccount(let account): payload = try encode(account)
        case .enrollIntegration(let input): payload = try encode(EnrollmentInput(wallet: input.wallet, integrationID: input.integrationID, accountIDs: input.accountIDs, scopes: input.scopes, expiresAt: input.expiresAt))
        case .rotateGrant(let selector), .revokeGrant(let selector): payload = try encode(selector)
        case .setApprovalPolicy(let input): payload = try encode(PolicyInput(wallet: input.wallet, expectedRevision: input.expectedRevision, approvalRequired: input.approvalRequired))
        case .paymentStatus(let selector), .reviewPreview(let selector), .reviewRelay(let selector): payload = try encode(selector)
        case .approveExactPayment(let context), .rejectExactPayment(let context): payload = try encode(context)
        case .authorizeExactRelay(let input): payload = try encode(RelayInput(requestKey: input.requestKey, context: input.context))
        case .relayReceipt(let input): payload = try encode(ReceiptInput(wallet: input.wallet, requestKey: input.requestKey))
        }
        try validateSensitive(sensitive, required: request.call.method == .restoreSeed)
        return NativeOwnerPacket(frame: try frame(OwnerBody(method: request.call.method.rawValue, payload: payload), kind: .ownerRequest, requestID: requestID), sensitive: sensitive)
    }
    static func decodeOwnerRequest(_ packet: NativeOwnerPacket) throws -> (UUID, OwnerControlRequest) {
        let outer = try unpack(packet.frame, kind: .ownerRequest)
        let body = try decode(OwnerBody.self, from: outer.payload)
        guard let method = OwnerControlMethod(rawValue: body.method) else { throw NativeIPCFailure.malformedFrame }
        try validateSensitive(packet.sensitive, required: method == .restoreSeed)
        let call: OwnerControlCall
        switch method {
        case .status: _ = try decode(EmptyBody.self, from: body.payload); call = .status
        case .listAccounts: call = .listAccounts(try decode(WalletScope.self, from: body.payload))
        case .listPayments: call = .listPayments(try decode(WalletPageRequest.self, from: body.payload))
        case .inspectRecovery: _ = try decode(EmptyBody.self, from: body.payload); call = .inspectRecovery
        case .createWallet: call = .createWallet(network: try decode(WalletNetwork.self, from: body.payload))
        case .restoreSeed:
            guard let bytes = packet.sensitive else { throw NativeIPCFailure.malformedFrame }
            call = .restoreSeed(SeedRestoreRequest(network: try decode(WalletNetwork.self, from: body.payload), mnemonic: try SensitiveOwnerMaterial(bytes: bytes)))
        case .exportRecoveryMaterial: call = .exportRecoveryMaterial(try decode(WalletScope.self, from: body.payload))
        case .enableWallet: call = .enableWallet(try decode(WalletScope.self, from: body.payload))
        case .recoverJournal:
            let input = try decode(RecoveryInput.self, from: body.payload); call = .recoverJournal(JournalRecoveryRequest(wallet: input.wallet, source: input.source))
        case .discoverPublicAccount: call = .discoverPublicAccount(try decode(AccountScope.self, from: body.payload))
        case .enrollIntegration:
            let input = try decode(EnrollmentInput.self, from: body.payload)
            call = .enrollIntegration(try EnrollmentRequest(wallet: input.wallet, integrationID: input.integrationID, accountIDs: input.accountIDs, scopes: input.scopes, expiresAt: input.expiresAt))
        case .rotateGrant: call = .rotateGrant(try decode(GrantSelector.self, from: body.payload))
        case .revokeGrant: call = .revokeGrant(try decode(GrantSelector.self, from: body.payload))
        case .setApprovalPolicy:
            let input = try decode(PolicyInput.self, from: body.payload); call = .setApprovalPolicy(ApprovalPolicyRequest(wallet: input.wallet, expectedRevision: input.expectedRevision, approvalRequired: input.approvalRequired))
        case .paymentStatus: call = .paymentStatus(try decode(OperationSelector.self, from: body.payload))
        case .reviewPreview: call = .reviewPreview(try decode(OperationSelector.self, from: body.payload))
        case .reviewRelay: call = .reviewRelay(try decode(OperationSelector.self, from: body.payload))
        case .approveExactPayment: call = .approveExactPayment(try decode(ExactPreviewReviewContext.self, from: body.payload))
        case .rejectExactPayment: call = .rejectExactPayment(try decode(ExactPreviewReviewContext.self, from: body.payload))
        case .authorizeExactRelay:
            let input = try decode(RelayInput.self, from: body.payload); call = .authorizeExactRelay(OwnerRelayRequest(requestKey: input.requestKey, context: input.context))
        case .relayReceipt:
            let input = try decode(ReceiptInput.self, from: body.payload); call = .relayReceipt(OwnerReceiptSelector(wallet: input.wallet, requestKey: input.requestKey))
        }
        return (outer.requestID, OwnerControlRequest(call: call))
    }
    static func ownerResponse(_ response: OwnerControlResponse, requestID: UUID) throws -> NativeOwnerPacket {
        guard response.protocolVersion == ServiceStatus.currentProtocolVersion else { throw NativeIPCFailure.incompatibleProtocol }
        let payload: Data
        var sensitive: Data?
        var credential = false
        switch response.result {
        case .status(let value), .createWallet(let value), .restoreSeed(let value), .recoverJournal(let value), .enableWallet(let value): payload = try encode(value)
        case .listAccounts(let value): payload = try encode(value)
        case .listPayments(let value): payload = try encode(value)
        case .inspectRecovery(let value): payload = try encode(RecoveryOutput(status: value.status, availableSources: value.availableSources))
        case .exportRecoveryMaterial(let value): payload = try encode(value.wallet); sensitive = value.material.withBytes { $0 }
        case .discoverPublicAccount(let value): payload = try encode(value)
        case .enrollIntegration(let value), .rotateGrant(let value): payload = try encode(value.grant); sensitive = value.credential.withBytes { $0 }; credential = true
        case .revokeGrant(let value): payload = try encode(RevocationOutput(grant: value.grant, admittedOperations: value.admittedOperations))
        case .setApprovalPolicy(let value): payload = try encode(value)
        case .paymentStatus(let value), .approveExactPayment(let value), .rejectExactPayment(let value): payload = try encode(value)
        case .reviewPreview(let value): payload = try encode(value)
        case .reviewRelay(let value): payload = try encode(value)
        case .authorizeExactRelay(let value), .relayReceipt(let value):
            payload = try encode(RelayOutput(wallet: value.wallet, requestKey: value.requestKey, context: value.context,
                attempt: value.attempt, outcome: value.outcome, terminalReason: value.terminalReason, payment: value.payment))
        }
        let requiresSensitive = [.exportRecoveryMaterial, .enrollIntegration, .rotateGrant].contains(response.result.method)
        try validateSensitive(sensitive, required: requiresSensitive, credential: credential)
        return NativeOwnerPacket(frame: try frame(OwnerBody(method: response.result.method.rawValue, payload: payload), kind: .ownerResponse, requestID: requestID), sensitive: sensitive)
    }
    static func decodeOwnerResponse(_ packet: NativeOwnerPacket, requestID: UUID, method: OwnerControlMethod) throws -> OwnerControlResponse {
        let outer = try unpack(packet.frame, kind: .ownerResponse, requestID: requestID)
        let body = try decode(OwnerBody.self, from: outer.payload)
        guard body.method == method.rawValue else { throw NativeIPCFailure.malformedFrame }
        let requiresSensitive = [.exportRecoveryMaterial, .enrollIntegration, .rotateGrant].contains(method)
        try validateSensitive(packet.sensitive, required: requiresSensitive, credential: method == .enrollIntegration || method == .rotateGrant)
        let result: OwnerControlResult
        switch method {
        case .status: result = .status(try decode(OwnerWalletStatus.self, from: body.payload))
        case .listAccounts: result = .listAccounts(try decode(OwnerAccountDirectory.self, from: body.payload))
        case .listPayments: result = .listPayments(try decode(OwnerPaymentPage.self, from: body.payload))
        case .createWallet: result = .createWallet(try decode(OwnerWalletStatus.self, from: body.payload))
        case .restoreSeed: result = .restoreSeed(try decode(OwnerWalletStatus.self, from: body.payload))
        case .recoverJournal: result = .recoverJournal(try decode(OwnerWalletStatus.self, from: body.payload))
        case .enableWallet: result = .enableWallet(try decode(OwnerWalletStatus.self, from: body.payload))
        case .inspectRecovery:
            let value = try decode(RecoveryOutput.self, from: body.payload); result = .inspectRecovery(OwnerRecoveryStatus(status: value.status, availableSources: value.availableSources))
        case .exportRecoveryMaterial:
            guard let bytes = packet.sensitive else { throw NativeIPCFailure.malformedFrame }
            result = .exportRecoveryMaterial(OwnerRecoveryMaterial(wallet: try decode(WalletScope.self, from: body.payload), material: try SensitiveOwnerMaterial(bytes: bytes)))
        case .discoverPublicAccount: result = .discoverPublicAccount(try decode(SyncStatusProjection.self, from: body.payload))
        case .enrollIntegration, .rotateGrant:
            guard let bytes = packet.sensitive else { throw NativeIPCFailure.malformedFrame }
            let value = OwnerIssuedCredential(grant: try decode(GrantProjection.self, from: body.payload), credential: try SensitiveOwnerMaterial(bytes: bytes))
            result = method == .enrollIntegration ? .enrollIntegration(value) : .rotateGrant(value)
        case .revokeGrant:
            let value = try decode(RevocationOutput.self, from: body.payload); result = .revokeGrant(GrantRevocationProjection(grant: value.grant, admittedOperations: value.admittedOperations))
        case .setApprovalPolicy: result = .setApprovalPolicy(try decode(ApprovalPolicyProjection.self, from: body.payload))
        case .paymentStatus: result = .paymentStatus(try decode(PaymentOperation.self, from: body.payload))
        case .approveExactPayment: result = .approveExactPayment(try decode(PaymentOperation.self, from: body.payload))
        case .rejectExactPayment: result = .rejectExactPayment(try decode(PaymentOperation.self, from: body.payload))
        case .reviewPreview: result = .reviewPreview(try decode(ExactPreviewReviewContext.self, from: body.payload))
        case .reviewRelay: result = .reviewRelay(try decode(ExactRelayReviewContext.self, from: body.payload))
        case .authorizeExactRelay, .relayReceipt:
            let value = try decode(RelayOutput.self, from: body.payload)
            let receipt = OwnerRelayReceipt(wallet: value.wallet, requestKey: value.requestKey, context: value.context,
                attempt: value.attempt, outcome: value.outcome, terminalReason: value.terminalReason, payment: value.payment)
            result = method == .authorizeExactRelay ? .authorizeExactRelay(receipt) : .relayReceipt(receipt)
        }
        return OwnerControlResponse(result: result)
    }
    private static func validateSensitive(_ bytes: Data?, required: Bool, credential: Bool = false) throws {
        if required {
            guard let bytes, !bytes.isEmpty, bytes.count <= maximumSensitiveBytes,
                  !credential || bytes.count == 32 else { throw NativeIPCFailure.malformedFrame }
        } else if bytes != nil { throw NativeIPCFailure.malformedFrame }
    }
}
