// Tests/Support/InMemoryKeychainBackend.swift
import Foundation

final class InMemoryKeychainBackend: KeychainBackend {
    private var store: [String: String] = [:]
    func write(account: String, secret: String, biometricProtected: Bool) throws { store[account] = secret }
    func read(account: String) async throws -> String {
        guard let v = store[account] else { throw KeychainError.missing }
        return v
    }
    func readNonInteractive(account: String) throws -> String {
        guard let v = store[account] else { throw KeychainError.missing }
        return v
    }
    func delete(account: String) throws { store.removeValue(forKey: account) }
}
