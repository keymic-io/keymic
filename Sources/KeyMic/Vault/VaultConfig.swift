import Foundation

enum VaultConfig {
    static let maxScanLength = 8 * 1024
    static let maskPrefixLen = 2
    static let maskSuffixLen = 2
    static let maskMinTotalLen = 12
    /// Fixed mask emitted for secrets shorter than `maskMinTotalLen`, so the
    /// preview leaks neither content nor the secret's exact length.
    static let maskShortFixedLen = 8
    static let touchIDReuseDuration: TimeInterval = 5 * 60
    static let keychainService = "io.keymic.app.vault"
    /// Keychain account (under `keychainService`) holding the random salt used to
    /// derive `VaultItem.secretHash`. Not a secret entry itself — never listed.
    static let hashSaltAccount = "io.keymic.vault.hash-salt"
}
