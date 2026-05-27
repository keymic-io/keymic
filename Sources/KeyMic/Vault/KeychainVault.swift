import Foundation
import Security
import LocalAuthentication

struct KeychainVault: KeychainBackend {
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VaultConfig.keychainService,
            kSecAttrAccount as String: account
        ]
    }

    func write(account: String, secret: String) throws {
        let data = Data(secret.utf8)

        // Do NOT attach a SecAccessControl with .userPresence here.
        // Access control with biometric auth is enforced at read time via LAContext.
        // Adding .userPresence to SecItemAdd causes errSecAuthFailed on macOS when
        // there is no active authentication context, silently dropping the vault entry.
        var query = baseQuery(account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus != errSecSuccess { throw KeychainError.writeFailed(updateStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.writeFailed(status)
        }
    }

    /// Reads a secret from the keychain after biometric/passcode authentication.
    ///
    /// **Blocking**: This method uses a `DispatchSemaphore` to synchronously wait for
    /// the LAContext biometric prompt. Callers MUST invoke this from a context that
    /// can tolerate blocking (e.g. the main thread for user-initiated actions).
    /// Do NOT call from a GCD worker thread — the semaphore can exhaust the thread
    /// pool if multiple reads overlap.
    func read(account: String) throws -> String {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = VaultConfig.touchIDReuseDuration
        let reason = String(localized: "Reveal secret from KeyMic Vault")

        var evaluationSuccess = false
        var evaluationError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        // Evaluate policy explicitly to ensure TouchID or Passcode prompt is shown
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            evaluationSuccess = success
            evaluationError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .distantFuture)

        if !evaluationSuccess {
            if let err = evaluationError as? LAError {
                if err.code == .userCancel || err.code == .appCancel || err.code == .systemCancel {
                    throw KeychainError.userCancelled
                }
                throw KeychainError.readFailed(OSStatus(err.code.rawValue))
            }
            throw KeychainError.readFailed(errSecAuthFailed)
        }

        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
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
        case errSecInteractionNotAllowed:
            // Keychain is locked (device just rebooted, not yet unlocked).
            // Wrap with a distinct status so callers can show a "unlock your Mac" message.
            throw KeychainError.readFailed(errSecInteractionNotAllowed)
        default:
            throw KeychainError.readFailed(status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.writeFailed(status)
        }
    }
}
