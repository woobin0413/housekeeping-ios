import CryptoKit
import Foundation
import Security
import Supabase

/// No iCloud synchronization or device migration. Keys are scoped to this app and project.
struct KeychainSessionStorage: AuthLocalStorage {
    enum Failure: Error, Equatable {
        case unavailable(OSStatus)
        case invalidData
    }
    let service: String

    init(projectURL: URL, bundleID: String) {
        let digest = SHA256.hash(data: Data(projectURL.absoluteString.utf8))
        service = bundleID + ".auth." + digest.map { String(format: "%02x", $0) }.joined()
    }

    func store(key: String, value: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let entry = query(key).merging(attributes) { _, new in new }
            try check(SecItemAdd(entry as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func retrieve(key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw Failure.invalidData }
        return data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Failure.unavailable(status) }
    }
}
