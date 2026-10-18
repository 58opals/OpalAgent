import Foundation
import Testing
import AgentValues
import AgentClient

private struct FixedOwnerTransport: OwnerControlTransport {
    let response: OwnerControlResponse
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse { response }
}
private actor RecordingOwnerTransport: OwnerControlTransport {
    let response: OwnerControlResponse
    var methods: [OwnerControlMethod] = []
    var versions: [Int] = []
    init(_ result: OwnerControlResult) { response = OwnerControlResponse(result: result) }
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        methods.append(request.call.method); versions.append(request.protocolVersion); return response
    }
}
private func ownerClient(_ result: OwnerControlResult, version: Int = ServiceStatus.currentProtocolVersion) -> OwnerControlClient {
    OwnerControlClient(transport: FixedOwnerTransport(response: OwnerControlResponse(protocolVersion: version, result: result)))
}
private func ownerFixture(_ method: OwnerControlMethod) throws -> (OwnerControlCall, OwnerControlResult) {
    let account = try capabilityAccount()
    let (_, result) = try capabilityFixture(.preparePayment)
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
        return (.listPayments(request), .listPayments(OwnerPaymentPage(wallet: account.wallet, walletGeneration: 2,
            snapshotID: String(repeating: "aa", count: 32), page: CapabilityPage(items: [base]))))
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

@Test(arguments: OwnerControlMethod.allCases)
func ownerControlClientForwardsEachSeparateTypedOwnerCapability(_ method: OwnerControlMethod) async throws {
    let (call, result) = try ownerFixture(method)
    let transport = RecordingOwnerTransport(result)
    #expect(try await OwnerControlClient(transport: transport).call(call).method == method)
    #expect(await transport.methods == [method])
    #expect(await transport.versions == [ServiceStatus.currentProtocolVersion])
}

@Test func ownerControlClientDefaultsUnavailableAndRejectsProtocolOrKindMismatch() async throws {
    await #expect(throws: ClientFailure.unavailable) { try await OwnerControlClient().call(.status) }
    let (_, result) = try ownerFixture(.status)
    await #expect(throws: ClientFailure.incompatibleProtocol) { try await ownerClient(result, version: ServiceStatus.currentProtocolVersion + 1).call(.status) }
    await #expect(throws: CapabilityFailure.invalidResponse) { try await ownerClient(result).call(.inspectRecovery) }
}

@Test func ownerControlSensitiveMaterialIsIsolatedAndRedacted() throws {
    let marker = "CANARY_OWNER_ONLY"
    let material = try SensitiveOwnerMaterial(bytes: Data(marker.utf8))
    let request = OwnerControlRequest(call: .restoreSeed(SeedRestoreRequest(network: .chipnet, mnemonic: material)))
    let result = OwnerControlResult.exportRecoveryMaterial(OwnerRecoveryMaterial(wallet: try capabilityAccount().wallet, material: material))
    #expect(!isEncodable(material) && !isEncodable(request) && !isEncodable(result))
    var output = ""
    dump(request, to: &output)
    #expect(!output.contains(marker) && !String(reflecting: request).contains(marker))
    #expect(String(describing: material) == "<redacted owner material>")
    #expect(material.withBytes { $0 == Data(marker.utf8) })
    #expect(throws: CapabilityFailure.invalidRequest) { try SensitiveOwnerMaterial(bytes: Data()) }
}
private func isEncodable(_ value: Any) -> Bool { value is any Encodable }

@Test func ownerControlStatusWorksBeforeWalletExistsAndNeverRequiresCustodyOpening() async throws {
    let missing = OwnerWalletStatus(wallet: nil, availability: .unavailable, history: .unknown, walletGeneration: nil,
        custody: .absent, approvalPolicy: nil, unresolvedOperations: [])
    guard case .status(let response) = try await ownerClient(.status(missing)).call(.status) else { Issue.record("Wrong owner result"); return }
    #expect(response.wallet == nil && response.custody == .absent)
    let (call, result) = try ownerFixture(.status)
    guard case .status(let current) = try await ownerClient(result).call(call) else { Issue.record("Wrong owner result"); return }
    #expect(current.custody == .presentUnverified && current.grants.count == 1)
}

@Test func ownerControlRejectsWrongWalletAndEnrollmentScopeExpansion() async throws {
    let (call, result) = try ownerFixture(.enrollIntegration)
    guard case .enrollIntegration(let issued) = result else { throw CapabilityFailure.invalidResponse }
    let grant = issued.grant
    let expanded = GrantProjection(selector: grant.selector, integrationID: grant.integrationID, accountIDs: grant.accountIDs,
        scopes: [.read, .prepare, .submit], expiresAt: grant.expiresAt, credentialGeneration: grant.credentialGeneration, state: .active)
    await #expect(throws: CapabilityFailure.invalidResponse) {
        try await ownerClient(.enrollIntegration(OwnerIssuedCredential(grant: expanded, credential: issued.credential))).call(call)
    }
    let foreignWallet = try capabilityAccount(walletID: "wallet-b").wallet
    await #expect(throws: CapabilityFailure.invalidResponse) {
        try await ownerClient(.exportRecoveryMaterial(OwnerRecoveryMaterial(wallet: foreignWallet, material: issued.credential))).call(.exportRecoveryMaterial(grant.selector.wallet))
    }
}

@Test func ownerControlRejectsMalformedExpectedPreviewBeforeTransportAndComparesExactPreview() async throws {
    let (call, result) = try ownerFixture(.approveExactPayment)
    guard case .approveExactPayment(let context) = call, case .approveExactPayment(let payment) = result else { throw CapabilityFailure.invalidResponse }
    let malformed = ExactPreviewReviewContext(operation: context.operation, preview: context.preview, previewContextDigest: "not-a-digest",
        walletGeneration: context.walletGeneration, policyRevision: context.policyRevision, originGrantID: context.originGrantID, originCredentialGeneration: context.originCredentialGeneration)
    let transport = RecordingOwnerTransport(result)
    await #expect(throws: CapabilityFailure.invalidRequest) { try await OwnerControlClient(transport: transport).call(.approveExactPayment(malformed)) }
    #expect(await transport.methods.isEmpty)
    let alteredPreview = PaymentPreviewProjection(canonicalDestinationAddress: context.preview.canonicalDestinationAddress,
        destinationScriptHex: context.preview.destinationScriptHex, amountSatoshis: context.preview.amountSatoshis, feeSatoshis: context.preview.feeSatoshis + 1,
        selectedInputs: context.preview.selectedInputs, change: context.preview.change, templateDigest: context.preview.templateDigest, leaseDeadline: context.preview.leaseDeadline)
    let altered = PaymentOperation(identity: payment.identity, request: payment.request, state: payment.state, preview: alteredPreview)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await ownerClient(.approveExactPayment(altered)).call(call) }
}

@Test func ownerControlPreviewAndRelayReviewsAreDistinctComparableContexts() async throws {
    let (_, previewResult) = try ownerFixture(.reviewPreview)
    let (_, relayResult) = try ownerFixture(.reviewRelay)
    guard case .reviewPreview(let preview) = previewResult, case .reviewRelay(let relay) = relayResult else { throw CapabilityFailure.invalidResponse }
    #expect(preview.previewContextDigest != relay.transactionDigest)
    #expect(try JSONDecoder().decode(ExactPreviewReviewContext.self, from: JSONEncoder().encode(preview)) == preview)
    #expect(try JSONDecoder().decode(ExactRelayReviewContext.self, from: JSONEncoder().encode(relay)) == relay)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any])
    #expect(object["transactionDigest"] == nil && object["previewContextDigest"] != nil)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await ownerClient(relayResult).call(.reviewPreview(preview.operation)) }
}

@Test func ownerControlRelayReceiptBindsKeyAndWholeSignedContextWithoutRefilling() async throws {
    let (call, result) = try ownerFixture(.authorizeExactRelay)
    guard case .authorizeExactRelay(let receipt) = result else { throw CapabilityFailure.invalidResponse }
    let otherKey = try RequestKey(String(repeating: "03", count: 16))
    let wrongKey = OwnerRelayReceipt(wallet: receipt.wallet, requestKey: otherKey, context: receipt.context, attempt: receipt.attempt,
        outcome: receipt.outcome, terminalReason: receipt.terminalReason, payment: receipt.payment)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await ownerClient(.authorizeExactRelay(wrongKey)).call(call) }
    let original = receipt.context
    let changed = ExactRelayReviewContext(operation: original.operation, transactionDigest: original.transactionDigest, walletGeneration: original.walletGeneration,
        policyRevision: original.policyRevision, evidenceRevision: original.evidenceRevision + 1, accountLiabilityContextDigest: original.accountLiabilityContextDigest)
    let wrongContext = OwnerRelayReceipt(wallet: receipt.wallet, requestKey: receipt.requestKey, context: changed, attempt: receipt.attempt,
        outcome: receipt.outcome, terminalReason: receipt.terminalReason, payment: receipt.payment)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await ownerClient(.authorizeExactRelay(wrongContext)).call(call) }
    let replay = try await ownerClient(result).call(call)
    guard case .authorizeExactRelay(let historical) = replay else { throw CapabilityFailure.invalidResponse }
    #expect(historical.attempt?.number == 2 && historical.payment.ordinaryAdmissions == 1)
}

@Test func ownerControlRelayNoAdmissionIsExplicitAndHistoricalReceiptCanOutliveCurrentEvidence() async throws {
    let (_, result) = try ownerFixture(.relayReceipt)
    guard case .relayReceipt(let receipt) = result else { throw CapabilityFailure.invalidResponse }
    let noAdmission = OwnerRelayReceipt(wallet: receipt.wallet, requestKey: receipt.requestKey, context: receipt.context, attempt: nil,
        outcome: .noAdmission, terminalReason: .relayNotEligible, payment: receipt.payment)
    let selector = OwnerReceiptSelector(wallet: receipt.wallet, requestKey: receipt.requestKey)
    #expect(try await ownerClient(.relayReceipt(noAdmission)).call(.relayReceipt(selector)).method == .relayReceipt)
    let bad = OwnerRelayReceipt(wallet: receipt.wallet, requestKey: receipt.requestKey, context: receipt.context, attempt: nil,
        outcome: .admitted, terminalReason: nil, payment: receipt.payment)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await ownerClient(.relayReceipt(bad)).call(.relayReceipt(selector)) }
    let p = receipt.payment
    let current = PaymentOperation(identity: p.identity, request: p.request, state: p.state, preview: p.preview, accountRestriction: .held,
        liabilityUnresolved: true, evidence: PaymentEvidenceProjection(revision: 9, support: .unsupported), ordinaryAdmissions: p.ordinaryAdmissions, latestAttempt: p.latestAttempt)
    let historical = OwnerRelayReceipt(wallet: receipt.wallet, requestKey: receipt.requestKey, context: receipt.context, attempt: receipt.attempt,
        outcome: receipt.outcome, terminalReason: nil, payment: current)
    #expect(try await ownerClient(.relayReceipt(historical)).call(.relayReceipt(selector)).method == .relayReceipt)
}
