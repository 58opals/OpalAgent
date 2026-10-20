import Foundation
import Security
@testable import AgentServiceCore

/// An isolated model of exact generic-password items. It never calls Security.
final class KeychainTestOperations: KeychainItemOperations, @unchecked Sendable {
    enum Call {
        case copyMatching([String: Any])
        case add([String: Any])
        case update(query: [String: Any], attributes: [String: Any])
    }

    private struct CopyOverride {
        let status: OSStatus
        let result: CFTypeRef?
    }
    private struct WriteOverride {
        let status: OSStatus
        let persist: Bool
    }

    private let lock = NSLock()
    private var items: [[String: Any]]
    private var recorded: [Call] = []
    private var copies = 0
    private var additions = 0
    private var updates = 0
    private var copyOverrides: [Int: CopyOverride] = [:]
    private var addOverrides: [Int: WriteOverride] = [:]
    private var updateOverrides: [Int: WriteOverride] = [:]

    init(items: [[String: Any]] = []) { self.items = items }

    var calls: [Call] { lock.withLock { recorded } }
    var storedItems: [[String: Any]] { lock.withLock { items } }
    var copyCount: Int { lock.withLock { copies } }
    var addCount: Int { lock.withLock { additions } }
    var updateCount: Int { lock.withLock { updates } }

    func insert(_ item: [String: Any]) { lock.withLock { items.append(item) } }

    func overrideCopy(call: Int, status: OSStatus, result: CFTypeRef? = nil) {
        lock.withLock { copyOverrides[call] = CopyOverride(status: status, result: result) }
    }

    func overrideAdd(call: Int, status: OSStatus, persist: Bool) {
        lock.withLock { addOverrides[call] = WriteOverride(status: status, persist: persist) }
    }

    func overrideUpdate(call: Int, status: OSStatus, persist: Bool) {
        lock.withLock { updateOverrides[call] = WriteOverride(status: status, persist: persist) }
    }

    func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?) {
        lock.withLock {
            let query = query as NSDictionary as! [String: Any]
            copies += 1
            recorded.append(.copyMatching(query))
            if let override = copyOverrides[copies] { return (override.status, override.result) }
            guard let item = items.first(where: { matches($0, query: query) }) else {
                return (errSecItemNotFound, nil)
            }
            if query[kSecReturnAttributes as String] as? Bool == true {
                var result = item
                if query[kSecReturnData as String] as? Bool != true {
                    result.removeValue(forKey: kSecValueData as String)
                }
                return (errSecSuccess, result as NSDictionary)
            }
            if query[kSecReturnData as String] as? Bool == true {
                return (errSecSuccess, item[kSecValueData as String] as CFTypeRef?)
            }
            return (errSecSuccess, nil)
        }
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            let attributes = attributes as NSDictionary as! [String: Any]
            additions += 1
            recorded.append(.add(attributes))
            let override = addOverrides[additions]
            if override?.persist == false { return override!.status }
            let status: OSStatus
            if items.contains(where: { matches($0, query: attributes, includeProtection: false) }) {
                status = errSecDuplicateItem
            } else {
                items.append(attributes)
                status = errSecSuccess
            }
            return override?.status ?? status
        }
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            let query = query as NSDictionary as! [String: Any]
            let attributes = attributes as NSDictionary as! [String: Any]
            updates += 1
            recorded.append(.update(query: query, attributes: attributes))
            let override = updateOverrides[updates]
            if override?.persist == false { return override!.status }
            guard let index = items.firstIndex(where: { matches($0, query: query) }) else {
                return override?.status ?? errSecItemNotFound
            }
            items[index].merge(attributes) { _, replacement in replacement }
            return override?.status ?? errSecSuccess
        }
    }

    private func matches(_ item: [String: Any], query: [String: Any], includeProtection: Bool = true) -> Bool {
        let keys = [kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup, kSecAttrSynchronizable]
            + (includeProtection ? [kSecAttrAccessible] : [])
        return keys.allSatisfy { key in
            guard let expected = query[key as String] else { return true }
            guard let actual = item[key as String] else { return false }
            return (actual as? NSObject)?.isEqual(expected) == true
        }
    }
}

func keychainTestItem(service: String = "com.58opals.OpalAgent.wrapkey", account: String = "v1:6:wallet",
                      accessGroup: String = "test.OpalAgent.Service", data: Data = Data(repeating: 7, count: 32)) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account,
     kSecAttrAccessGroup as String: accessGroup,
     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
     kSecAttrSynchronizable as String: false,
     kSecValueData as String: data]
}
