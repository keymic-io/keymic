// Sources/KeyMic/Vault/VaultMask.swift
import Foundation
import CryptoKit

enum VaultMask {
    /// Masked preview persisted in the (unencrypted) SwiftData store. Keeps only
    /// 2 + 2 characters; secrets shorter than `maskMinTotalLen` collapse to a
    /// fixed-length mask so neither content nor length leaks.
    static func mask(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count >= VaultConfig.maskMinTotalLen else {
            return String(repeating: "*", count: VaultConfig.maskShortFixedLen)
        }
        let p = VaultConfig.maskPrefixLen, q = VaultConfig.maskSuffixLen
        return String(chars.prefix(p)) + "****" + String(chars.suffix(q))
    }

    /// Salted dedup hash (HMAC-SHA256, hex). The salt lives in the Keychain, so the
    /// hash persisted next to `maskedPreview` in the unencrypted store cannot be
    /// brute-forced offline against short secrets.
    static func saltedHashHex(_ s: String, salt: String) -> String {
        let key = SymmetricKey(data: Data(salt.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
