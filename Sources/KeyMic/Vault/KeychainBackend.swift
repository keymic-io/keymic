import Foundation

protocol KeychainBackend {
    func write(account: String, secret: String) throws
    /// Reads a secret. `async` because the concrete backend may show a biometric
    /// prompt — awaiting it must never block the caller's thread (the event tap
    /// lives on the main run loop and would be starved by a synchronous wait).
    func read(account: String) async throws -> String
    func delete(account: String) throws
}

enum KeychainError: Error, LocalizedError {
    case writeFailed(OSStatus)
    case readFailed(OSStatus)
    case userCancelled
    case missing
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .writeFailed(let status):
            return "Keychain write/delete operation failed with OSStatus \(status)."
        case .readFailed(let status):
            return "Keychain read operation failed with OSStatus \(status)."
        case .userCancelled:
            return "Keychain operation was cancelled by the user."
        case .missing:
            return "Keychain item is missing."
        case .decodeFailed:
            return "Keychain item could not be decoded as UTF-8 text."
        }
    }
}
