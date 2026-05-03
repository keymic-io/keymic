import Foundation
import SwiftData

@Model
final class VaultItem {
    @Attribute(.unique) var id: UUID
    var ruleID: String
    var ruleName: String
    var maskedPreview: String
    var copiedAt: Date
    var sourceBundleID: String?
    var keychainAccount: String
    var lastUsedAt: Date?
    var secretHash: String

    init(
        id: UUID = UUID(),
        ruleID: String,
        ruleName: String,
        maskedPreview: String,
        copiedAt: Date = Date(),
        sourceBundleID: String?,
        keychainAccount: String,
        secretHash: String
    ) {
        self.id = id
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.maskedPreview = maskedPreview
        self.copiedAt = copiedAt
        self.sourceBundleID = sourceBundleID
        self.keychainAccount = keychainAccount
        self.lastUsedAt = nil
        self.secretHash = secretHash
    }
}
