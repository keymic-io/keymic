// Sources/KeyMic/Vault/VaultMask.swift
import Foundation
import CryptoKit

enum VaultMask {
    static func mask(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count >= VaultConfig.maskMinTotalLen else {
            return String(repeating: "*", count: chars.count)
        }
        let p = VaultConfig.maskPrefixLen, q = VaultConfig.maskSuffixLen
        return String(chars.prefix(p)) + "****" + String(chars.suffix(q))
    }

    static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
