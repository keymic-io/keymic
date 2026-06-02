import Foundation

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
