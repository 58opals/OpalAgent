import Foundation
import Testing
import AgentValues
import AgentClient

func capabilityAccount(_ accountID: String = "account-a", walletID: String = "wallet-a", network: WalletNetwork = .mainnet) throws -> AccountScope {
    try AccountScope(wallet: WalletScope(walletID: walletID, network: network), accountID: accountID)
}
func capabilityFixture(_ method: CapabilityMethod) throws -> (CapabilityCall, CapabilityResult) {
    let account = try capabilityAccount()
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
private struct FixedCapabilityTransport: CapabilityTransport {
    let response: CapabilityResponse
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse { response }
}
private actor RecordingCapabilityTransport: CapabilityTransport {
    var requests: [CapabilityRequest] = []
    let response: CapabilityResponse
    init(response: CapabilityResponse) { self.response = response }
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse { requests.append(request); return response }
}
private func client(_ result: CapabilityResult, version: Int = ServiceStatus.currentProtocolVersion) -> CapabilityClient {
    CapabilityClient(transport: FixedCapabilityTransport(response: CapabilityResponse(protocolVersion: version, result: result)))
}

@Test(arguments: CapabilityMethod.allCases)
func capabilityClientAcceptsAndForwardsAllTwelveTypedContracts(_ method: CapabilityMethod) async throws {
    let (call, result) = try capabilityFixture(method)
    let encodedResponse = try JSONEncoder().encode(CapabilityResponse(result: result))
    let decoded = try JSONDecoder().decode(CapabilityResponse.self, from: encodedResponse)
    let transport = RecordingCapabilityTransport(response: decoded)
    #expect(try await CapabilityClient(transport: transport).call(call) == result)
    #expect(await transport.requests == [CapabilityRequest(call: call)])
}

@Test func capabilityClientDefaultsToUnavailableAndRejectsWrongVersionOrKind() async throws {
    let (call, result) = try capabilityFixture(.getBalance)
    await #expect(throws: ClientFailure.unavailable) { try await CapabilityClient().call(call) }
    await #expect(throws: ClientFailure.incompatibleProtocol) { try await client(result, version: ServiceStatus.currentProtocolVersion + 1).call(call) }
    let wrongKind = try capabilityFixture(.getSyncStatus).1
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(wrongKind).call(call) }
}

@Test(arguments: [CapabilityMethod.listAccounts, .getBalance, .listTransactions, .listUTXOs, .getSyncStatus, .synchronizeAccount, .createReceiveRequest, .preparePayment, .submitPayment, .getOperation, .cancelOperation])
func capabilityClientRejectsForeignWalletAccountOrNetwork(_ method: CapabilityMethod) async throws {
    let (call, result) = try capabilityFixture(method)
    let foreignAccount = try capabilityAccount("account-b", walletID: "wallet-b", network: .chipnet)
    let foreign = try replacingAccount(result, with: foreignAccount)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(foreign).call(call) }
}

@Test(arguments: [CapabilityMethod.submitPayment, .getOperation, .cancelOperation])
func capabilityClientRejectsAnotherImmutableOperation(_ method: CapabilityMethod) async throws {
    let (call, result) = try capabilityFixture(method)
    let payment = try paymentValue(result)
    let otherIdentity = OperationIdentity(selector: try OperationSelector(account: payment.request.account, operationID: "operation-b"), requestKey: payment.identity.requestKey)
    let other = PaymentOperation(identity: otherIdentity, request: payment.request, state: payment.state, preview: payment.preview)
    let response: CapabilityResult
    switch method { case .submitPayment: response = .submitPayment(other); case .getOperation: response = .getOperation(.payment(other)); default: response = .cancelOperation(.payment(other)) }
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(response).call(call) }
}

@Test func capabilityClientBindsRetainedKeyAndEffectAndPrepareNumericContext() async throws {
    let (call, result) = try capabilityFixture(.preparePayment)
    let payment = try paymentValue(result)
    let badKey = try RequestKey(String(repeating: "02", count: 16))
    let wrongIdentity = OperationIdentity(selector: payment.identity.selector, requestKey: badKey)
    let wrongKey = PaymentOperation(identity: wrongIdentity, request: payment.request, state: payment.state, preview: payment.preview)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(.preparePayment(wrongKey)).call(call) }
    let lookup = CapabilityCall.getOperation(.request(account: payment.request.account, effect: .createReceiveRequest, key: payment.identity.requestKey))
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(.getOperation(.payment(payment))).call(lookup) }
    let different = try PreparePaymentRequest(account: payment.request.account, requestKey: payment.request.requestKey,
        destinationAddress: payment.request.destinationAddress, amountSatoshis: 500, feeRateSatoshisPerByte: 2, expiresAt: 500)
    let wrongContext = PaymentOperation(identity: payment.identity, request: different, state: payment.state, preview: payment.preview)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(.preparePayment(wrongContext)).call(call) }
}

@Test func capabilityClientDoesNotInventAnAddressNormalizerForSemanticReplay() async throws {
    let (call, result) = try capabilityFixture(.preparePayment)
    let payment = try paymentValue(result)
    let alternateDisplay = try PreparePaymentRequest(account: payment.request.account, requestKey: payment.request.requestKey,
        destinationAddress: payment.request.destinationAddress.uppercased(), amountSatoshis: payment.request.amountSatoshis,
        feeRateSatoshisPerByte: payment.request.feeRateSatoshisPerByte, expiresAt: payment.request.expiresAt)
    let retained = PaymentOperation(identity: payment.identity, request: alternateDisplay, state: payment.state, preview: payment.preview)
    #expect(try await client(.preparePayment(retained)).call(call) == .preparePayment(retained))
}

@Test func capabilityClientRejectsOversizedOrDuplicatePagesAndHonorsRequestedLimit() async throws {
    let account = try capabilityAccount()
    let tooMany = CapabilityPage(items: try (0..<41).map { index in WalletSummary(scope: try WalletScope(walletID: "wallet-\(index)", network: .mainnet)) })
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(.listWallets(tooMany)).call(.listWallets(try PageRequest())) }
    let wallets = CapabilityPage(items: [WalletSummary(scope: account.wallet), WalletSummary(scope: try WalletScope(walletID: "wallet-b", network: .mainnet))])
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(.listWallets(wallets)).call(.listWallets(try PageRequest(limit: 1))) }
    let duplicates = CapabilityPage(items: [WalletSummary(scope: account.wallet), WalletSummary(scope: account.wallet)])
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(.listWallets(duplicates)).call(.listWallets(try PageRequest(limit: 2))) }
    #expect(try await client(.listWallets(wallets)).call(.listWallets(try PageRequest(limit: 40))) == .listWallets(wallets))
}

@Test func capabilityClientRejectsMalformedPaymentProjectionAndUnknownState() async throws {
    let (call, result) = try capabilityFixture(.preparePayment)
    let payment = try paymentValue(result)
    let missingPreview = PaymentOperation(identity: payment.identity, request: payment.request, state: .ready, preview: nil)
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(.preparePayment(missingPreview)).call(call) }
    let preview = try #require(payment.preview)
    let wrongAmount = PaymentPreviewProjection(canonicalDestinationAddress: preview.canonicalDestinationAddress, destinationScriptHex: preview.destinationScriptHex,
        amountSatoshis: 501, feeSatoshis: preview.feeSatoshis, selectedInputs: preview.selectedInputs, change: preview.change, templateDigest: preview.templateDigest, leaseDeadline: preview.leaseDeadline)
    await #expect(throws: CapabilityFailure.invalidResponse) {
        try await client(.preparePayment(PaymentOperation(identity: payment.identity, request: payment.request, state: .prepared, preview: wrongAmount))).call(call)
    }
    var encoded = String(decoding: try JSONEncoder().encode(CapabilityResponse(result: result)), as: UTF8.self)
    encoded = encoded.replacingOccurrences(of: "\"prepared\"", with: "\"ownerApprovedForever\"")
    #expect(throws: (any Error).self) { try JSONDecoder().decode(CapabilityResponse.self, from: Data(encoded.utf8)) }
    let account = try capabilityAccount()
    let malformed = BalanceProjection(account: account, totalSatoshis: -1, observation: SnapshotObservation(providerID: "provider-a", viewID: "view-a", chainTip: "tip-a", sequence: 1, observedAt: 100, generation: 2, fresh: true, complete: true))
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(.getBalance(malformed)).call(.getBalance(account)) }
}

private func paymentValue(_ result: CapabilityResult) throws -> PaymentOperation {
    switch result { case .preparePayment(let v), .submitPayment(let v), .getOperation(.payment(let v)), .cancelOperation(.payment(let v)): return v; default: throw CapabilityFailure.invalidResponse }
}
private func replacingAccount(_ result: CapabilityResult, with account: AccountScope) throws -> CapabilityResult {
    switch result {
    case .listAccounts(let v): return .listAccounts(AccountList(wallet: account.wallet, page: v.page))
    case .getBalance(let v): return .getBalance(BalanceProjection(account: account, totalSatoshis: v.totalSatoshis, observation: v.observation))
    case .listTransactions(let v): return .listTransactions(AccountPage(account: account, observation: v.observation, page: v.page))
    case .listUTXOs(let v): return .listUTXOs(AccountPage(account: account, observation: v.observation, page: v.page))
    case .getSyncStatus(let v): return .getSyncStatus(SyncStatusProjection(account: account, observation: v.observation))
    case .synchronizeAccount(let v): return .synchronizeAccount(SyncOperation(identity: OperationIdentity(selector: try OperationSelector(account: account, operationID: v.identity.selector.operationID), requestKey: v.identity.requestKey), state: v.state, observation: v.observation))
    case .createReceiveRequest(let v): return .createReceiveRequest(ReceiveOperation(identity: OperationIdentity(selector: try OperationSelector(account: account, operationID: v.identity.selector.operationID), requestKey: v.identity.requestKey), state: v.state, allocation: v.allocation, closeReason: v.closeReason, blocker: v.blocker))
    default:
        let v = try paymentValue(result)
        let request = try PreparePaymentRequest(account: account, requestKey: v.request.requestKey, destinationAddress: v.request.destinationAddress,
            amountSatoshis: v.request.amountSatoshis, feeRateSatoshisPerByte: v.request.feeRateSatoshisPerByte, expiresAt: v.request.expiresAt)
        let payment = PaymentOperation(identity: OperationIdentity(selector: try OperationSelector(account: account, operationID: v.identity.selector.operationID), requestKey: v.identity.requestKey), request: request, state: v.state, preview: v.preview)
        switch result { case .preparePayment: return .preparePayment(payment); case .submitPayment: return .submitPayment(payment); case .getOperation: return .getOperation(.payment(payment)); default: return .cancelOperation(.payment(payment)) }
    }
}

@Test(arguments: [CapabilityMethod.synchronizeAccount, .createReceiveRequest])
func capabilityClientRejectsMismatchedReceiveAndSyncKeys(_ method: CapabilityMethod) async throws {
    let (call, result) = try capabilityFixture(method)
    let key = try RequestKey(String(repeating: "02", count: 16))
    let response: CapabilityResult
    switch result {
    case .synchronizeAccount(let v): response = .synchronizeAccount(SyncOperation(identity: OperationIdentity(selector: v.identity.selector, requestKey: key), state: v.state, observation: v.observation))
    case .createReceiveRequest(let v): response = .createReceiveRequest(ReceiveOperation(identity: OperationIdentity(selector: v.identity.selector, requestKey: key), state: v.state, allocation: v.allocation, closeReason: v.closeReason, blocker: v.blocker))
    default: throw CapabilityFailure.invalidResponse
    }
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(response).call(call) }
}

@Test func capabilityResponsesRejectFractionalAmountsAndHardenedReceiveIndexes() async throws {
    let (balanceCall, balance) = try capabilityFixture(.getBalance)
    let encoded = String(decoding: try JSONEncoder().encode(CapabilityResponse(result: balance)), as: UTF8.self)
    let fractional = encoded.replacingOccurrences(of: "\"totalSatoshis\":1000", with: "\"totalSatoshis\":1.5")
    #expect(fractional != encoded)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(CapabilityResponse.self, from: Data(fractional.utf8)) }
    #expect(balanceCall.method == .getBalance)
    let (call, result) = try capabilityFixture(.createReceiveRequest)
    guard case .createReceiveRequest(let v) = result else { throw CapabilityFailure.invalidResponse }
    let allocation = try #require(v.allocation)
    let hardened = ReceiveOperation(identity: v.identity, state: .allocated, allocation: ReceiveAllocationProjection(address: allocation.address, index: 0x8000_0000))
    await #expect(throws: CapabilityFailure.invalidResponse) { try await client(.createReceiveRequest(hardened)).call(call) }
}
