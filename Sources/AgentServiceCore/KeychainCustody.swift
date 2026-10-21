import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The adapters construct native requests; only explicitly selected operations perform I/O.
protocol KeychainItemOperations: Sendable {
    func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?)
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
}

struct NativeKeychainItemOperations: KeychainItemOperations {
    func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        return (status, result)
    }

    func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }
}

enum KeychainCustodyError: Error, Equatable {
    case invalidConfiguration
    case invalidResult
    case operationFailed(OSStatus)
}

/// Reads an already provisioned key. A no-match result never creates or replaces one.
struct KeychainWrappingKeySource: WrappingKeySource {
    private let item: KeychainCustodyItem
    private let operations: any KeychainItemOperations

    init(accessGroup: String, walletID: String, operations: any KeychainItemOperations) throws {
        item = try KeychainCustodyItem(service: "com.58opals.OpalAgent.wrapkey",
            accessGroup: accessGroup, components: [walletID])
        self.operations = operations
    }

    func wrappingKey() throws -> WrappingKeyAvailability {
        let result = operations.copyMatching(item.readQuery())
        switch result.status {
        case errSecSuccess:
            let data = try item.data(from: result.result)
            guard data.count == 32 else { throw KeychainCustodyError.invalidResult }
            return .available(SymmetricKey(data: data))
        case errSecItemNotFound:
            // This also covers a query outside the caller's access-group membership.
            return .missing
        case let status where keychainIsUnavailable(status):
            return .inaccessible
        default:
            throw KeychainCustodyError.operationFailed(result.status)
        }
    }
}

/// Add-only capability selected exclusively by the explicit owner new-wallet flow.
struct KeychainWrappingKeyProvisioner: Sendable {
    private let item: KeychainCustodyItem
    private let reader: KeychainWrappingKeySource
    private let operations: any KeychainItemOperations
    private let generateKey: @Sendable () throws -> SymmetricKey

    init(accessGroup: String, walletID: String, operations: any KeychainItemOperations,
         generateKey: @escaping @Sendable () throws -> SymmetricKey = { SymmetricKey(size: .bits256) }) throws {
        item = try KeychainCustodyItem(service: "com.58opals.OpalAgent.wrapkey",
            accessGroup: accessGroup, components: [walletID])
        reader = try KeychainWrappingKeySource(accessGroup: accessGroup, walletID: walletID, operations: operations)
        self.operations = operations
        self.generateKey = generateKey
    }

    func requireAbsent() throws {
        switch try reader.wrappingKey() {
        case .missing: return
        case .inaccessible: throw ContinuityError.keyUnavailable
        case .available: throw ContinuityError.invalidState
        }
    }

    func provision() throws -> SymmetricKey {
        try requireAbsent()
        let candidate = try generateKey()
        guard candidate.bitCount == 256 else { throw KeychainCustodyError.invalidResult }
        var attributes = item.query()
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = candidate.withUnsafeBytes { Data($0) }
        // Even an error after persistence is unacknowledged. Never adopt a duplicate,
        // update, delete, retry, or infer rollback from an unsuccessful add.
        let status = operations.add(attributes as CFDictionary)
        guard status == errSecSuccess else { throw KeychainCustodyError.operationFailed(status) }
        guard case .available(let stored) = try reader.wrappingKey(), stored == candidate else {
            throw KeychainCustodyError.invalidResult
        }
        return stored
    }
}

/// Persists one complete independent anchor. The coordinator owns all write read-back.
final class KeychainContinuityAnchorStore: ContinuityAnchorStore {
    private let item: KeychainCustodyItem
    private let installationID: String
    private let walletID: String
    private let operations: any KeychainItemOperations

    init(accessGroup: String, installationID: String, walletID: String,
         operations: any KeychainItemOperations) throws {
        item = try KeychainCustodyItem(service: "com.58opals.OpalAgent.continuityanchor",
            accessGroup: accessGroup, components: [installationID, walletID])
        self.installationID = installationID
        self.walletID = walletID
        self.operations = operations
    }

    func read() throws -> ContinuityAnchor? {
        let result = operations.copyMatching(item.readQuery())
        switch result.status {
        case errSecSuccess:
            let anchor: ContinuityAnchor
            do { anchor = try JSONDecoder().decode(ContinuityAnchor.self, from: item.data(from: result.result)) }
            catch { throw KeychainCustodyError.invalidResult }
            try validate(anchor)
            return anchor
        case errSecItemNotFound:
            return nil
        default:
            try requireSuccess(result.status)
            throw KeychainCustodyError.invalidResult
        }
    }

    func write(_ anchor: ContinuityAnchor) throws {
        try validate(anchor)
        // Preserve existing evidence if its metadata or contents cannot be validated.
        // This preflight is not the coordinator's post-write verification barrier.
        _ = try read()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(anchor)
        var query = item.query()
        // Match accessibility rather than rewriting an existing item's protection.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = operations.update(query as CFDictionary, attributes: [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = item.query()
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecValueData as String] = data
            // A racing/foreign existing item is an error, never delete-and-replace or retry.
            try requireSuccess(operations.add(attributes as CFDictionary))
        } else {
            try requireSuccess(status)
        }
    }

    private func validate(_ anchor: ContinuityAnchor) throws {
        try anchor.validate()
        var references = [anchor.committed, anchor.pending?.parent, anchor.pending?.target].compactMap { $0 }
        references += anchor.originalProofs.flatMap { [$0.reference, $0.parent].compactMap { $0 } }
        if let recovery = anchor.recovery {
            references += [recovery.observedCommitted, recovery.observedDatabase,
                           recovery.observedPending?.parent, recovery.observedPending?.target].compactMap { $0 }
        }
        guard references.allSatisfy({ $0.installationID == installationID && $0.walletID == walletID }) else {
            throw KeychainCustodyError.invalidResult
        }
    }

    private func requireSuccess(_ status: OSStatus) throws {
        if keychainIsUnavailable(status) { throw ContinuityStoreError.unavailable }
        guard status == errSecSuccess else { throw KeychainCustodyError.operationFailed(status) }
    }
}

private struct KeychainCustodyItem: Sendable {
    let service: String
    let accessGroup: String
    let account: String

    init(service: String, accessGroup: String, components: [String]) throws {
        guard ([accessGroup] + components).allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
            throw KeychainCustodyError.invalidConfiguration
        }
        self.service = service
        self.accessGroup = accessGroup
        // Length prefixes preserve identity even when components contain delimiters or Unicode.
        account = "v1:" + components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    func query() -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: context]
    }

    func readQuery() -> CFDictionary {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query as CFDictionary
    }

    func data(from result: CFTypeRef?) throws -> Data {
        guard let attributes = result as? [String: Any],
              attributes[kSecAttrService as String] as? String == service,
              attributes[kSecAttrAccount as String] as? String == account,
              attributes[kSecAttrAccessGroup as String] as? String == accessGroup,
              attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
              let synchronized = attributes[kSecAttrSynchronizable as String] as? NSNumber, synchronized == 0,
              let data = attributes[kSecValueData as String] as? Data else {
            throw KeychainCustodyError.invalidResult
        }
        // Data Protection can return an ACL even for an accessibility-only item.
        // Its opaque contents are not a public policy-inspection API. Every operation
        // uses a fresh noninteractive context; actual access failures remain unavailable.
        if let accessControl = attributes[kSecAttrAccessControl as String],
           CFGetTypeID(accessControl as CFTypeRef) != SecAccessControlGetTypeID() {
            throw KeychainCustodyError.invalidResult
        }
        return data
    }
}

private func keychainIsUnavailable(_ status: OSStatus) -> Bool {
    [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed,
     errSecNotAvailable].contains(status)
}
