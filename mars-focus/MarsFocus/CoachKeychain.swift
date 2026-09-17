import Foundation
import Security

protocol CoachSecretStorage {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func remove(account: String) throws
}

struct CoachKeychain: CoachSecretStorage {
    private let service = "com.mars.trackonme.coach"

    private struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Couldn't access the API key in Keychain (\(status)). Unlock the device and try again."
        }
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw StorageError(status: status == errSecSuccess ? errSecDecode : status)
        }
        return value
    }

    func write(_ value: String, account: String) throws {
        let request = query(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        // Update in place: never delete an existing key before its replacement is safe.
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError(status: status) }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError(status: status)
        }
    }
}

/// Migrates legacy preferences only after the secure write succeeds. An existing
/// Keychain key wins over an old preference left behind by an interrupted migration.
struct CoachCredentials {
    let defaults: UserDefaults
    let secrets: any CoachSecretStorage

    private func account(_ provider: String) -> String { "coach-api-key-\(provider)" }

    func load(provider: String) throws -> String {
        let name = account(provider)
        if let existing = try secrets.read(account: name) {
            defaults.removeObject(forKey: name)
            return existing
        }
        guard let legacy = defaults.string(forKey: name) else { return "" }
        try save(legacy, provider: provider)
        return legacy
    }

    func save(_ value: String, provider: String) throws {
        let name = account(provider)
        if value.isEmpty {
            try secrets.remove(account: name)
        } else {
            try secrets.write(value, account: name)
        }
        defaults.removeObject(forKey: name)
    }
}
