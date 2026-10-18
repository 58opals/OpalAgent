import CryptoKit
import Foundation
import Testing
@testable import AgentServiceCore

private final class IntegrityAnchor: ContinuityAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuityAnchor?
    func read() throws -> ContinuityAnchor? { lock.withLock { value } }
    func write(_ anchor: ContinuityAnchor) throws { lock.withLock { value = anchor } }
}

private func integrityStore() async throws -> (DurableWalletStore, SQLiteJournal) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let policy = AuthorityPolicy(bridge: .init(teamIdentifier: "test", signingIdentifier: "bridge"),
        owner: .init(teamIdentifier: "test", signingIdentifier: "owner"), accountIDs: [], capabilities: ["read"],
        ownerAuthenticationAge: 30)
    let store = try DurableWalletStore(directory: directory, anchor: IntegrityAnchor(), policy: policy)
    let owner = OwnerAuthenticationEvidence(peer: .init(identity: policy.owner, signatureValidated: true),
        authenticationSucceeded: true, authenticatedAt: 100)
    let vault = WalletSeedVault(keys: InjectedWrappingKeySource {
        .available(SymmetricKey(data: Data(repeating: 7, count: 32)))
    }, accounts: BaseSeedAccountProvider())
    _ = try await store.ownerControl.createNew(vault: vault, network: "mainnet", owner: owner, now: 100)
    return (store, try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path))
}

@Test(arguments: ["custody", "policy", "snapshot", "generation"])
private func restoredMetadataCannotReuseAnOlderCompleteCommitment(_ field: String) async throws {
    let (store, journal) = try await integrityStore()
    var changed = try #require(try journal.read())
    switch field {
    case "custody": changed.custody?.publicDescriptor.append(1)
    case "policy": changed.paymentPolicy.approvalRequired.toggle()
    case "generation": changed.authorization.generation += 1
    default:
        let custody = try #require(changed.custody)
        changed.publicSnapshots = [.init(accountID: custody.accountID, network: custody.network,
            providerID: "provider", viewID: "view", chainTip: "tip", observedAt: 100, complete: true, fresh: true,
            balance: 100, snapshot: Data([1]), receivingHorizon: -1, changeHorizon: -1)]
    }
    // Simulate restored/tampered rows keeping the old commit identity, not a service command.
    try journal.write(changed)
    #expect(store.continuity.status() == .quarantined)
    #expect(throws: ContinuityError.recoveryRequired) { try store.continuity.inspect { $0.mode } }
}

@Test(arguments: ["origin", "format", "owner-generation"])
private func retainedRequestAuthorityAndNormalizationContextCannotBeRewritten(_ field: String) async throws {
    let (store, journal) = try await integrityStore()
    try store.continuity.transaction { state in
        state.requests.append(.init(id: "request", principalID: "integration", method: "receive_address",
            key: String(repeating: "a", count: 32), binding: Data([1]), disposition: .closed, result: Data([2]),
            consumedAttemptID: nil, tombstone: true, originGrantID: "original-grant"))
    }
    let before = try #require(try journal.read()).reference()
    #expect(throws: ContinuityError.invalidState) {
        try store.continuity.transaction { state in
            switch field {
            case "origin": state.requests[0].originGrantID = "replacement-grant"
            case "format": state.requests[0].formatVersion += 1
            default: state.requests[0].ownerGeneration = 99
            }
        }
    }
    #expect(try journal.read()?.reference() == before)
}
