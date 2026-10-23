import Foundation
import Security

struct FeishuAppCredentials: Codable, Equatable {
    let appID: String
    let appSecret: String

    init(appID: String, appSecret: String) throws {
        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedAppID.range(of: #"^cli_[A-Za-z0-9]{8,64}$"#, options: .regularExpression) != nil else {
            throw OAuthError.invalidAppCredentials("App ID 格式应为 cli_ 开头的飞书应用 ID。")
        }
        guard !appSecret.isEmpty, appSecret == appSecret.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw OAuthError.invalidAppCredentials("App Secret 不能为空，也不能带首尾空格。")
        }
        self.appID = normalizedAppID
        self.appSecret = appSecret
    }
}

struct KeychainAppCredentialsStore {
    private let service = "com.todo-desktop.feishu.app-credentials"
    private let account = "active"

    func load() throws -> FeishuAppCredentials? {
        guard let data = try read() else { return nil }
        return try JSONDecoder().decode(FeishuAppCredentials.self, from: data)
    }

    func save(_ credentials: FeishuAppCredentials) throws {
        try write(JSONEncoder().encode(credentials))
    }

    private func read() throws -> Data? {
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

    private func write(_ data: Data) throws {
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
}
