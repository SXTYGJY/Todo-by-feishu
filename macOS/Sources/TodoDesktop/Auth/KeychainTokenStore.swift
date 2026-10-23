import Foundation
import Security

struct FeishuTokenSet: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var identity: FeishuIdentity
    var displayName: String?

    var isExpired: Bool { expiresAt <= Date() }
}

struct KeychainTokenStore {
    private let service = "com.todo-desktop.feishu.tokens"

    func load(for identityKey: String) throws -> FeishuTokenSet? {
        guard let data = try read(service: service, account: identityKey) else { return nil }
        return try JSONDecoder().decode(FeishuTokenSet.self, from: data)
    }

    func save(_ tokens: FeishuTokenSet) throws {
        let data = try JSONEncoder().encode(tokens)
        try write(data, service: service, account: tokens.identity.storageKey)
    }

    func delete(for identityKey: String) throws {
        try deleteItem(service: service, account: identityKey)
    }

    private func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError(status: status) }
        return result as? Data
    }

    private func write(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStoreError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainStoreError(status: status)
        }
    }

    private func deleteItem(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }
}

struct KeychainStoreError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        if status == errSecUserCanceled {
            return "macOS Keychain 访问被取消。请在系统弹出的钥匙串确认框中选择“允许”，然后重试。"
        }
        if status == errSecInteractionNotAllowed {
            return "macOS 当前不允许访问登录钥匙串。请先解锁登录钥匙串后重试（Keychain 状态 \(status)）。"
        }
        return "无法安全保存飞书凭证（Keychain 状态 \(status)）。"
    }
}
