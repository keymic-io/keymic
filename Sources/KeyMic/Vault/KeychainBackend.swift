import Foundation

protocol KeychainBackend {
    func write(account: String, secret: String) throws
    func read(account: String) throws -> String
    func delete(account: String) throws
}

enum KeychainError: Error {
    case writeFailed(OSStatus)
    case readFailed(OSStatus)
    case userCancelled
    case missing
    case decodeFailed
}
