import Foundation
import Security

nonisolated protocol RouterCredentialStore: Sendable {
    func password(for account: String) async throws -> String?
    func save(_ password: String, for account: String) async throws
    func remove(account: String) async throws
}

struct KeychainStore: RouterCredentialStore {
    private let service = "app.iwifyou.router-login"

    // Keychain can prompt or block; keep it off the UI actor.
    @concurrent func password(for account: String) async throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return password
    }

    @concurrent func save(_ password: String, for account: String) async throws {
        let query = baseQuery(account)
        let update = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrLabel as String] = "iwifyou · login router"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    @concurrent func remove(account: String) async throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    nonisolated private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

private struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain tidak dapat diakses (\(status)). Kamu tetap bisa masuk tanpa menyimpan password." }
}
