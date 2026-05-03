import Foundation
import SwiftData

@main
struct CleanupPolicyTestRunner {
    static func main() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardItem.self, configurations: config)

        // Mode .days drops rows older than cutoff
        let context = ModelContext(container)
        let now = Date()
        let stale = ClipboardItem(text: "stale", createdAt: now.addingTimeInterval(-31 * 86400))
        let fresh = ClipboardItem(text: "fresh", createdAt: now)
        context.insert(stale)
        context.insert(fresh)
        try context.save()

        let store = ClipboardStore(
            container: container,
            maxHistory: 1000,
            cleanupModeProvider: { .days },
            cleanupDaysProvider: { 30 }
        )
        store.applyCleanup()
        let after = store.fetchAll()
        expect(after.count == 1, "stale row removed")
        expect(after.first?.text == "fresh", "fresh row remains")

        // Mode .count truncates
        let store2 = ClipboardStore(
            container: try ModelContainer(for: ClipboardItem.self, configurations: config),
            maxHistory: 3,
            cleanupModeProvider: { .count },
            cleanupDaysProvider: { 30 }
        )
        for s in ["a", "b", "c", "d", "e"] {
            store2.add(text: s, sourceBundleID: nil, sourceAppName: nil)
        }
        expect(store2.fetchAll().count == 3, "count mode truncated to 3")

        // addCount throttle: cleanup runs every 10 inserts
        var cleanupCalls = 0
        let store3 = ClipboardStore(
            container: try ModelContainer(for: ClipboardItem.self, configurations: config),
            maxHistory: 1000,
            cleanupModeProvider: { .count },
            cleanupDaysProvider: { 30 },
            cleanupHook: { cleanupCalls += 1 }
        )
        let baseline = cleanupCalls // startup invocation
        for i in 1...9 {
            store3.add(text: "t\(i)", sourceBundleID: nil, sourceAppName: nil)
        }
        expect(cleanupCalls == baseline, "cleanup not called for first 9 inserts")
        store3.add(text: "t10", sourceBundleID: nil, sourceAppName: nil)
        expect(cleanupCalls == baseline + 1, "cleanup called on 10th insert")

        // deleteOlderThan strict-< semantics: row newer than cutoff is kept
        let container4 = try ModelContainer(for: ClipboardItem.self, configurations: config)
        let context4 = ModelContext(container4)
        // 1 second newer than 30-day cutoff to avoid sub-ms Date() drift between
        // test setup and deleteOlderThan's recomputed cutoff
        let nearCutoff = now.addingTimeInterval(-30 * 86400 + 1)
        context4.insert(ClipboardItem(text: "near-cutoff", createdAt: nearCutoff))
        try context4.save()
        let store4 = ClipboardStore(
            container: container4,
            maxHistory: 1000,
            cleanupModeProvider: { .days },
            cleanupDaysProvider: { 30 }
        )
        store4.applyCleanup()
        expect(store4.fetchAll().count == 1, "row 1s newer than cutoff is kept (strict <)")

        print("CleanupPolicyTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
