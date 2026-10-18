import Foundation

/// Owner-only material. It is deliberately not Codable and its ordinary/debug/reflection descriptions are redacted.
/// Native owner transports must handle the bytes explicitly; never attach them to integration values or diagnostics.
public struct SensitiveOwnerMaterial: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let bytes: Data
    public init(bytes: Data) throws {
        guard !bytes.isEmpty else { throw CapabilityFailure.invalidRequest }
        self.bytes = bytes
    }
    public func withBytes<Result>(_ body: (Data) throws -> Result) rethrows -> Result { try body(bytes) }
    public var description: String { "<redacted owner material>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["material": "<redacted>"]) }
}

public struct SeedRestoreRequest: Sendable {
    public let network: WalletNetwork
    public let mnemonic: SensitiveOwnerMaterial
    public init(network: WalletNetwork, mnemonic: SensitiveOwnerMaterial) { self.network = network; self.mnemonic = mnemonic }
}
public struct RecoverySourceHandle: Codable, Sendable, Equatable, Hashable {
    public let value: String
    public init(_ value: String) throws {
        guard ownerIdentifier(value) else { throw CapabilityFailure.invalidRequest }
        self.value = value
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
}
public struct JournalRecoveryRequest: Sendable, Equatable {
    public let wallet: WalletScope?
    public let source: RecoverySourceHandle?
    public init(wallet: WalletScope?, source: RecoverySourceHandle?) { self.wallet = wallet; self.source = source }
}
public struct GrantSelector: Codable, Sendable, Equatable {
    public let wallet: WalletScope
    public let grantID: String
    public init(wallet: WalletScope, grantID: String) throws {
        guard ownerIdentifier(grantID) else { throw CapabilityFailure.invalidRequest }
        self.wallet = wallet; self.grantID = grantID
    }
}
public struct EnrollmentRequest: Sendable, Equatable {
    public let wallet: WalletScope
    public let integrationID: String
    public let accountIDs: [String]
    public let scopes: [IntegrationScope]
    public let expiresAt: Int64?
    public init(wallet: WalletScope, integrationID: String, accountIDs: [String], scopes: [IntegrationScope], expiresAt: Int64? = nil) throws {
        guard ownerIdentifier(integrationID), !accountIDs.isEmpty, accountIDs.allSatisfy(ownerIdentifier),
              Set(accountIDs).count == accountIDs.count, !scopes.isEmpty, Set(scopes).count == scopes.count,
              expiresAt.map({ $0 > 0 }) ?? true else { throw CapabilityFailure.invalidRequest }
        self.wallet = wallet; self.integrationID = integrationID; self.accountIDs = accountIDs; self.scopes = scopes; self.expiresAt = expiresAt
    }
}
public struct ApprovalPolicyRequest: Sendable, Equatable {
    public let wallet: WalletScope
    public let expectedRevision: UInt64
    public let approvalRequired: Bool
    public init(wallet: WalletScope, expectedRevision: UInt64, approvalRequired: Bool) {
        self.wallet = wallet; self.expectedRevision = expectedRevision; self.approvalRequired = approvalRequired
    }
}
/// Expected service-produced preview facts. These do not confer owner authority or contain signed transaction bytes.
public struct ExactPreviewReviewContext: Codable, Sendable, Equatable {
    public let operation: OperationSelector
    public let preview: PaymentPreviewProjection
    public let previewContextDigest: String
    public let walletGeneration: UInt64
    public let policyRevision: UInt64
    public let originGrantID: String
    public let originCredentialGeneration: UInt64
    public init(operation: OperationSelector, preview: PaymentPreviewProjection, previewContextDigest: String,
                walletGeneration: UInt64, policyRevision: UInt64, originGrantID: String, originCredentialGeneration: UInt64) {
        self.operation = operation; self.preview = preview; self.previewContextDigest = previewContextDigest
        self.walletGeneration = walletGeneration; self.policyRevision = policyRevision
        self.originGrantID = originGrantID; self.originCredentialGeneration = originCredentialGeneration
    }
}
/// Expected context for exactly one relay of already retained signed bytes, separate from ordinary preview approval.
public struct ExactRelayReviewContext: Codable, Sendable, Equatable {
    public let operation: OperationSelector
    public let transactionDigest: String
    public let walletGeneration: UInt64
    public let policyRevision: UInt64
    public let evidenceRevision: UInt64
    public let accountLiabilityContextDigest: String
    public init(operation: OperationSelector, transactionDigest: String, walletGeneration: UInt64,
                policyRevision: UInt64, evidenceRevision: UInt64, accountLiabilityContextDigest: String) {
        self.operation = operation; self.transactionDigest = transactionDigest; self.walletGeneration = walletGeneration
        self.policyRevision = policyRevision; self.evidenceRevision = evidenceRevision; self.accountLiabilityContextDigest = accountLiabilityContextDigest
    }
}
public struct OwnerRelayRequest: Sendable, Equatable {
    public let requestKey: RequestKey
    public let context: ExactRelayReviewContext
    public init(requestKey: RequestKey, context: ExactRelayReviewContext) { self.requestKey = requestKey; self.context = context }
}
public struct OwnerReceiptSelector: Sendable, Equatable {
    public let wallet: WalletScope
    public let requestKey: RequestKey
    public init(wallet: WalletScope, requestKey: RequestKey) { self.wallet = wallet; self.requestKey = requestKey }
}
public enum HistoryCoverageProjection: String, Codable, Sendable { case unknown, incomplete, complete }
/// Metadata-only status uses presentUnverified. Availability is never inferred by opening custody during a status read.
public enum CustodyAvailability: String, Codable, Sendable { case absent, presentUnverified, available, unavailable }
public struct ApprovalPolicyProjection: Codable, Sendable, Equatable {
    public let wallet: WalletScope
    public let revision: UInt64
    public let approvalRequired: Bool
    public init(wallet: WalletScope, revision: UInt64, approvalRequired: Bool) {
        self.wallet = wallet; self.revision = revision; self.approvalRequired = approvalRequired
    }
}
public struct OwnerWalletStatus: Codable, Sendable, Equatable {
    public let wallet: WalletScope?
    public let availability: ServiceAvailability
    public let history: HistoryCoverageProjection
    public let walletGeneration: UInt64?
    public let custody: CustodyAvailability
    public let approvalPolicy: ApprovalPolicyProjection?
    public let unresolvedOperations: [OperationSelector]
    public let grants: [GrantProjection]
    public init(wallet: WalletScope?, availability: ServiceAvailability, history: HistoryCoverageProjection,
                walletGeneration: UInt64?, custody: CustodyAvailability, approvalPolicy: ApprovalPolicyProjection?, unresolvedOperations: [OperationSelector], grants: [GrantProjection] = []) {
        self.wallet = wallet; self.availability = availability; self.history = history; self.walletGeneration = walletGeneration
        self.custody = custody; self.approvalPolicy = approvalPolicy; self.unresolvedOperations = unresolvedOperations; self.grants = grants
    }
}
/// A bounded owner-only account directory. Reading it never opens custody or confers integration authority.
public struct OwnerAccountDirectory: Codable, Sendable, Equatable {
    public let wallet: WalletScope
    public let walletGeneration: UInt64
    public let accounts: [AccountScope]
    public init(wallet: WalletScope, walletGeneration: UInt64, accounts: [AccountScope]) {
        self.wallet = wallet; self.walletGeneration = walletGeneration; self.accounts = accounts
    }
}
/// A current owner-only payment page, bound to one wallet generation and exact state commitment.
/// The cursor is an opaque service value, never a caller-provided authorization context.
public struct OwnerPaymentPage: Codable, Sendable, Equatable {
    public let wallet: WalletScope
    public let walletGeneration: UInt64
    public let snapshotID: String
    public let page: CapabilityPage<PaymentOperation>
    public init(wallet: WalletScope, walletGeneration: UInt64, snapshotID: String, page: CapabilityPage<PaymentOperation>) {
        self.wallet = wallet; self.walletGeneration = walletGeneration; self.snapshotID = snapshotID; self.page = page
    }
}
public struct OwnerRecoveryStatus: Sendable, Equatable {
    public let status: OwnerWalletStatus
    public let availableSources: [RecoverySourceHandle]
    public init(status: OwnerWalletStatus, availableSources: [RecoverySourceHandle]) { self.status = status; self.availableSources = availableSources }
}
public struct OwnerRecoveryMaterial: Sendable {
    public let wallet: WalletScope
    public let material: SensitiveOwnerMaterial
    public init(wallet: WalletScope, material: SensitiveOwnerMaterial) { self.wallet = wallet; self.material = material }
}
public enum GrantState: String, Codable, Sendable { case active, revoked, expired }
public struct GrantProjection: Codable, Sendable, Equatable {
    public let selector: GrantSelector
    public let integrationID: String
    public let accountIDs: [String]
    public let scopes: [IntegrationScope]
    public let expiresAt: Int64?
    public let credentialGeneration: UInt64
    public let state: GrantState
    public init(selector: GrantSelector, integrationID: String, accountIDs: [String], scopes: [IntegrationScope],
                expiresAt: Int64?, credentialGeneration: UInt64, state: GrantState) {
        self.selector = selector; self.integrationID = integrationID; self.accountIDs = accountIDs; self.scopes = scopes
        self.expiresAt = expiresAt; self.credentialGeneration = credentialGeneration; self.state = state
    }
}
public struct OwnerIssuedCredential: Sendable {
    public let grant: GrantProjection
    public let credential: SensitiveOwnerMaterial
    public init(grant: GrantProjection, credential: SensitiveOwnerMaterial) { self.grant = grant; self.credential = credential }
}
public struct GrantRevocationProjection: Sendable, Equatable {
    public let grant: GrantProjection
    public let admittedOperations: [OperationSelector]
    public init(grant: GrantProjection, admittedOperations: [OperationSelector]) { self.grant = grant; self.admittedOperations = admittedOperations }
}
public enum OwnerRelayOutcome: String, Codable, Sendable { case admitted, noAdmission }
public struct OwnerRelayReceipt: Sendable, Equatable {
    public let wallet: WalletScope
    public let requestKey: RequestKey
    public let context: ExactRelayReviewContext
    public let attempt: RelayAttemptProjection?
    public let outcome: OwnerRelayOutcome
    public let terminalReason: ServiceProblemCode?
    public let payment: PaymentOperation
    public init(wallet: WalletScope, requestKey: RequestKey, context: ExactRelayReviewContext, attempt: RelayAttemptProjection?,
                outcome: OwnerRelayOutcome, terminalReason: ServiceProblemCode?, payment: PaymentOperation) {
        self.wallet = wallet; self.requestKey = requestKey; self.context = context; self.attempt = attempt
        self.outcome = outcome; self.terminalReason = terminalReason; self.payment = payment
    }
}
public enum OwnerControlMethod: String, Sendable, CaseIterable {
    case status, listAccounts, listPayments, inspectRecovery, createWallet, restoreSeed, exportRecoveryMaterial, recoverJournal, discoverPublicAccount, enableWallet
    case enrollIntegration, rotateGrant, revokeGrant, setApprovalPolicy, paymentStatus, reviewPreview, approveExactPayment, rejectExactPayment
    case reviewRelay, authorizeExactRelay, relayReceipt
}
/// Only the separately authenticated owner endpoint accepts these calls. There is no caller-asserted role/authentication flag.
public enum OwnerControlCall: Sendable {
    case status
    case listAccounts(WalletScope)
    case listPayments(WalletPageRequest)
    case inspectRecovery
    case createWallet(network: WalletNetwork)
    case restoreSeed(SeedRestoreRequest)
    case exportRecoveryMaterial(WalletScope)
    case recoverJournal(JournalRecoveryRequest)
    case discoverPublicAccount(AccountScope)
    case enableWallet(WalletScope)
    case enrollIntegration(EnrollmentRequest)
    case rotateGrant(GrantSelector)
    case revokeGrant(GrantSelector)
    case setApprovalPolicy(ApprovalPolicyRequest)
    case paymentStatus(OperationSelector)
    case reviewPreview(OperationSelector)
    case approveExactPayment(ExactPreviewReviewContext)
    case rejectExactPayment(ExactPreviewReviewContext)
    case reviewRelay(OperationSelector)
    case authorizeExactRelay(OwnerRelayRequest)
    case relayReceipt(OwnerReceiptSelector)
    public var method: OwnerControlMethod {
        switch self {
        case .status: .status; case .listAccounts: .listAccounts; case .listPayments: .listPayments
        case .inspectRecovery: .inspectRecovery; case .createWallet: .createWallet
        case .restoreSeed: .restoreSeed; case .exportRecoveryMaterial: .exportRecoveryMaterial; case .recoverJournal: .recoverJournal
        case .discoverPublicAccount: .discoverPublicAccount; case .enableWallet: .enableWallet; case .enrollIntegration: .enrollIntegration
        case .rotateGrant: .rotateGrant; case .revokeGrant: .revokeGrant; case .setApprovalPolicy: .setApprovalPolicy
        case .paymentStatus: .paymentStatus; case .reviewPreview: .reviewPreview; case .approveExactPayment: .approveExactPayment
        case .rejectExactPayment: .rejectExactPayment; case .reviewRelay: .reviewRelay; case .authorizeExactRelay: .authorizeExactRelay; case .relayReceipt: .relayReceipt
        }
    }
}
public struct OwnerControlRequest: Sendable {
    public let protocolVersion: Int
    public let call: OwnerControlCall
    public init(call: OwnerControlCall) { self.protocolVersion = ServiceStatus.currentProtocolVersion; self.call = call }
}
public enum OwnerControlResult: Sendable {
    case status(OwnerWalletStatus)
    case listAccounts(OwnerAccountDirectory)
    case listPayments(OwnerPaymentPage)
    case inspectRecovery(OwnerRecoveryStatus)
    case createWallet(OwnerWalletStatus)
    case restoreSeed(OwnerWalletStatus)
    case exportRecoveryMaterial(OwnerRecoveryMaterial)
    case recoverJournal(OwnerWalletStatus)
    case discoverPublicAccount(SyncStatusProjection)
    case enableWallet(OwnerWalletStatus)
    case enrollIntegration(OwnerIssuedCredential)
    case rotateGrant(OwnerIssuedCredential)
    case revokeGrant(GrantRevocationProjection)
    case setApprovalPolicy(ApprovalPolicyProjection)
    case paymentStatus(PaymentOperation)
    case reviewPreview(ExactPreviewReviewContext)
    case approveExactPayment(PaymentOperation)
    case rejectExactPayment(PaymentOperation)
    case reviewRelay(ExactRelayReviewContext)
    case authorizeExactRelay(OwnerRelayReceipt)
    case relayReceipt(OwnerRelayReceipt)
    public var method: OwnerControlMethod {
        switch self {
        case .status: .status; case .listAccounts: .listAccounts; case .listPayments: .listPayments
        case .inspectRecovery: .inspectRecovery; case .createWallet: .createWallet
        case .restoreSeed: .restoreSeed; case .exportRecoveryMaterial: .exportRecoveryMaterial; case .recoverJournal: .recoverJournal
        case .discoverPublicAccount: .discoverPublicAccount; case .enableWallet: .enableWallet; case .enrollIntegration: .enrollIntegration
        case .rotateGrant: .rotateGrant; case .revokeGrant: .revokeGrant; case .setApprovalPolicy: .setApprovalPolicy
        case .paymentStatus: .paymentStatus; case .reviewPreview: .reviewPreview; case .approveExactPayment: .approveExactPayment
        case .rejectExactPayment: .rejectExactPayment; case .reviewRelay: .reviewRelay; case .authorizeExactRelay: .authorizeExactRelay; case .relayReceipt: .relayReceipt
        }
    }
}
public struct OwnerControlResponse: Sendable {
    public let protocolVersion: Int
    public let result: OwnerControlResult
    public init(protocolVersion: Int = ServiceStatus.currentProtocolVersion, result: OwnerControlResult) {
        self.protocolVersion = protocolVersion; self.result = result
    }
}
private func ownerIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 2048 && !value.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
    })
}
