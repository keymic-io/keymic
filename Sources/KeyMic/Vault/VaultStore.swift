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

    init(modelContainer: ModelContainer, keychain: KeychainBackend) {
        self.modelContainer = modelContainer
        self.context = modelContainer.mainContext
        self.keychain = keychain
    }

    func fetchAll() -> [VaultItem] {
        let descriptor = FetchDescriptor<VaultItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func ingest(match: SecretMatch, copiedFrom bundleID: String?) -> VaultItem? {
        let hash = VaultMask.sha256Hex(match.secret)
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
            try keychain.write(account: item.keychainAccount, secret: match.secret)
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
            try? keychain.delete(account: item.keychainAccount)
            return nil
        }
    }

    func reveal(_ item: VaultItem) throws -> String {
        do {
            let plain = try keychain.read(account: item.keychainAccount)
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
