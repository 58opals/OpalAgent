// AgentAutomationRequests.swift

import AgentValues
import Foundation

public struct AgentAutomationRequestOwner: Codable, Sendable, Equatable {
    public let wallet: WalletScope
    public let integrationID: String
    public let grantID: String
    public let walletGeneration: UInt64

    public init(wallet: WalletScope, integrationID: String, grantID: String, walletGeneration: UInt64) throws {
        guard automationIdentifier(integrationID), automationIdentifier(grantID), walletGeneration > 0 else {
            throw AgentAutomationFailure.invalidReference
        }
        self.wallet = wallet; self.integrationID = integrationID; self.grantID = grantID; self.walletGeneration = walletGeneration
    }
    public init(binding: AgentAutomationBinding) {
        self.wallet = binding.wallet; self.integrationID = binding.integrationID
        self.grantID = binding.grantID; self.walletGeneration = binding.walletGeneration
    }
    public init(from decoder: any Decoder) throws {
        try automationRejectUnknown(decoder, ["wallet", "integrationID", "grantID", "walletGeneration"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(wallet: c.decode(WalletScope.self, forKey: .wallet), integrationID: c.decode(String.self, forKey: .integrationID),
                      grantID: c.decode(String.self, forKey: .grantID), walletGeneration: c.decode(UInt64.self, forKey: .walletGeneration))
    }
    private enum CodingKeys: String, CodingKey { case wallet, integrationID, grantID, walletGeneration }
}

/// Original typed caller fields. The service owns BCH address/network/script normalization.
public struct AgentAutomationPaymentDraft: Codable, Sendable, Equatable {
    public let account: AccountScope
    public let destinationAddress: String
    public let amountSatoshis: Int64
    public let feeRateSatoshisPerByte: Int64
    public let expiresAt: Int64?

    public init(account: AccountScope, destinationAddress: String, amountSatoshis: Int64,
                feeRateSatoshisPerByte: Int64 = 1, expiresAt: Int64? = nil) throws {
        guard !destinationAddress.isEmpty, destinationAddress.utf8.count <= 512,
              destinationAddress == destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...2_100_000_000_000_000).contains(amountSatoshis), feeRateSatoshisPerByte > 0,
              expiresAt.map({ $0 > 0 }) ?? true else { throw AgentAutomationFailure.invalidReference }
        self.account = account; self.destinationAddress = destinationAddress; self.amountSatoshis = amountSatoshis
        self.feeRateSatoshisPerByte = feeRateSatoshisPerByte; self.expiresAt = expiresAt
    }
    public init(from decoder: any Decoder) throws {
        try automationRejectUnknown(decoder, ["account", "destinationAddress", "amountSatoshis", "feeRateSatoshisPerByte", "expiresAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(AccountScope.self, forKey: .account), destinationAddress: c.decode(String.self, forKey: .destinationAddress),
                      amountSatoshis: c.decode(Int64.self, forKey: .amountSatoshis),
                      feeRateSatoshisPerByte: c.decode(Int64.self, forKey: .feeRateSatoshisPerByte),
                      expiresAt: c.decodeIfPresent(Int64.self, forKey: .expiresAt))
    }
    private enum CodingKeys: String, CodingKey { case account, destinationAddress, amountSatoshis, feeRateSatoshisPerByte, expiresAt }
}

public enum AgentAutomationRequestPayload: Codable, Sendable, Equatable {
    case synchronizeAccount(AccountScope)
    case createReceiveRequest(AccountScope)
    case preparePayment(AgentAutomationPaymentDraft)

    public var account: AccountScope {
        switch self { case .synchronizeAccount(let v), .createReceiveRequest(let v): v; case .preparePayment(let v): v.account }
    }
    public var effect: EffectKind {
        switch self { case .synchronizeAccount: .synchronizeAccount; case .createReceiveRequest: .createReceiveRequest; case .preparePayment: .preparePayment }
    }
    public init(from decoder: any Decoder) throws {
        try automationRejectUnknown(decoder, ["effect", "account", "payment"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(EffectKind.self, forKey: .effect) {
        case .synchronizeAccount:
            guard !c.contains(.payment) else { throw AgentAutomationFailure.invalidReference }
            self = .synchronizeAccount(try c.decode(AccountScope.self, forKey: .account))
        case .createReceiveRequest:
            guard !c.contains(.payment) else { throw AgentAutomationFailure.invalidReference }
            self = .createReceiveRequest(try c.decode(AccountScope.self, forKey: .account))
        case .preparePayment:
            guard !c.contains(.account) else { throw AgentAutomationFailure.invalidReference }
            self = .preparePayment(try c.decode(AgentAutomationPaymentDraft.self, forKey: .payment))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(effect, forKey: .effect)
        switch self {
        case .synchronizeAccount(let account), .createReceiveRequest(let account): try c.encode(account, forKey: .account)
        case .preparePayment(let payment): try c.encode(payment, forKey: .payment)
        }
    }
    private enum CodingKeys: String, CodingKey { case effect, account, payment }
}

/// Local identity only; service state and authority are never cached in this record.
public struct RetainedAgentAutomationRequest: Codable, Sendable, Equatable {
    public let handleID: String
    public let owner: AgentAutomationRequestOwner
    public let payload: AgentAutomationRequestPayload
    public let requestKey: RequestKey
    public let operation: OperationIdentity?

    public init(handleID: String, owner: AgentAutomationRequestOwner, payload: AgentAutomationRequestPayload,
                requestKey: RequestKey, operation: OperationIdentity? = nil) throws {
        guard automationHandleID(handleID), payload.account.wallet == owner.wallet,
              operation.map({ $0.selector.account == payload.account && $0.requestKey == requestKey }) ?? true else {
            throw AgentAutomationFailure.invalidReference
        }
        self.handleID = handleID; self.owner = owner; self.payload = payload; self.requestKey = requestKey; self.operation = operation
    }
    public init(from decoder: any Decoder) throws {
        try automationRejectUnknown(decoder, ["handleID", "owner", "payload", "requestKey", "operation"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(handleID: c.decode(String.self, forKey: .handleID), owner: c.decode(AgentAutomationRequestOwner.self, forKey: .owner),
                      payload: c.decode(AgentAutomationRequestPayload.self, forKey: .payload), requestKey: c.decode(RequestKey.self, forKey: .requestKey),
                      operation: c.decodeIfPresent(OperationIdentity.self, forKey: .operation))
    }
    private enum CodingKeys: String, CodingKey { case handleID, owner, payload, requestKey, operation }
}

/// Host-owned durable identity storage. Create completes persistence before returning; enrichment is an atomic once-fill.
public protocol AgentAutomationRequestStore: Sendable {
    func create(binding: AgentAutomationBinding, payload: AgentAutomationRequestPayload) async throws -> RetainedAgentAutomationRequest
    func load(handleID: String, binding: AgentAutomationBinding) async throws -> RetainedAgentAutomationRequest
    func recordOperation(handleID: String, binding: AgentAutomationBinding, identity: OperationIdentity) async throws -> RetainedAgentAutomationRequest
    func recent(binding: AgentAutomationBinding, limit: Int) async throws -> [RetainedAgentAutomationRequest]
}
public struct UnavailableAgentAutomationRequestStore: AgentAutomationRequestStore {
    public init() {}
    public func create(binding: AgentAutomationBinding, payload: AgentAutomationRequestPayload) async throws -> RetainedAgentAutomationRequest { throw AgentAutomationFailure.requestUnavailable }
    public func load(handleID: String, binding: AgentAutomationBinding) async throws -> RetainedAgentAutomationRequest { throw AgentAutomationFailure.requestUnavailable }
    public func recordOperation(handleID: String, binding: AgentAutomationBinding, identity: OperationIdentity) async throws -> RetainedAgentAutomationRequest { throw AgentAutomationFailure.localRetentionUnavailable }
    public func recent(binding: AgentAutomationBinding, limit: Int) async throws -> [RetainedAgentAutomationRequest] { throw AgentAutomationFailure.requestUnavailable }
}

public struct AgentAutomationReviewRequest: Sendable, Equatable {
    public let owner: AgentAutomationRequestOwner
    public let operation: OperationSelector
    public init(owner: AgentAutomationRequestOwner, operation: OperationSelector) throws {
        guard operation.account.wallet == owner.wallet else { throw AgentAutomationFailure.invalidReference }
        self.owner = owner; self.operation = operation
    }
}
public struct AgentAutomationReviewAcknowledgment: Sendable, Equatable {
    public let request: AgentAutomationReviewRequest
    public let routeAccepted: Bool
    public init(request: AgentAutomationReviewRequest, routeAccepted: Bool) { self.request = request; self.routeAccepted = routeAccepted }
}
public protocol AgentAutomationReviewNavigator: Sendable {
    func openReview(_ request: AgentAutomationReviewRequest) async throws -> AgentAutomationReviewAcknowledgment
}
public struct UnavailableAgentAutomationReviewNavigator: AgentAutomationReviewNavigator {
    public init() {}
    public func openReview(_ request: AgentAutomationReviewRequest) async throws -> AgentAutomationReviewAcknowledgment { throw AgentAutomationFailure.unavailable }
}

func automationHandleID(_ value: String) -> Bool {
    value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func automationRejectUnknown(_ decoder: any Decoder, _ allowed: Set<String>) throws {
    let fields = try decoder.container(keyedBy: AutomationRequestFieldKey.self)
    guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw AgentAutomationFailure.invalidReference }
}
private struct AutomationRequestFieldKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    let intValue: Int? = nil
    init?(intValue: Int) { return nil }
}
