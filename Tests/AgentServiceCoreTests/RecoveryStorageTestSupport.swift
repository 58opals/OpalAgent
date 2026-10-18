import AgentValues
import Darwin
import Foundation
@testable import AgentServiceCore

/// Observes actual owner-service calls to external collaborators. Recovery does not
/// install a payment executor, signer or relay; retained attempts/bytes are checked separately.
final class RecoveryStorageEffects: SeedAccountProvider, WrappingKeySource, AccountChainBoundary, @unchecked Sendable {
    struct Counts: Codable, Equatable, Sendable {
        var keyReads = 0
        var generation = 0
        var derivation = 0
        var refresh = 0
        var address = 0
        var authority = 0
        var forbiddenWrites = 0
    }
    private let lock = NSLock()
    private var value = Counts()
    var counts: Counts { lock.withLock { value } }
    func wrappingKey() throws -> WrappingKeyAvailability {
        lock.withLock { value.keyReads += 1 }; throw ContinuityError.invalidState
    }
    func generateMnemonic() throws -> Data {
        lock.withLock { value.generation += 1 }; throw ContinuityError.invalidState
    }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        lock.withLock { value.derivation += 1 }; throw ContinuityError.invalidState
    }
    func refresh(accountID: String, network: String) async throws -> AccountSyncRecord {
        lock.withLock { value.refresh += 1 }; throw ContinuityError.invalidState
    }
    func receivingAddress(at index: UInt32, accountID: String, network: String) async throws -> String {
        lock.withLock { value.address += 1 }; throw ContinuityError.invalidState
    }
    func integrationAuthority() throws -> ServiceAuthority {
        lock.withLock { value.authority += 1 }; throw ContinuityError.invalidState
    }
    func rejectWrite() throws {
        lock.withLock { value.forbiddenWrites += 1 }; throw ContinuityError.invalidState
    }
}

struct RecoveryStorageClock: PaymentClock {
    func read() -> PaymentClockReading { .init(wall: 1_000, monotonic: 100) }
}
private struct RecoveryStorageConsent: OwnerConsentProvider {
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        .init(challenge: challenge, authenticatedAt: 1_000)
    }
}
func recoveryStorageOwner(continuity: ContinuityCoordinator, effects: RecoveryStorageEffects)
    -> (OwnerControlService, OwnerConnectionContext) {
    let owner = SignedPeerIdentity(teamIdentifier: "synthetic-recovery", signingIdentifier: "owner")
    let policy = AuthorityPolicy(bridge: .init(teamIdentifier: "synthetic-recovery", signingIdentifier: "bridge"),
        owner: owner, accountIDs: ["account"], capabilities: ["read", "receive", "sync", "prepare", "submit", "cancel"],
        ownerAuthenticationAge: 30)
    let service = OwnerControlService(continuity: continuity, policy: policy,
        authority: { try effects.integrationAuthority() }, vault: WalletSeedVault(keys: effects, accounts: effects),
        accounts: effects, consent: RecoveryStorageConsent(), clock: RecoveryStorageClock())
    return (service, OwnerConnectionContext(connectionID: UUID().uuidString,
        peer: .init(identity: owner, signatureValidated: true)))
}

/// Optional metadata only. The runner supplies an existing private receipt directory;
/// assertions and the test runner's exit/XML remain authoritative for success.
func writeRecoveryStorageReceipt(name: String, contents: [String: Any]) throws {
    guard let path = ProcessInfo.processInfo.environment["OPAL_AGENT_RECOVERY_STORAGE_RECEIPT_DIRECTORY"] else { return }
    guard path.hasPrefix("/"), !name.isEmpty,
          name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
        throw ContinuityError.invalidState
    }
    let directory = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw ContinuityError.invalidState }
    defer { Darwin.close(directory) }
    var attributes = stat()
    guard fstat(directory, &attributes) == 0, attributes.st_uid == getuid() else { throw ContinuityError.invalidState }
    let fd = openat(directory, name + ".json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ContinuityError.invalidState }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys]))
    try handle.synchronize()
}
func recoveryStorageCountMetadata(_ counts: RecoveryStorageEffects.Counts?) throws -> Any {
    guard let counts else { return NSNull() }
    return try JSONSerialization.jsonObject(with: JSONEncoder().encode(counts))
}
