import Foundation

// NOTE: This exercises `InMemoryKeychainBackend` (a plain dictionary fake), NOT the
// real `KeychainVault`. It guards the VaultStore ↔ backend contract (round-trip +
// missing-after-delete) only. The real `KeychainVault`'s biometric path —
// `.userPresence` access control on write, Touch ID `evaluatePolicy` on read, and the
// lazy `upgradeToBiometricACL` migration — talks to the system Keychain and
// LocalAuthentication and CANNOT run in a headless swiftc runner (it would hang on the
// Touch ID prompt or fail with errSecAuthFailed). Verify that path manually on-device.
@main
struct KeychainVaultTestRunner {
    static func main() async throws {
        let backend = InMemoryKeychainBackend()
        try backend.write(account: "a", secret: "hello")
        let r = try await backend.read(account: "a")
        expect(r == "hello", "round trip works")
        try backend.delete(account: "a")
        do {
            _ = try await backend.read(account: "a")
            fatalError("expected missing error")
        } catch KeychainError.missing {
            // expected
        } catch {
            fatalError("unexpected error: \(error)")
        }
        print("KeychainVaultTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
