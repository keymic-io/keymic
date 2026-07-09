// Sources/KeyMic/Vault/VaultStore.swift
import Foundation
import OSLog
import SwiftData

@MainActor
final class VaultStore {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "VaultStore")

    let modelContainer: ModelContainer
    private let context: ModelContext
    private let keychain: KeychainBackend

    /// Random salt for `VaultItem.secretHash` (HMAC key). Persisted in the Keychain —
    /// NOT in the unencrypted SwiftData store — so the hashes stored there can't be
    /// brute-forced offline. Loaded lazily; created (and persisted) on first use.
    private lazy var hashSalt: String = loadOrCreateHashSalt()

    init(modelContainer: ModelContainer, keychain: KeychainBackend) {
        self.modelContainer = modelContainer
        self.context = modelContainer.mainContext
        self.keychain = keychain
    }

    private func loadOrCreateHashSalt() -> String {
        if let existing = try? keychain.readNonInteractive(account: VaultConfig.hashSaltAccount),
           !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &generator) }
        let salt = Data(bytes).base64EncodedString()
        do {
            try keychain.write(account: VaultConfig.hashSaltAccount, secret: salt)
        } catch {
            // Non-fatal: dedup degrades (a fresh salt next launch treats re-copied
            // secrets as new entries), but ingest still works.
            Self.logger.error("vault hash-salt persist failed: \(String(describing: error), privacy: .public)")
        }
        return salt
    }

    func fetchAll() -> [VaultItem] {
        let descriptor = FetchDescriptor<VaultItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func ingest(match: SecretMatch, copiedFrom bundleID: String?) -> VaultItem? {
        // Salted hash. Pre-existing rows hashed with the legacy unsalted scheme simply
        // won't match — the secret is re-ingested as a new entry, never a crash.
        let hash = VaultMask.saltedHashHex(match.secret, salt: hashSalt)
        let ruleID = match.rule.id
        let descriptor = FetchDescriptor<VaultItem>(
            predicate: #Predicate { $0.ruleID == ruleID && $0.secretHash == hash }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.copiedAt = Date()
            existing.sourceBundleID = bundleID ?? existing.sourceBundleID
            try? context.save()
            return existing
        }

        let item = VaultItem(
            ruleID: match.rule.id,
            ruleName: match.rule.description,
            maskedPreview: VaultMask.mask(match.secret),
            sourceBundleID: bundleID,
            keychainAccount: UUID().uuidString,
            secretHash: hash
        )
        do {
            try keychain.write(account: item.keychainAccount, secret: match.secret, biometricProtected: true)
        } catch {
            Self.logger.error("keychain write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        context.insert(item)
        do {
            try context.save()
            return item
        } catch {
            Self.logger.error("vault metadata save failed: \(error.localizedDescription, privacy: .public)")
            context.delete(item)
            do {
                try keychain.delete(account: item.keychainAccount)
            } catch {
                Self.logger.error("keychain cleanup delete failed (orphaned entry \(item.keychainAccount, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    func reveal(_ item: VaultItem) async throws -> String {
        do {
            let plain = try await keychain.read(account: item.keychainAccount)
            item.lastUsedAt = Date()
            try? context.save()
            return plain
        } catch KeychainError.missing {
            context.delete(item)
            try? context.save()
            throw KeychainError.missing
        }
    }

    func delete(_ item: VaultItem) {
        try? keychain.delete(account: item.keychainAccount)
        context.delete(item)
        try? context.save()
    }
}
