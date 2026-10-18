import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

private final class StoreTestAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuityAnchor?
    func read() throws -> ContinuityAnchor? { lock.withLock { value } }
    func write(_ anchor: ContinuityAnchor) throws { lock.withLock { value = anchor } }
}
private func storePolicy() -> AuthorityPolicy {
    .init(bridge: .init(teamIdentifier: "test", signingIdentifier: "bridge"),
          owner: .init(teamIdentifier: "test", signingIdentifier: "owner"),
          accountIDs: [], capabilities: ["read", "prepare", "submit", "receive", "sync"], ownerAuthenticationAge: 30)
}
@Test func durableStoreWriterLeaseOutlivesTheCompositionWrapper() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let anchor = StoreTestAnchor()
    do {
        var store: DurableWalletStore? = try DurableWalletStore(directory: directory, anchor: anchor, policy: storePolicy())
        let coordinator = try #require(store?.continuity)
        store = nil
        _ = withExtendedLifetime(coordinator) {
            #expect(throws: StoreLockFailure.busy) {
                try DurableWalletStore(directory: directory, anchor: anchor, policy: storePolicy())
            }
        }
    }
    _ = try DurableWalletStore(directory: directory, anchor: anchor, policy: storePolicy())
}
@Test func newSQLiteWalletEnablesSeparatelyThenEnrollsOnlyItsDerivedAccount() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let policy = storePolicy()
    let store = try DurableWalletStore(directory: directory, anchor: StoreTestAnchor(), policy: policy)
    let owner = OwnerAuthenticationEvidence(peer: .init(identity: policy.owner, signatureValidated: true),
        authenticationSucceeded: true, authenticatedAt: 100)
    let keys = InjectedWrappingKeySource { .available(SymmetricKey(data: Data(repeating: 7, count: 32))) }
    let vault = WalletSeedVault(keys: keys, accounts: BaseSeedAccountProvider())
    let custody = try await store.ownerControl.createNew(vault: vault, network: "mainnet", owner: owner, now: 100)
    #expect(try store.continuity.inspect { $0.mode } == .restricted)
    _ = try store.ownerControl.enable(vault: vault, owner: owner, now: 100)
    let authority = try store.integrationAuthority()
    let issued = try authority.enroll(id: "derived", integrationID: "integration", accounts: [custody.accountID],
        capabilities: ["read"], expiry: nil, owner: owner, now: 100)
    #expect(issued.principal.integrationID == "integration")
    #expect(throws: AuthorizationFailure.scopeDenied) {
        try authority.enroll(id: "foreign", integrationID: "foreign", accounts: ["foreign-account"],
            capabilities: ["read"], expiry: nil, owner: owner, now: 100)
    }
    let boundary = StoreUnavailableBoundary()
    _ = try store.paymentEngine(boundary: boundary)
    #expect(throws: DurableWalletStoreError.self) { try store.paymentEngine(boundary: boundary) }
    _ = try store.receiveEngine(boundary: boundary)
    #expect(throws: DurableWalletStoreError.self) { try store.receiveEngine(boundary: boundary) }
}

private struct StoreUnavailableBoundary: PaymentExecutionBoundary, AccountChainBoundary {
    func prepare(_ request: PaymentPreparationInput) async throws -> PaymentPreview { throw PaymentFailure.unavailable }
    func sign(_ preview: PaymentPreview) async throws -> SignedPayment { throw PaymentFailure.unavailable }
    func preflight(_ payment: SignedPayment) async throws { throw PaymentFailure.unavailable }
    func handoff(_ payment: SignedPayment, admission: @escaping PaymentAdmission) async throws -> PaymentTransportInvocation {
        throw PaymentFailure.unavailable
    }
    func dispose(operationID: String) async throws {}
    func observe(_ payment: PaymentRecord) async throws -> PaymentObservation { throw PaymentFailure.unavailable }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord { throw PaymentFailure.unavailable }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String { throw PaymentFailure.unavailable }
}
