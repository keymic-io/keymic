import Foundation
import Security

public enum MCPTokenStoreConfig {
    public static let keychainService = "io.keymic.app.mcp"
}

public struct MCPTokenStore: Sendable {
    public init() {}

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPTokenStoreConfig.keychainService,
            kSecAttrAccount as String: account
        ]
    }

    public func write(account: String, token: String) throws {
        let data = Data(token.utf8)
        var query = baseQuery(account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                [
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    kSecValueData as String: data
                ] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.writeFailed(updateStatus)
            }
            return
        }

        throw KeychainError.writeFailed(status)
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodeFailed
        }
        return token
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.writeFailed(status)
        }
    }
}
