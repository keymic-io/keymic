import AppKit
import Foundation
import SwiftData

final class FakePasteboard: PasteboardReading {
    var changeCount: Int = 0
    var stringValue: String?
    var typesValue: [String] = []
    var dataByType: [String: Data] = [:]
    var fileURLValues: [URL] = []

    func string() -> String? { stringValue }
    func types() -> [String] { typesValue }
    func data(forType type: String) -> Data? { dataByType[type] }
    func fileURLs() -> [URL] { fileURLValues }
    func copyItems() -> [NSPasteboardItem]? { nil }
    func writeItems(_ items: [NSPasteboardItem]) -> Int { changeCount += 1; return changeCount }

    func simulate(text: String, types: [String] = []) {
        stringValue = text
        typesValue = types
        dataByType = [:]
        fileURLValues = []
        changeCount += 1
    }

    func simulate(image data: Data, mime type: String) {
        stringValue = nil
        typesValue = [type]
        dataByType = [type: data]
        fileURLValues = []
        changeCount += 1
    }

    func simulate(fileURLs urls: [URL]) {
        stringValue = nil
        typesValue = ["public.file-url"]
        dataByType = [:]
        fileURLValues = urls
        changeCount += 1
    }

    func simulate(richTextHTML html: Data, plainText: String) {
        stringValue = plainText
        typesValue = ["public.html", "public.utf8-plain-text"]
        dataByType = ["public.html": html]
        fileURLValues = []
        changeCount += 1
    }
}

@main
struct ClipboardMonitorTestRunner {
    static func main() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardItem.self, configurations: config)
        let store = ClipboardStore(container: container, maxHistory: 100)

        let fake = FakePasteboard()
        let monitor = ClipboardMonitor(
            pasteboard: fake,
            store: store,
            ownBundleID: "io.keymic.app",
            sourceAppProvider: { ("com.example.Editor", "Editor") },
            ignoreConfidential: { true },
            isEnabled: { true }
        )

        // initial tick observes baseline; nothing inserted
        monitor.tickForTesting()
        expect(store.fetchAll().isEmpty, "baseline tick inserts nothing")

        // normal copy
        fake.simulate(text: "hello")
        monitor.tickForTesting()
        expect(store.fetchAll().map(\.text) == ["hello"], "captured text")
        expect(store.fetchAll().first?.sourceBundleID == "com.example.Editor", "captured source")

        // confidential type skipped
        fake.simulate(text: "secret", types: [ConfidentialClipboardType.concealed])
        monitor.tickForTesting()
        expect(store.fetchAll().count == 1, "confidential drop")

        // Counter-based ignore: markIgnoredChangeCount suppresses the next tick with that changeCount
        fake.simulate(text: "self-paste")
        let selfPasteCC = fake.changeCount
        monitor.markIgnoredChangeCount(selfPasteCC)
        monitor.tickForTesting()
        expect(store.fetchAll().count == 1, "self-paste ignored")
        // marker clears after one observation — next change is captured
        fake.simulate(text: "after-self")
        monitor.tickForTesting()
        expect(store.fetchAll().map(\.text).first == "after-self", "next change captured")

        // own bundle source skipped
        let keymicMonitor = ClipboardMonitor(
            pasteboard: fake,
            store: store,
            ownBundleID: "io.keymic.app",
            sourceAppProvider: { ("io.keymic.app", "KeyMic") },
            ignoreConfidential: { true },
            isEnabled: { true }
        )
        keymicMonitor.tickForTesting() // baseline
        let sizeBefore = store.fetchAll().count
        fake.simulate(text: "from-keymic")
        keymicMonitor.tickForTesting()
        expect(store.fetchAll().count == sizeBefore, "own-bundle source dropped")

        // disabled monitor ignores
        let disabled = ClipboardMonitor(
            pasteboard: fake,
            store: store,
            ownBundleID: "io.keymic.app",
            sourceAppProvider: { ("com.example.Editor", "Editor") },
            ignoreConfidential: { true },
            isEnabled: { false }
        )
        disabled.tickForTesting()
        let sizeBefore2 = store.fetchAll().count
        fake.simulate(text: "while-disabled")
        disabled.tickForTesting()
        expect(store.fetchAll().count == sizeBefore2, "disabled monitor inserts nothing")

        print("ClipboardMonitorTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
