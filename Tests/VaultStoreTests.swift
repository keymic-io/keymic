// Tests/VaultStoreTests.swift
import Foundation
import SwiftData

@main
struct VaultStoreTestRunner {
    @MainActor
    static func main() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardItem.self, VaultItem.self, configurations: config)
        let backend = InMemoryKeychainBackend()
        let store = VaultStore(modelContainer: container, keychain: backend)

        let rule = SecretRule(raw: [
            "id": .string("aws-access-token"),
            "regex": .string(#"AKIA[0-9A-Z]{16}"#),
            "keywords": .array(["AKIA"]),
            "description": .string("AWS Access Key")
        ])!

        let match = SecretMatch(rule: rule, secret: "AKIAABCDEFGHIJKLMNOP")
        let v = store.ingest(match: match, copiedFrom: "com.example.app")!
        expect(store.fetchAll().count == 1, "one vault item after ingest")
        expect(v.maskedPreview == "AKIA****MNOP", "mask formatted")
        let plain = try store.reveal(v)
        expect(plain == "AKIAABCDEFGHIJKLMNOP", "reveal returns plaintext")

        let firstCopiedAt = v.copiedAt
        Thread.sleep(forTimeInterval: 0.01)
        _ = store.ingest(match: match, copiedFrom: nil)
        expect(store.fetchAll().count == 1, "dedup keeps single row")
        expect(store.fetchAll().first!.copiedAt > firstCopiedAt, "copiedAt bumped")

        let target = store.fetchAll().first!
        store.delete(target)
        expect(store.fetchAll().isEmpty, "vault empty after delete")
        do {
            _ = try backend.read(account: target.keychainAccount)
            fatalError("expected missing")
        } catch KeychainError.missing {
            // expected
        }

        let v2 = store.ingest(match: match, copiedFrom: nil)!
        try backend.delete(account: v2.keychainAccount)
        do {
            _ = try store.reveal(v2)
            fatalError("expected throw")
        } catch KeychainError.missing {
            expect(store.fetchAll().isEmpty, "orphan metadata cleaned up")
        }

        print("VaultStoreTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
