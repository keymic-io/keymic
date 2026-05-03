import Foundation

enum VaultConfig {
    static let maxScanLength = 8 * 1024
    static let maskPrefixLen = 4
    static let maskSuffixLen = 4
    static let maskMinTotalLen = 12
    static let touchIDReuseDuration: TimeInterval = 5 * 60
    static let keychainService = "io.keymic.app.vault"
}
