// AgentAutomationIntents.swift

import AgentValues
import AppIntents
import Foundation

public struct ListAgentWalletsIntent: AppIntent {
    public static let isDiscoverable = false
    public static let title: LocalizedStringResource = "List Agent Wallets"
    public static let description = IntentDescription("List one authorized page of Agent wallets. This does not open personal Wallet state.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Maximum Results", default: 40) public var limit: Int
    @Parameter(title: "Cursor") public var cursor: String?
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("List up to \(\.$limit) Agent wallets after \(\.$cursor)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentWalletPageSnapshot> {
        let page = try PageRequest(limit: limit, cursor: cursor)
        let value = try await AgentAutomationAdapter(dependency: dependency).wallets(page: page)
        return .result(value: try AgentWalletPageSnapshot(value))
    }
}

public struct ListAgentAccountsIntent: AppIntent {
    public static let isDiscoverable = false
    public static let title: LocalizedStringResource = "List Agent Accounts"
    public static let description = IntentDescription("List one authorized page of neutral Agent account references without reading funds.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Maximum Results", default: 40) public var limit: Int
    @Parameter(title: "Cursor") public var cursor: String?
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("List up to \(\.$limit) Agent accounts after \(\.$cursor)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentAccountDirectorySnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).accountDirectory(page: PageRequest(limit: limit, cursor: cursor))
        return .result(value: value)
    }
}

public struct GetAgentSyncStatusIntent: AppIntent {
    public static let isDiscoverable = false
    public static let title: LocalizedStringResource = "Get Agent Sync Status"
    public static let description = IntentDescription("Read cached status and actual freshness. This never starts synchronization.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Agent Account") public var account: AgentAccountEntity
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("Get cached sync status for \(\.$account)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentAccountSnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).syncStatus(accountID: account.id)
        let reference = AgentAccountEntity(id: account.id, network: value.account.wallet.network.rawValue)
        let id = try automationIdentity([account.id, "snapshot"], encoded: value.observation)
        return .result(value: try AgentAccountSnapshot(id: id, account: reference, balance: nil, status: value))
    }
}

public struct ListAgentTransactionsIntent: AppIntent {
    public static let title: LocalizedStringResource = "List Agent Transactions"
    public static let description = IntentDescription("Read one bounded cached transaction page; unknown amounts and confirmation facts remain unknown.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Agent Account") public var account: AgentAccountEntity
    @Parameter(title: "Maximum Results", default: 40) public var limit: Int
    @Parameter(title: "Cursor") public var cursor: String?
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("List up to \(\.$limit) transactions for \(\.$account) after \(\.$cursor)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentActivityPageSnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).transactions(accountID: account.id, page: PageRequest(limit: limit, cursor: cursor))
        return .result(value: try AgentActivityPageSnapshot(accountID: account.id, value: value))
    }
}

public struct ListAgentUTXOsIntent: AppIntent {
    public static let title: LocalizedStringResource = "List Agent Unspent Outputs"
    public static let description = IntentDescription("Read one advanced cached UTXO page with exact satoshis and the service-redacted reservation state.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Agent Account") public var account: AgentAccountEntity
    @Parameter(title: "Maximum Results", default: 40) public var limit: Int
    @Parameter(title: "Cursor") public var cursor: String?
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("List up to \(\.$limit) unspent outputs for \(\.$account) after \(\.$cursor)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentUTXOPageSnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).utxos(accountID: account.id, page: PageRequest(limit: limit, cursor: cursor))
        return .result(value: try AgentUTXOPageSnapshot(accountID: account.id, value: value))
    }
}

public struct SynchronizeAgentAccountIntent: AppIntent {
    public static let title: LocalizedStringResource = "Synchronize Agent Account"
    public static let description = IntentDescription("Execute or replay this retained synchronization request. A terminal replay returns the original result; use New for another refresh.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Retained Agent Request") public var request: AgentRequestHandleEntity
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("Synchronize Agent Account using \(\.$request)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentOperationSnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).execute(handleID: request.id, effect: .synchronizeAccount)
        return .result(value: try AgentOperationSnapshot(handleID: request.id, operation: value))
    }
}

public struct CreateAgentReceiveRequestIntent: AppIntent {
    public static let title: LocalizedStringResource = "Create Agent Receive Request"
    public static let description = IntentDescription("Execute or replay this retained receive request. A published allocation is immutable and cannot be reclaimed by cancellation.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Retained Agent Request") public var request: AgentRequestHandleEntity
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("Create Agent Receive Request using \(\.$request)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentOperationSnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).execute(handleID: request.id, effect: .createReceiveRequest)
        return .result(value: try AgentOperationSnapshot(handleID: request.id, operation: value))
    }
}

public struct PrepareAgentPaymentIntent: AppIntent {
    public static let title: LocalizedStringResource = "Prepare Agent Payment"
    public static let description = IntentDescription("Prepare or replay the same retained payment fields and key. This does not submit or grant owner approval.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Retained Agent Request") public var request: AgentRequestHandleEntity
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("Prepare Agent Payment using \(\.$request)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentOperationSnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).execute(handleID: request.id, effect: .preparePayment)
        return .result(value: try AgentOperationSnapshot(handleID: request.id, operation: value))
    }
}

public struct SubmitAgentPaymentIntent: AppIntent {
    public static let title: LocalizedStringResource = "Submit Agent Payment"
    public static let description = IntentDescription("Explicitly submit the retained payment using ordinary service policy and allowance. No automatic retry occurs; cancellation or revocation cannot recall an admitted handoff.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Agent Payment") public var payment: AgentPaymentOperationEntity
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("Submit \(\.$payment)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentOperationSnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).submit(handleID: payment.id)
        return .result(value: try AgentOperationSnapshot(handleID: payment.id, operation: .payment(value)))
    }
}

public struct ResumeAgentRequestIntent: AppIntent {
    public static let title: LocalizedStringResource = "Resume Agent Request"
    public static let description = IntentDescription("Inspect the same retained key after a lost response. This reads current service state without executing or retrying the request.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Retained Agent Request") public var request: AgentRequestHandleEntity
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("Resume \(\.$request)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentOperationSnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).resume(handleID: request.id)
        return .result(value: try AgentOperationSnapshot(handleID: request.id, operation: value))
    }
}

public struct CancelAgentOperationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Cancel Agent Operation"
    public static let description = IntentDescription("Ask the service to cancel the retained operation if its state permits. This is not undo and cannot recall funds already handed off.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Retained Agent Request") public var request: AgentRequestHandleEntity
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("Cancel \(\.$request)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentOperationSnapshot> {
        let value = try await AgentAutomationAdapter(dependency: dependency).cancel(handleID: request.id)
        return .result(value: try AgentOperationSnapshot(handleID: request.id, operation: value))
    }
}

public struct OpenAgentPaymentReviewIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Agent Payment Review"
    public static let description = IntentDescription("Open the exact retained payment in the separate owner destination. This returns navigation acknowledgement only, not owner data, approval or extra relay authority.")
    public static let supportedModes: IntentModes = .foreground(.immediate)
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Agent Payment") public var payment: AgentPaymentOperationEntity
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary { Summary("Open owner review for \(\.$payment)") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentReviewRouteReceipt> {
        let value = try await AgentAutomationAdapter(dependency: dependency).openReview(handleID: payment.id)
        return .result(value: AgentReviewRouteReceipt(handleID: payment.id, acknowledgment: value))
    }
}

public enum AgentRequestPurpose: String, AppEnum, Sendable {
    case synchronizeAccount, createReceiveRequest, preparePayment
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent Request Purpose")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .synchronizeAccount: "Synchronize Account", .createReceiveRequest: "Receive Request", .preparePayment: "Prepare Payment"
    ]
}

/// Creates identity locally. No service effect is performed until a separate explicit action uses the handle.
public struct NewAgentRequestIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Agent Request"
    public static let description = IntentDescription("Retain a new local handle and key before an effect. New means a distinct intention; reuse the same handle for replay or response recovery.")
    public static let supportedModes: IntentModes = .background
    public static let allowedExecutionTargets: IntentExecutionTargets = .main
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Purpose") public var purpose: AgentRequestPurpose
    @Parameter(title: "Agent Account") public var account: AgentAccountEntity
    @Parameter(title: "Destination Address") public var destinationAddress: String?
    @Parameter(title: "Amount (Satoshi)") public var amountSatoshis: Int?
    @Parameter(title: "Fee Rate (Satoshi Per Byte)", default: 1) public var feeRateSatoshisPerByte: Int
    @Parameter(title: "Expires At (Unix Seconds)") public var expiresAt: Int?
    @AppDependency(default: AgentAutomationDependency()) private var dependency
    public static var parameterSummary: some ParameterSummary {
        When(\.$purpose, .equalTo, .preparePayment) {
            Summary("New \(\.$purpose) request for \(\.$amountSatoshis) satoshi to \(\.$destinationAddress) from \(\.$account), fee rate \(\.$feeRateSatoshisPerByte), expiry \(\.$expiresAt)")
        } otherwise: {
            Summary("New \(\.$purpose) request for \(\.$account)")
        }
    }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<AgentRequestHandleEntity> {
        let adapter = AgentAutomationAdapter(dependency: dependency)
        let value: RetainedAgentAutomationRequest
        if purpose == .preparePayment {
            guard let destinationAddress else { throw $destinationAddress.needsValueError("Enter the destination address.") }
            guard let amountSatoshis else { throw $amountSatoshis.needsValueError("Enter the amount in satoshis.") }
            guard let amount = Int64(exactly: amountSatoshis), let fee = Int64(exactly: feeRateSatoshisPerByte) else {
                throw AgentAutomationFailure.invalidReference
            }
            let expiry = try expiresAt.map { value in
                guard let exact = Int64(exactly: value) else { throw AgentAutomationFailure.invalidReference }
                return exact
            }
            value = try await adapter.newPaymentRequest(accountID: account.id, destinationAddress: destinationAddress,
                amountSatoshis: amount, feeRateSatoshisPerByte: fee, expiresAt: expiry)
        } else {
            guard destinationAddress == nil, amountSatoshis == nil, expiresAt == nil, feeRateSatoshisPerByte == 1 else {
                throw AgentAutomationFailure.invalidReference
            }
            value = try await adapter.newRequest(accountID: account.id,
                effect: purpose == .synchronizeAccount ? .synchronizeAccount : .createReceiveRequest)
        }
        return .result(value: AgentRequestHandleEntity(value))
    }
}
