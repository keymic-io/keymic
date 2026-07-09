import Foundation

protocol KeychainBackend {
    /// Writes a secret. When `biometricProtected` is true the item is bound to a
    /// `.userPresence` access control (Touch ID first, device passcode fallback),
    /// so reads require authentication instead of a `login` keychain password
    /// prompt that breaks whenever the app is re-signed with a new cdhash.
    func write(account: String, secret: String, biometricProtected: Bool) throws
    /// Reads a secret. `async` because the concrete backend may show a biometric
    /// prompt — awaiting it must never block the caller's thread (the event tap
    /// lives on the main run loop and would be starved by a synchronous wait).
    func read(account: String) async throws -> String
    /// Reads without any user-interactive authentication. For non-secret bookkeeping
    /// values (e.g. the vault hash salt) that must be available on every ingest
    /// without showing a biometric prompt.
    func readNonInteractive(account: String) throws -> String
    func delete(account: String) throws
}

extension KeychainBackend {
    /// Convenience: write without biometric protection (non-secret bookkeeping
    /// values such as the vault hash salt).
    func write(account: String, secret: String) throws {
        try write(account: account, secret: secret, biometricProtected: false)
    }
}

enum KeychainError: Error {
    case writeFailed(OSStatus)
    case readFailed(OSStatus)
    case userCancelled
    case missing
    case decodeFailed
}
