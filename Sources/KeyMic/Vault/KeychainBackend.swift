import Foundation

protocol KeychainBackend {
    func write(account: String, secret: String) throws
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

enum KeychainError: Error {
    case writeFailed(OSStatus)
    case readFailed(OSStatus)
    case userCancelled
    case missing
    case decodeFailed
}
