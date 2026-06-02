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
    /// **Non-blocking**: the LAContext prompt is awaited via a continuation, so the
    /// calling thread is never parked. This matters because the only caller runs on
    /// the main thread, whose run loop also drives the `CGEvent` tap — a synchronous
    /// wait here would freeze every global hotkey until the user answered the prompt.
    func read(account: String) async throws -> String {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = VaultConfig.touchIDReuseDuration
        let reason = String(localized: "Reveal secret from KeyMic Vault")

        // Map the (Bool, Error?) completion to a Sendable outcome inside the closure so
        // no non-Sendable `Error` crosses the continuation boundary.
        enum AuthOutcome { case success, cancelled, failed(OSStatus) }
        let outcome: AuthOutcome = await withCheckedContinuation { cont in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    cont.resume(returning: .success)
                } else if let err = error as? LAError,
                          err.code == .userCancel || err.code == .appCancel || err.code == .systemCancel {
                    cont.resume(returning: .cancelled)
                } else if let err = error as? LAError {
                    cont.resume(returning: .failed(OSStatus(err.code.rawValue)))
                } else {
                    cont.resume(returning: .failed(errSecAuthFailed))
                }
            }
        }

        switch outcome {
        case .success: break
        case .cancelled: throw KeychainError.userCancelled
        case .failed(let status): throw KeychainError.readFailed(status)
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
