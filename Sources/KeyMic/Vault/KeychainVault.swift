import Foundation
import Security
import LocalAuthentication

struct KeychainVault: KeychainBackend {
    func write(account: String, secret: String) throws {
        let data = Data(secret.utf8)

        // Do NOT attach a SecAccessControl with .userPresence here.
        // Access control with biometric auth is enforced at read time via LAContext.
        // Adding .userPresence to SecItemAdd causes errSecAuthFailed on macOS when
        // there is no active authentication context, silently dropping the vault entry.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VaultConfig.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttrs: [String: Any] = [kSecValueData as String: data]
            let baseQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: VaultConfig.keychainService,
                kSecAttrAccount as String: account
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus != errSecSuccess { throw KeychainError.writeFailed(updateStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.writeFailed(status)
        }
    }

    func read(account: String) throws -> String {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = VaultConfig.touchIDReuseDuration
        context.localizedReason = "Reveal secret from KeyMic Vault"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VaultConfig.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodeFailed
            }
            return s
        case errSecUserCanceled:
            throw KeychainError.userCancelled
        case errSecItemNotFound:
            throw KeychainError.missing
        default:
            throw KeychainError.readFailed(status)
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VaultConfig.keychainService,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.writeFailed(status)
        }
    }
}
