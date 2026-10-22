#if DEBUG
import AgentClient
import AgentNativeIPC
import AgentValues
import Foundation
import Darwin
import LocalAuthentication
import Security
@testable import AgentServiceCore

/// Published, permanently disposable BIP39 vector, supplied through the actual owner creation contract.
struct FixtureSeedAccountProvider: SeedAccountProvider {
    static let mnemonic = Data("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8)
    func generateMnemonic() throws -> Data { Self.mnemonic }
    func deriveAccount(mnemonic: Data, network: String) async throws -> DerivedSeedAccount {
        try await BaseSeedAccountProvider().deriveAccount(mnemonic: mnemonic, network: network)
    }
}

/// This file models only synthetic generic-password items. No Security I/O is performed.
/// Attribute validation mirrors the real adapter's noninteractive, device-only requests.
final class FixtureKeychainOperations: KeychainItemOperations, @unchecked Sendable {
    private struct Item: Codable {
        let service: String
        let account: String
        let group: String
        var data: Data
    }
    private struct Envelope: Codable { let version: Int; let group: String; let items: [Item] }
    private let lock = NSLock()
    private let path: URL
    private let group: String
    private var items: [Item]
    private var present = true
    private var keyReads = 0
    init(path: URL, group: String, resume: Bool) throws {
        self.path = path; self.group = group
        if resume {
            let data = try FixtureProcessOwnership.readOwned(path, maximum: 2_097_152)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.group == group,
                  envelope.items.count == 2,
                  envelope.items.allSatisfy({ $0.group == group && Self.services.contains($0.service) && !$0.account.isEmpty }),
                  Set(envelope.items.map(\.service)) == Self.services else { throw FixtureFailure.invalidArguments }
            items = envelope.items
        } else {
            items = []
            try FixtureProcessOwnership.writeNew(JSONEncoder().encode(Envelope(version: 1, group: group, items: [])), to: path)
        }
    }
    private static let services: Set<String> = ["com.58opals.OpalAgent.wrapkey", "com.58opals.OpalAgent.continuityanchor"]
    var reads: Int { lock.withLock { keyReads } }
    var isPresent: Bool { lock.withLock { present } }
    func setPresent(_ value: Bool) { lock.withLock { present = value } }
    private func query(_ raw: CFDictionary, reading: Bool, protected: Bool) -> (String, String)? {
        let value = raw as NSDictionary
        let expected: Set<String> = Set([kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup,
            kSecAttrSynchronizable, kSecUseDataProtectionKeychain, kSecUseAuthenticationContext].map { $0 as String })
            .union(reading ? [kSecReturnAttributes as String, kSecReturnData as String, kSecMatchLimit as String] : [])
            .union(protected ? [kSecAttrAccessible as String] : [])
        guard Set(value.allKeys.compactMap { $0 as? String }) == expected,
              value[kSecClass] as? String == kSecClassGenericPassword as String,
              let service = value[kSecAttrService] as? String, Self.services.contains(service),
              let account = value[kSecAttrAccount] as? String, account.hasPrefix("v1:"),
              value[kSecAttrAccessGroup] as? String == group,
              value[kSecAttrSynchronizable] as? NSNumber == 0,
              value[kSecUseDataProtectionKeychain] as? NSNumber == 1,
              let context = value[kSecUseAuthenticationContext] as? LAContext, context.interactionNotAllowed,
              !protected || value[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
              !reading || (value[kSecReturnAttributes] as? NSNumber == 1 && value[kSecReturnData] as? NSNumber == 1 && value[kSecMatchLimit] as? String == kSecMatchLimitOne as String)
        else { return nil }
        return (service, account)
    }
    func copyMatching(_ raw: CFDictionary) -> (status: OSStatus, result: CFTypeRef?) {
        lock.withLock {
            guard let (service, account) = query(raw, reading: true, protected: false) else { return (errSecParam, nil) }
            if service == "com.58opals.OpalAgent.wrapkey" { keyReads += 1; if !present { return (errSecItemNotFound, nil) } }
            guard let item = items.first(where: { $0.service == service && $0.account == account }) else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, [kSecAttrService as String: item.service, kSecAttrAccount as String: item.account,
                kSecAttrAccessGroup as String: item.group, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: false, kSecValueData as String: item.data] as CFDictionary)
        }
    }
    func add(_ raw: CFDictionary) -> OSStatus {
        lock.withLock {
            var attributes = raw as NSDictionary as! [String: Any]
            guard let data = attributes.removeValue(forKey: kSecValueData as String) as? Data,
                  let (service, account) = query(attributes as CFDictionary, reading: false, protected: true),
                  service != "com.58opals.OpalAgent.wrapkey" || data.count == 32 else { return errSecParam }
            guard !items.contains(where: { $0.service == service && $0.account == account }) else { return errSecDuplicateItem }
            var candidate = items
            candidate.append(Item(service: service, account: account, group: group, data: data))
            return persist(candidate)
        }
    }
    func update(_ raw: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            let attributes = attributes as NSDictionary
            guard attributes.count == 1, let data = attributes[kSecValueData] as? Data,
                  let (service, account) = query(raw, reading: false, protected: true),
                  service == "com.58opals.OpalAgent.continuityanchor" else { return errSecParam }
            guard let index = items.firstIndex(where: { $0.service == service && $0.account == account }) else { return errSecItemNotFound }
            var candidate = items
            candidate[index].data = data
            return persist(candidate)
        }
    }
    private func persist(_ candidate: [Item]) -> OSStatus {
        do {
            let temporary = path.deletingLastPathComponent().appendingPathComponent(".synthetic-items-" + UUID().uuidString)
            let data = try JSONEncoder().encode(Envelope(version: 1, group: group, items: candidate))
            try FixtureProcessOwnership.writeNew(data, to: temporary)
            guard Darwin.rename(temporary.path, path.path) == 0 else { throw FixtureFailure.fixtureUnavailable }
            // Failed writes retain their on-disk evidence; reads must never acknowledge
            // a candidate that only existed in this process's staging memory.
            items = candidate
            return errSecSuccess
        } catch { return errSecIO }
    }
}

final class FixtureInspection: @unchecked Sendable {
    private let lock = NSLock()
    private weak var continuity: ContinuityCoordinator?
    private var stopped = false
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func bind(_ value: ContinuityCoordinator) { lock.withLock { continuity = value } }
    func didStop() { lock.withLock { continuity = nil; stopped = true } }
    func inspect<T>(_ body: (CanonicalState) throws -> T) throws -> T {
        try lock.withLock {
            if let continuity { return try continuity.inspect(body) }
            guard stopped, let state = try SQLiteJournal(path: directory.appendingPathComponent("journal.sqlite").path, createIfMissing: false).read() else { throw FixtureFailure.fixtureUnavailable }
            return try body(state)
        }
    }
}

final class FixtureEndpointRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [NativeChannel: ServiceEndpointHandlers] = [:]
    func host(_ channel: NativeChannel, handlers: ServiceEndpointHandlers) -> any ServiceEndpointHost {
        FixtureEndpointHost(registry: self, channel: channel, handlers: handlers)
    }
    func activate(_ channel: NativeChannel, handlers: ServiceEndpointHandlers) throws {
        try lock.withLock { guard self.handlers[channel] == nil else { throw FixtureFailure.fixtureUnavailable }; self.handlers[channel] = handlers }
    }
    func invalidate(_ channel: NativeChannel) { lock.withLock { _ = handlers.removeValue(forKey: channel) } }
    func endpoint(_ channel: NativeChannel) throws -> ServiceEndpointHandlers {
        try lock.withLock { guard let value = handlers[channel] else { throw FixtureFailure.fixtureUnavailable }; return value }
    }
}
private struct FixtureEndpointHost: ServiceEndpointHost {
    let registry: FixtureEndpointRegistry
    let channel: NativeChannel
    let handlers: ServiceEndpointHandlers
    func activate() throws { try registry.activate(channel, handlers: handlers) }
    func invalidate() { registry.invalidate(channel) }
}

private struct FixtureCapabilityTransport: CapabilityTransport {
    let handlers: ServiceEndpointHandlers
    let connection: ServiceConnection
    let chain: FixturePublicChain
    let trace: FixtureTrace?
    func send(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        do {
            let result = try await handlers.capability(request, connection: connection)
            try trace?.emit(event: "capability-call", method: request.call.method, status: "succeeded", relayCount: chain.counts.relays)
            return result
        } catch {
            try trace?.emit(event: "capability-call", method: request.call.method, status: "rejected", relayCount: chain.counts.relays)
            throw error
        }
    }
}
final class FixtureClientSession: Sendable {
    let client: CapabilityClient
    let connection: ServiceConnection
    private let handlers: ServiceEndpointHandlers
    init(handlers: ServiceEndpointHandlers, connection: ServiceConnection, chain: FixturePublicChain, trace: FixtureTrace?) {
        self.handlers = handlers; self.connection = connection
        client = CapabilityClient(transport: FixtureCapabilityTransport(handlers: handlers, connection: connection, chain: chain, trace: trace))
    }
    func close() async { connection.invalidate(); await handlers.disconnect(connection) }
}
struct FixtureConsent: OwnerConsentProvider {
    let clock: FixtureClock
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof {
        .init(challenge: challenge, authenticatedAt: clock.read().wall)
    }
}
struct FixtureOwnerSession: OwnerControlTransport {
    let handlers: ServiceEndpointHandlers
    let connection: ServiceConnection
    let consent: any OwnerConsentProvider
    func send(_ request: OwnerControlRequest) async throws -> OwnerControlResponse {
        try await handlers.owner(request, connection: connection, consent: consent)
    }
    func close() async { connection.invalidate(); await handlers.disconnect(connection) }
    func packet(_ input: NativeOwnerPacket, requestID: UUID, method: OwnerControlMethod) async throws -> OwnerControlResponse {
        let (_, request) = try NativeWire.decodeOwnerRequest(input)
        let response = try await send(request)
        return try NativeWire.decodeOwnerResponse(NativeWire.ownerResponse(response, requestID: requestID), requestID: requestID, method: method)
    }
}
#endif
