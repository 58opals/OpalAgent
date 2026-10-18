import AgentClient
import AgentValues
import Foundation
import Testing

private struct OwnerDiscoveryFixedTransport: OwnerControlTransport {
    let response: OwnerControlResponse
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse { response }
}
private actor OwnerDiscoveryRecordingTransport: OwnerControlTransport {
    let result: OwnerControlResult
    private(set) var methods: [OwnerControlMethod] = []
    private(set) var wallets: [WalletScope] = []
    private(set) var pages: [PageRequest] = []
    private(set) var versions: [Int] = []
    init(_ result: OwnerControlResult) { self.result = result }
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        methods.append(request.call.method); versions.append(request.protocolVersion)
        switch request.call {
        case .listAccounts(let wallet): wallets.append(wallet)
        case .listPayments(let request): wallets.append(request.wallet); pages.append(request.page)
        default: throw CapabilityFailure.invalidRequest
        }
        return OwnerControlResponse(result: result)
    }
}
private struct OwnerDiscoveryFixture {
    let wallet: WalletScope
    let account: AccountScope
    let foreignWallet: WalletScope
    let foreignAccount: AccountScope
    let snapshotID = String(repeating: "ab", count: 32)
    init() throws {
        wallet = try WalletScope(walletID: "owner-wallet", network: .mainnet)
        account = try AccountScope(wallet: wallet, accountID: "account-0")
        foreignWallet = try WalletScope(walletID: wallet.walletID, network: .chipnet)
        foreignAccount = try AccountScope(wallet: foreignWallet, accountID: account.accountID)
    }
    func payment(operationID: String = "payment-0", account selected: AccountScope? = nil,
                 requestAccount: AccountScope? = nil, hasPreview: Bool = true) throws -> PaymentOperation {
        let selected = selected ?? account
        let key = try RequestKey(String(repeating: "1a", count: 16))
        let request = try PreparePaymentRequest(account: requestAccount ?? selected, requestKey: key,
            destinationAddress: "synthetic-public-destination", amountSatoshis: 1_000)
        let preview = PaymentPreviewProjection(canonicalDestinationAddress: request.destinationAddress,
            destinationScriptHex: "51", amountSatoshis: 1_000, feeSatoshis: 100,
            selectedInputs: [.init(transactionID: String(repeating: "bc", count: 32), outputIndex: 0)],
            change: [], templateDigest: String(repeating: "cd", count: 32), leaseDeadline: 2_000)
        return PaymentOperation(identity: .init(selector: try OperationSelector(account: selected, operationID: operationID), requestKey: key),
            request: request, state: .pendingApproval, preview: hasPreview ? preview : nil)
    }
    func page(items: [PaymentOperation], generation: UInt64 = 1, snapshot: String? = nil,
              wallet selected: WalletScope? = nil, cursor: String? = nil) -> OwnerPaymentPage {
        OwnerPaymentPage(wallet: selected ?? wallet, walletGeneration: generation, snapshotID: snapshot ?? snapshotID,
            page: .init(items: items, nextCursor: cursor))
    }
    func client(_ result: OwnerControlResult, version: Int = ServiceStatus.currentProtocolVersion) -> OwnerControlClient {
        OwnerControlClient(transport: OwnerDiscoveryFixedTransport(response: .init(protocolVersion: version, result: result)))
    }
}

@Test(arguments: [OwnerControlMethod.listAccounts, .listPayments])
func ownerDiscoveryClientForwardsBothReadsAndRoundTripsPublicDirectoryValues(_ method: OwnerControlMethod) async throws {
    let fixture = try OwnerDiscoveryFixture()
    let call: OwnerControlCall
    let result: OwnerControlResult
    switch method {
    case .listAccounts:
        let directory = OwnerAccountDirectory(wallet: fixture.wallet, walletGeneration: UInt64.max, accounts: [fixture.account])
        #expect(try JSONDecoder().decode(OwnerAccountDirectory.self, from: JSONEncoder().encode(directory)) == directory)
        call = .listAccounts(fixture.wallet); result = .listAccounts(directory)
    case .listPayments:
        let page = fixture.page(items: [try fixture.payment()], generation: UInt64.max)
        #expect(try JSONDecoder().decode(OwnerPaymentPage.self, from: JSONEncoder().encode(page)) == page)
        call = .listPayments(.init(wallet: fixture.wallet, page: try PageRequest(limit: 1, cursor: "opaque-request-cursor")))
        result = .listPayments(page)
    default: throw CapabilityFailure.invalidRequest
    }
    let transport = OwnerDiscoveryRecordingTransport(result)
    #expect(try await OwnerControlClient(transport: transport).call(call).method == method)
    #expect(await transport.methods == [method])
    #expect(await transport.wallets == [fixture.wallet])
    #expect(await transport.versions == [ServiceStatus.currentProtocolVersion])
    if method == .listPayments {
        let expected = try PageRequest(limit: 1, cursor: "opaque-request-cursor")
        #expect(await transport.pages == [expected])
    }
}

enum OwnerAccountDirectoryDefect: Sendable, CaseIterable {
    case wrongWallet, zeroGeneration, duplicateAccount, foreignAccount, oversized
}
@Test(arguments: OwnerAccountDirectoryDefect.allCases)
func ownerAccountDirectoryClientRejectsMalformedAndForeignCollections(_ defect: OwnerAccountDirectoryDefect) async throws {
    let fixture = try OwnerDiscoveryFixture()
    var wallet = fixture.wallet
    var generation: UInt64 = 1
    var accounts = [fixture.account]
    switch defect {
    case .wrongWallet: wallet = fixture.foreignWallet; accounts = [fixture.foreignAccount]
    case .zeroGeneration: generation = 0
    case .duplicateAccount: accounts.append(fixture.account)
    case .foreignAccount: accounts = [fixture.foreignAccount]
    case .oversized:
        accounts = try (0...PageRequest.maximumCount).map { try AccountScope(wallet: wallet, accountID: "account-\($0)") }
    }
    let directory = OwnerAccountDirectory(wallet: wallet, walletGeneration: generation, accounts: accounts)
    await #expect(throws: CapabilityFailure.invalidResponse) {
        try await fixture.client(.listAccounts(directory)).call(.listAccounts(fixture.wallet))
    }
}

enum OwnerPaymentDirectoryDefect: Sendable, CaseIterable {
    case wrongWallet, zeroGeneration, malformedSnapshot, uppercaseSnapshot, duplicateID
    case foreignAccount, mismatchedRequestAccount, missingPreview
}
@Test(arguments: OwnerPaymentDirectoryDefect.allCases)
func ownerPaymentDirectoryClientRejectsMalformedContextAndPaymentBindings(_ defect: OwnerPaymentDirectoryDefect) async throws {
    let fixture = try OwnerDiscoveryFixture()
    var wallet = fixture.wallet
    var generation: UInt64 = 1
    var snapshot = fixture.snapshotID
    var items = [try fixture.payment()]
    switch defect {
    case .wrongWallet: wallet = fixture.foreignWallet; items = [try fixture.payment(account: fixture.foreignAccount)]
    case .zeroGeneration: generation = 0
    case .malformedSnapshot: snapshot = String(repeating: "a", count: 63)
    case .uppercaseSnapshot: snapshot = fixture.snapshotID.uppercased()
    case .duplicateID: items.append(try fixture.payment())
    case .foreignAccount: items = [try fixture.payment(account: fixture.foreignAccount)]
    case .mismatchedRequestAccount: items = [try fixture.payment(requestAccount: fixture.foreignAccount)]
    case .missingPreview: items = [try fixture.payment(hasPreview: false)]
    }
    let page = fixture.page(items: items, generation: generation, snapshot: snapshot, wallet: wallet)
    let request = WalletPageRequest(wallet: fixture.wallet, page: try PageRequest())
    await #expect(throws: CapabilityFailure.invalidResponse) {
        try await fixture.client(.listPayments(page)).call(.listPayments(request))
    }
}

enum OwnerPaymentPageDefect: Sendable, CaseIterable {
    case overRequestLimit, overMaximumLimit, emptyCursor, whitespaceCursor, oversizedCursor
}
@Test(arguments: OwnerPaymentPageDefect.allCases)
func ownerPaymentDirectoryClientBoundsPagesAndOpaqueCursors(_ defect: OwnerPaymentPageDefect) async throws {
    let fixture = try OwnerDiscoveryFixture()
    var limit = PageRequest.maximumCount
    var count = 1
    var cursor: String? = nil
    switch defect {
    case .overRequestLimit: limit = 1; count = 2
    case .overMaximumLimit: count = PageRequest.maximumCount + 1
    case .emptyCursor: cursor = ""
    case .whitespaceCursor: cursor = "unsafe cursor"
    case .oversizedCursor: cursor = String(repeating: "a", count: 2_049)
    }
    let items = try (0..<count).map { try fixture.payment(operationID: "payment-\($0)") }
    let page = fixture.page(items: items, cursor: cursor)
    let request = WalletPageRequest(wallet: fixture.wallet, page: try PageRequest(limit: limit))
    await #expect(throws: CapabilityFailure.invalidResponse) {
        try await fixture.client(.listPayments(page)).call(.listPayments(request))
    }
}

@Test func ownerPaymentDirectoryClientAcceptsFortyBoundItemsAndOpaquePagination() async throws {
    let fixture = try OwnerDiscoveryFixture()
    let cursor = String(repeating: "z", count: 2_048)
    let items = try (0..<PageRequest.maximumCount).map { try fixture.payment(operationID: "payment-\($0)") }
    let page = fixture.page(items: items, cursor: cursor)
    let request = WalletPageRequest(wallet: fixture.wallet, page: try PageRequest())
    guard case .listPayments(let response) = try await fixture.client(.listPayments(page)).call(.listPayments(request)) else {
        throw CapabilityFailure.invalidResponse
    }
    #expect(response == page && response.page.items.count == 40 && response.page.nextCursor == cursor)
    #expect(response.walletGeneration == 1 && response.snapshotID == fixture.snapshotID)
}

@Test(arguments: [OwnerControlMethod.listAccounts, .listPayments])
func ownerDiscoveryClientKeepsUnavailableProtocolAndKindChecks(_ method: OwnerControlMethod) async throws {
    let fixture = try OwnerDiscoveryFixture()
    let directory = OwnerAccountDirectory(wallet: fixture.wallet, walletGeneration: 1, accounts: [fixture.account])
    let page = fixture.page(items: [])
    let request = WalletPageRequest(wallet: fixture.wallet, page: try PageRequest())
    let call: OwnerControlCall = method == .listAccounts ? .listAccounts(fixture.wallet) : .listPayments(request)
    let result: OwnerControlResult = method == .listAccounts ? .listAccounts(directory) : .listPayments(page)
    let wrongKind: OwnerControlResult = method == .listAccounts ? .listPayments(page) : .listAccounts(directory)
    await #expect(throws: ClientFailure.unavailable) { try await OwnerControlClient().call(call) }
    await #expect(throws: ClientFailure.incompatibleProtocol) {
        try await fixture.client(result, version: ServiceStatus.currentProtocolVersion + 1).call(call)
    }
    await #expect(throws: CapabilityFailure.invalidResponse) { try await fixture.client(wrongKind).call(call) }
}
