import AgentValues
import AgentClient
import AgentNativeIPC
import Foundation
import Testing

// These fixtures exercise the native codec's explicit dispatch switches and public client
// validation. No synthetic policy is treated as qualified and no native connection is opened.
func nativeFixtureAccount(_ accountID: String = "account-a", walletID: String = "wallet-a", network: WalletNetwork = .mainnet) throws -> AccountScope {
    try AccountScope(wallet: WalletScope(walletID: walletID, network: network), accountID: accountID)
}
func nativeCapabilityFixture(_ method: CapabilityMethod) throws -> (CapabilityCall, CapabilityResult) {
    let account = try nativeFixtureAccount()
    let key = try RequestKey(String(repeating: "01", count: 16))
    let selector = try OperationSelector(account: account, operationID: "operation-a")
    let identity = OperationIdentity(selector: selector, requestKey: key)
    let observation = SnapshotObservation(providerID: "provider-a", viewID: "view-a", chainTip: "tip-a", sequence: 1, observedAt: 100, generation: 2, fresh: true, complete: true)
    let page = try PageRequest(limit: 2)
    let keyed = KeyedAccountRequest(account: account, requestKey: key)
    let request = try PreparePaymentRequest(account: account, requestKey: key,
        destinationAddress: "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a", amountSatoshis: 500, expiresAt: 500)
    let preview = PaymentPreviewProjection(canonicalDestinationAddress: request.destinationAddress, destinationScriptHex: "76a914000000000000000000000000000000000000000088ac",
        amountSatoshis: 500, feeSatoshis: 10, selectedInputs: [Outpoint(transactionID: String(repeating: "ab", count: 32), outputIndex: 0)],
        change: [], templateDigest: String(repeating: "cd", count: 32), leaseDeadline: 500)
    let payment = PaymentOperation(identity: identity, request: request, state: .prepared, preview: preview)
    switch method {
    case .listWallets: return (.listWallets(page), .listWallets(CapabilityPage(items: [WalletSummary(scope: account.wallet)])))
    case .listAccounts: return (.listAccounts(WalletPageRequest(wallet: account.wallet, page: page)), .listAccounts(AccountList(wallet: account.wallet, page: CapabilityPage(items: [AccountSummary(scope: account)]))))
    case .getBalance: return (.getBalance(account), .getBalance(BalanceProjection(account: account, totalSatoshis: 1000, observation: observation)))
    case .listTransactions: return (.listTransactions(AccountPageRequest(account: account, page: page)), .listTransactions(AccountPage(account: account, observation: observation, page: CapabilityPage(items: [TransactionSummary(transactionID: String(repeating: "ab", count: 32), deltaSatoshis: -510, confirmations: 0)]))))
    case .listUTXOs: return (.listUTXOs(AccountPageRequest(account: account, page: page)), .listUTXOs(AccountPage(account: account, observation: observation, page: CapabilityPage(items: [UTXOSummary(outpoint: preview.selectedInputs[0], amountSatoshis: 1000, reservation: .unreserved)]))))
    case .getSyncStatus: return (.getSyncStatus(account), .getSyncStatus(SyncStatusProjection(account: account, observation: nil)))
    case .synchronizeAccount: return (.synchronizeAccount(keyed), .synchronizeAccount(SyncOperation(identity: identity, state: .completed, observation: observation)))
    case .createReceiveRequest: return (.createReceiveRequest(keyed), .createReceiveRequest(ReceiveOperation(identity: identity, state: .allocated, allocation: ReceiveAllocationProjection(address: request.destinationAddress, index: 19))))
    case .preparePayment: return (.preparePayment(request), .preparePayment(payment))
    case .submitPayment: return (.submitPayment(selector), .submitPayment(payment))
    case .getOperation: return (.getOperation(.operation(selector)), .getOperation(.payment(payment)))
    case .cancelOperation: return (.cancelOperation(selector), .cancelOperation(.payment(payment)))
    }
}
private func nativeOwnerFixture(_ method: OwnerControlMethod) throws -> (OwnerControlCall, OwnerControlResult) {
    let account = try nativeFixtureAccount()
    let (_, result) = try nativeCapabilityFixture(.preparePayment)
    guard case .preparePayment(let base) = result, let preview = base.preview else { throw CapabilityFailure.invalidResponse }
    let policy = ApprovalPolicyProjection(wallet: account.wallet, revision: 1, approvalRequired: false)
    let selector = try GrantSelector(wallet: account.wallet, grantID: "grant-a")
    let grant = GrantProjection(selector: selector, integrationID: "integration-a", accountIDs: [account.accountID], scopes: [.read, .prepare], expiresAt: nil, credentialGeneration: 1, state: .active)
    let restricted = OwnerWalletStatus(wallet: account.wallet, availability: .restricted, history: .complete, walletGeneration: 2,
        custody: .presentUnverified, approvalPolicy: policy, unresolvedOperations: [], grants: [grant])
    let previewContext = ExactPreviewReviewContext(operation: base.identity.selector, preview: preview, previewContextDigest: String(repeating: "ab", count: 32),
        walletGeneration: 2, policyRevision: 1, originGrantID: "grant-a", originCredentialGeneration: 1)
    let relayContext = ExactRelayReviewContext(operation: base.identity.selector, transactionDigest: String(repeating: "ef", count: 32),
        walletGeneration: 2, policyRevision: 1, evidenceRevision: 3, accountLiabilityContextDigest: String(repeating: "de", count: 32))
    let attempt = RelayAttemptProjection(attemptID: "attempt-owner", number: 2, route: .owner, outcome: .admitted, admittedAt: 100)
    let uncertain = PaymentOperation(identity: base.identity, request: base.request, state: .uncertain, preview: preview, accountRestriction: .held,
        liabilityUnresolved: true, evidence: PaymentEvidenceProjection(revision: 3, support: .unsupported), ordinaryAdmissions: 1, latestAttempt: attempt)
    let relayKey = try RequestKey(String(repeating: "02", count: 16))
    let receipt = OwnerRelayReceipt(wallet: account.wallet, requestKey: relayKey, context: relayContext, attempt: attempt, outcome: .admitted, terminalReason: nil, payment: uncertain)
    let credential = try SensitiveOwnerMaterial(bytes: Data(repeating: 0x7f, count: 32))
    switch method {
    case .status: return (.status, .status(restricted))
    case .listAccounts:
        return (.listAccounts(account.wallet), .listAccounts(OwnerAccountDirectory(wallet: account.wallet, walletGeneration: 2, accounts: [account])))
    case .listPayments:
        let request = WalletPageRequest(wallet: account.wallet, page: try PageRequest(limit: 2))
        return (.listPayments(request), .listPayments(OwnerPaymentPage(wallet: account.wallet, walletGeneration: 2, snapshotID: String(repeating: "aa", count: 32), page: CapabilityPage(items: [base]))))
    case .inspectRecovery: return (.inspectRecovery, .inspectRecovery(OwnerRecoveryStatus(status: restricted, availableSources: [try RecoverySourceHandle("archive-a")])))
    case .createWallet: return (.createWallet(network: .mainnet), .createWallet(restricted))
    case .restoreSeed: return (.restoreSeed(SeedRestoreRequest(network: .mainnet, mnemonic: try SensitiveOwnerMaterial(bytes: Data("synthetic-owner-input".utf8)))), .restoreSeed(restricted))
    case .exportRecoveryMaterial: return (.exportRecoveryMaterial(account.wallet), .exportRecoveryMaterial(OwnerRecoveryMaterial(wallet: account.wallet, material: try SensitiveOwnerMaterial(bytes: Data("synthetic-owner-export".utf8)))))
    case .recoverJournal: return (.recoverJournal(JournalRecoveryRequest(wallet: account.wallet, source: try RecoverySourceHandle("archive-a"))), .recoverJournal(restricted))
    case .discoverPublicAccount: return (.discoverPublicAccount(account), .discoverPublicAccount(SyncStatusProjection(account: account, observation: nil)))
    case .enableWallet:
        let enabled = OwnerWalletStatus(wallet: account.wallet, availability: .enabled, history: .complete, walletGeneration: 2,
            custody: .presentUnverified, approvalPolicy: policy, unresolvedOperations: [], grants: [grant])
        return (.enableWallet(account.wallet), .enableWallet(enabled))
    case .enrollIntegration:
        return (.enrollIntegration(try EnrollmentRequest(wallet: account.wallet, integrationID: "integration-a", accountIDs: [account.accountID], scopes: [.read, .prepare])), .enrollIntegration(OwnerIssuedCredential(grant: grant, credential: credential)))
    case .rotateGrant: return (.rotateGrant(selector), .rotateGrant(OwnerIssuedCredential(grant: grant, credential: credential)))
    case .revokeGrant:
        let revoked = GrantProjection(selector: selector, integrationID: grant.integrationID, accountIDs: grant.accountIDs, scopes: grant.scopes,
            expiresAt: nil, credentialGeneration: 1, state: .revoked)
        return (.revokeGrant(selector), .revokeGrant(GrantRevocationProjection(grant: revoked, admittedOperations: [base.identity.selector])))
    case .setApprovalPolicy: return (.setApprovalPolicy(ApprovalPolicyRequest(wallet: account.wallet, expectedRevision: 1, approvalRequired: false)), .setApprovalPolicy(policy))
    case .paymentStatus: return (.paymentStatus(base.identity.selector), .paymentStatus(base))
    case .reviewPreview: return (.reviewPreview(base.identity.selector), .reviewPreview(previewContext))
    case .approveExactPayment:
        let ready = PaymentOperation(identity: base.identity, request: base.request, state: .ready, preview: preview)
        return (.approveExactPayment(previewContext), .approveExactPayment(ready))
    case .rejectExactPayment:
        let closed = PaymentOperation(identity: base.identity, request: base.request, state: .closed, preview: preview,
            terminalReason: .rejected, closures: [PaymentClosureProjection(reason: .rejected, evidenceRevision: 0, support: .notApplicable)], accountRestriction: .clear)
        return (.rejectExactPayment(previewContext), .rejectExactPayment(closed))
    case .reviewRelay: return (.reviewRelay(base.identity.selector), .reviewRelay(relayContext))
    case .authorizeExactRelay: return (.authorizeExactRelay(OwnerRelayRequest(requestKey: relayKey, context: relayContext)), .authorizeExactRelay(receipt))
    case .relayReceipt: return (.relayReceipt(OwnerReceiptSelector(wallet: account.wallet, requestKey: relayKey)), .relayReceipt(receipt))
    }
}

@Test(arguments: CapabilityMethod.allCases)
func nativeCodecPreservesEveryIntegrationContract(_ method: CapabilityMethod) throws {
    let (call, result) = try nativeCapabilityFixture(method)
    let id = UUID(), request = CapabilityRequest(call: call), response = CapabilityResponse(result: result)
    let (decodedID, decoded) = try NativeWire.decodeCapabilityRequest(NativeWire.capabilityRequest(request, requestID: id))
    #expect(decodedID == id && decoded == request)
    #expect(try NativeWire.decodeCapabilityResponse(NativeWire.capabilityResponse(response, requestID: id), requestID: id) == response)
}

@Test(arguments: OwnerControlMethod.allCases)
func nativeCodecPreservesEverySeparateOwnerContractAndSensitiveSlot(_ method: OwnerControlMethod) async throws {
    let (call, result) = try nativeOwnerFixture(method)
    let id = UUID()
    let request = try NativeWire.ownerRequest(OwnerControlRequest(call: call), requestID: id)
    let (decodedID, decoded) = try NativeWire.decodeOwnerRequest(request)
    #expect(decodedID == id && decoded.call.method == method)
    let reencoded = try NativeWire.ownerRequest(decoded, requestID: id)
    #expect(reencoded.frame == request.frame && reencoded.sensitive == request.sensitive)
    let response = try NativeWire.ownerResponse(OwnerControlResponse(result: result), requestID: id)
    let value = try NativeWire.decodeOwnerResponse(response, requestID: id, method: method)
    #expect(response.sensitive == nativeExpectedSensitive(result))
    #expect(nativeExpectedSensitive(value.result) == nativeExpectedSensitive(result))
    let transport = NativeFixedOwnerTransport(response: value)
    #expect(try await OwnerControlClient(transport: transport).call(call).method == method)
    let roundTrip = try NativeWire.ownerResponse(value, requestID: id)
    #expect(roundTrip.frame == response.frame && roundTrip.sensitive == response.sensitive)
    #expect((request.sensitive != nil) == (method == .restoreSeed))
    #expect((response.sensitive != nil) == [.exportRecoveryMaterial, .enrollIntegration, .rotateGrant].contains(method))
    let wrong: OwnerControlMethod = method == .status ? .inspectRecovery : .status
    #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.decodeOwnerResponse(response, requestID: id, method: wrong) }
}
private func nativeExpectedSensitive(_ result: OwnerControlResult) -> Data? {
    switch result {
    case .exportRecoveryMaterial(let value): return value.material.withBytes { $0 }
    case .enrollIntegration(let value), .rotateGrant(let value): return value.credential.withBytes { $0 }
    default: return nil
    }
}
private struct NativeFixedOwnerTransport: OwnerControlTransport {
    let response: OwnerControlResponse
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse { response }
}
private struct NativeDenyConsent: NativeWalletConsentProvider {
    func authenticate(_ challenge: NativeConsentChallenge) async throws -> NativeConsentProof { throw ClientFailure.unavailable }
}
@Test func nativeOrdinaryFactoryCannotOpenEitherChannelWithoutTrustedDeployment() {
    let factory = NativeClientFactory()
    #expect(throws: ClientFailure.unavailable) { try factory.integrationTransport(credential: Data(repeating: 0x22, count: 32)) }
    #expect(throws: ClientFailure.unavailable) { try factory.ownerTransport(consent: NativeDenyConsent()) }
}
@Test func nativeEncoderRejectsUnboundedTypedValuesBeforeJSONEncoding() {
    #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.encode(String(repeating: "a", count: NativeWire.maximumFrameBytes + 1)) }
    #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.encode(Array(repeating: "a", count: 20_000)) }
    #expect(throws: NativeIPCFailure.malformedFrame) { try NativeWire.encode(Data(count: NativeWire.maximumFrameBytes + 1)) }
}

@Test(arguments: ["policy", "enrollment", "seed", "preview", "relay"])
func nativeSensitiveConsentCommitmentBindsExactPendingRequest(_ field: String) throws {
    let account = try nativeFixtureAccount()
    let first: OwnerControlCall
    let changed: OwnerControlCall
    switch field {
    case "policy":
        first = .setApprovalPolicy(.init(wallet: account.wallet, expectedRevision: 1, approvalRequired: true))
        changed = .setApprovalPolicy(.init(wallet: account.wallet, expectedRevision: 2, approvalRequired: true))
    case "enrollment":
        first = .enrollIntegration(try EnrollmentRequest(wallet: account.wallet, integrationID: "same", accountIDs: [account.accountID], scopes: [.read]))
        changed = .enrollIntegration(try EnrollmentRequest(wallet: account.wallet, integrationID: "same", accountIDs: [account.accountID], scopes: [.read, .prepare]))
    case "seed":
        first = .restoreSeed(.init(network: .mainnet, mnemonic: try SensitiveOwnerMaterial(bytes: Data("synthetic-a".utf8))))
        changed = .restoreSeed(.init(network: .mainnet, mnemonic: try SensitiveOwnerMaterial(bytes: Data("synthetic-b".utf8))))
    case "preview":
        let (call, _) = try nativeOwnerFixture(.approveExactPayment)
        guard case .approveExactPayment(let context) = call else { throw NativeIPCFailure.malformedFrame }
        first = call
        changed = .approveExactPayment(.init(operation: context.operation, preview: context.preview,
            previewContextDigest: context.previewContextDigest, walletGeneration: context.walletGeneration,
            policyRevision: context.policyRevision + 1, originGrantID: context.originGrantID,
            originCredentialGeneration: context.originCredentialGeneration))
    default:
        let (call, _) = try nativeOwnerFixture(.authorizeExactRelay)
        guard case .authorizeExactRelay(let request) = call else { throw NativeIPCFailure.malformedFrame }
        first = call
        let c = request.context
        changed = .authorizeExactRelay(.init(requestKey: request.requestKey, context: .init(operation: c.operation,
            transactionDigest: String(repeating: "aa", count: 32), walletGeneration: c.walletGeneration,
            policyRevision: c.policyRevision, evidenceRevision: c.evidenceRevision,
            accountLiabilityContextDigest: c.accountLiabilityContextDigest)))
    }
    let commitment = try NativeWire.reviewCommitment(first)
    #expect(first.method == changed.method && commitment.count == 32)
    #expect(try NativeWire.reviewCommitment(first) == commitment)
    #expect(try NativeWire.reviewCommitment(changed) != commitment)
}
@Test(arguments: OwnerControlMethod.allCases)
func nativeEverySensitiveMethodHasAStableNonemptyConsentBinding(_ method: OwnerControlMethod) throws {
    let (call, _) = try nativeOwnerFixture(method)
    let bytes = try NativeWire.reviewCommitment(call)
    let polling: Set<OwnerControlMethod> = [.status, .inspectRecovery, .listAccounts, .listPayments, .paymentStatus, .reviewPreview, .reviewRelay, .relayReceipt]
    #expect(bytes.count == (polling.contains(method) ? 0 : 32))
    #expect(try NativeWire.reviewCommitment(call) == bytes)
}

@Test(arguments: [OwnerControlMethod.listAccounts, .listPayments])
func nativeOwnerDiscoveryFramesRejectWrongKindAndNestedAuthorityFields(_ method: OwnerControlMethod) throws {
    let (call, result) = try nativeOwnerFixture(method), id = UUID()
    let request = try NativeWire.ownerRequest(OwnerControlRequest(call: call), requestID: id)
    var outer = try #require(JSONSerialization.jsonObject(with: request.frame) as? [String: Any])
    outer["kind"] = NativeFrameKind.capabilityRequest.rawValue
    #expect(throws: NativeIPCFailure.malformedFrame) {
        try NativeWire.decodeOwnerRequest(NativeOwnerPacket(frame: JSONSerialization.data(withJSONObject: outer)))
    }
    let original = try NativeWire.unpack(request.frame, kind: .ownerRequest)
    var body = try #require(JSONSerialization.jsonObject(with: original.payload) as? [String: Any])
    let encodedPayload = try #require(body["payload"] as? String)
    let payload = try #require(Data(base64Encoded: encodedPayload))
    var parameters = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    if method == .listAccounts { parameters["approved"] = true }
    else {
        var wallet = try #require(parameters["wallet"] as? [String: Any]); wallet["owner"] = true; parameters["wallet"] = wallet
    }
    body["payload"] = try JSONSerialization.data(withJSONObject: parameters).base64EncodedString()
    let malicious = NativeFrame(requestID: id, kind: .ownerRequest, payload: try JSONSerialization.data(withJSONObject: body))
    #expect(throws: (any Error).self) { try NativeWire.decodeOwnerRequest(NativeOwnerPacket(frame: NativeWire.encode(malicious))) }
    let response = try NativeWire.ownerResponse(OwnerControlResponse(result: result), requestID: id)
    #expect(request.sensitive == nil && response.sensitive == nil)
    #expect(try NativeWire.reviewCommitment(call).isEmpty)
    #expect(throws: NativeIPCFailure.malformedFrame) {
        try NativeWire.decodeOwnerResponse(NativeOwnerPacket(frame: response.frame, sensitive: Data([1])), requestID: id, method: method)
    }
}
