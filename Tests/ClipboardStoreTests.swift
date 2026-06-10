import Foundation
import SwiftData

@main
struct ClipboardStoreTestRunner {
    static func main() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardItem.self, configurations: config)
        let store = ClipboardStore(container: container, maxHistory: 3)

        let defaultStoreURL = ClipboardStore.defaultStoreURL(
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/keymic-test-app-support", isDirectory: true))
        expect(
            defaultStoreURL.path == "/tmp/keymic-test-app-support/KeyMic/Clipboard.store",
            "default store path is app-specific")

        // add inserts
        store.add(text: "one", sourceBundleID: "a", sourceAppName: "A")
        expect(store.fetchAll().count == 1, "first add should insert")
        let first = store.fetchAll().first!
        expect(first.text == "one", "text matches")
        expect(first.sourceBundleID == "a", "bundle id matches")

        // dedup: identical newest text only updates createdAt
        let originalDate = first.createdAt
        Thread.sleep(forTimeInterval: 0.01)
        store.add(text: "one", sourceBundleID: "a", sourceAppName: "A")
        let after = store.fetchAll()
        expect(after.count == 1, "dedup keeps single row")
        expect(after.first!.createdAt > originalDate, "createdAt advanced")

        // distinct text inserts
        store.add(text: "two", sourceBundleID: "a", sourceAppName: "A")
        store.add(text: "three", sourceBundleID: "a", sourceAppName: "A")
        expect(store.fetchAll().count == 3, "three rows")

        // truncation past maxHistory
        store.add(text: "four", sourceBundleID: "a", sourceAppName: "A")
        let trimmed = store.fetchAll()
        expect(trimmed.count == 3, "truncated to maxHistory")
        expect(trimmed.map(\.text) == ["four", "three", "two"], "newest first, oldest dropped")

        // empty / whitespace rejected
        store.add(text: "", sourceBundleID: nil, sourceAppName: nil)
        store.add(text: "   \n\t", sourceBundleID: nil, sourceAppName: nil)
        expect(store.fetchAll().count == 3, "blank text rejected")

        // delete by id
        let target = store.fetchAll()[1]  // "three"
        store.delete(id: target.id)
        let afterDelete = store.fetchAll()
        expect(afterDelete.count == 2, "deletion removed row")
        expect(afterDelete.map(\.text) == ["four", "two"], "correct row removed")

        // truncate(to:)
        store.add(text: "five", sourceBundleID: nil, sourceAppName: nil)
        store.add(text: "six", sourceBundleID: nil, sourceAppName: nil)
        store.truncate(to: 2)
        expect(store.fetchAll().count == 2, "truncate(to:) shrinks")
        expect(store.fetchAll().first!.text == "six", "newest preserved")

        // Pinned items are exempt from count truncation
        let pinnedStore = ClipboardStore(container: container, maxHistory: 2)
        // Reset by deleting everything from prior test scope
        for old in pinnedStore.fetchAll() { pinnedStore.delete(id: old.id) }
        pinnedStore.add(text: "p1", sourceBundleID: nil, sourceAppName: nil)
        let p1 = pinnedStore.fetchAll().first(where: { $0.text == "p1" })!
        p1.isPinned = true
        p1.pinnedAt = Date()
        pinnedStore.add(text: "p2", sourceBundleID: nil, sourceAppName: nil)
        pinnedStore.add(text: "p3", sourceBundleID: nil, sourceAppName: nil)
        pinnedStore.add(text: "p4", sourceBundleID: nil, sourceAppName: nil)
        pinnedStore.add(text: "p5", sourceBundleID: nil, sourceAppName: nil)
        let allAfterTrunc = pinnedStore.fetchAll().map(\.text)
        expect(allAfterTrunc.contains("p1"), "pinned item survives count truncation")
        expect(allAfterTrunc.count == 3, "two unpinned + one pinned (maxHistory=2 + pin)")

        // Pinned items are exempt from age cleanup
        let agedItem = pinnedStore.fetchAll().first(where: { $0.text == "p1" })!
        agedItem.createdAt = Date().addingTimeInterval(-100 * 86400)
        // Trigger age cleanup directly via internal hook — exposed via test helper below
        pinnedStore.testDeleteOlderThan(days: 1)
        expect(pinnedStore.fetchAll().contains(where: { $0.text == "p1" }), "pinned item survives age cleanup")

        // Unpinning makes the item eligible again
        let toUnpin = pinnedStore.fetchAll().first(where: { $0.text == "p1" })!
        toUnpin.isPinned = false
        toUnpin.pinnedAt = nil
        pinnedStore.testDeleteOlderThan(days: 1)
        expect(
            !pinnedStore.fetchAll().contains(where: { $0.text == "p1" }), "unpinned item becomes eligible for cleanup")

        // deleteAllClipboardItems wipes ClipboardItem rows
        let wipeStore = ClipboardStore(container: container, maxHistory: 10)
        wipeStore.add(text: "alpha", sourceBundleID: nil, sourceAppName: nil)
        wipeStore.add(text: "beta", sourceBundleID: nil, sourceAppName: nil)
        expect(!wipeStore.fetchAll().isEmpty, "rows exist before wipe")
        wipeStore.deleteAllClipboardItems()
        expect(wipeStore.fetchAll().isEmpty, "wipe removed all ClipboardItem rows")

        // Dedup key matches the stored (raw) text: "hello\n" and "hello" are
        // distinct entries, and re-copying "hello\n" bumps the right row.
        let rawStore = ClipboardStore(container: container, maxHistory: 10)
        rawStore.add(text: "hello\n", sourceBundleID: nil, sourceAppName: nil)
        rawStore.add(text: "hello", sourceBundleID: nil, sourceAppName: nil)
        expect(rawStore.fetchAll().count == 2, "trailing-newline variant is a distinct entry")
        let bareRow = rawStore.fetchAll().first(where: { $0.text == "hello" })!
        let bareDate = bareRow.createdAt
        Thread.sleep(forTimeInterval: 0.01)
        rawStore.add(text: "hello\n", sourceBundleID: nil, sourceAppName: nil)
        expect(rawStore.fetchAll().count == 2, "raw duplicate dedups instead of inserting")
        expect(rawStore.fetchAll().first!.text == "hello\n", "the raw-equal row was bumped")
        expect(
            rawStore.fetchAll().first(where: { $0.text == "hello" })!.createdAt == bareDate,
            "the trimmed-equal row was NOT bumped")

        print("ClipboardStoreTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
