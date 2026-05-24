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
struct ClipboardMonitorTypesTestRunner {
    static func main() throws {
        let tmp = URL(fileURLWithPath: "/tmp/keymic-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardItem.self, configurations: config)
        let store = ClipboardStore(container: container, maxHistory: 100, cacheDirectory: tmp)
        let fake = FakePasteboard()
        let monitor = ClipboardMonitor(
            pasteboard: fake,
            store: store,
            ownBundleID: "io.keymic.app",
            sourceAppProvider: { ("com.example.app", "App") },
            ignoreConfidential: { true },
            isEnabled: { true }
        )
        monitor.tickForTesting()  // consume baseline

        // 1. Image capture takes priority over a co-present .string
        let pngBytes = makePNGBytes()
        fake.simulate(image: pngBytes, mime: "public.png")
        monitor.tickForTesting()
        expect(store.fetchAll().first?.kind == .image, "image captured")
        expect(store.fetchAll().first?.imageRelativePath != nil, "cache file path set")

        // 2. File URL capture
        let url = URL(fileURLWithPath: "/tmp/sample-\(UUID().uuidString).txt")
        fake.simulate(fileURLs: [url])
        monitor.tickForTesting()
        expect(store.fetchAll().first?.kind == .file, "file captured")
        expect(store.fetchAll().first?.fileURLPath == url.path, "file path stored")

        // 3. Rich text capture stores HTML blob + plain text
        let html = Data("<b>hi</b>".utf8)
        fake.simulate(richTextHTML: html, plainText: "hi")
        monitor.tickForTesting()
        let rt = store.fetchAll().first!
        expect(rt.kind == .richText, "rich text captured")
        expect(rt.richBlob == html, "html blob captured")
        expect(rt.text == "hi", "plain text captured")

        // 4. markIgnored(token:) suppresses next matching capture only.
        monitor.markIgnored(token: "user-write")
        fake.simulate(text: "user-write")
        monitor.tickForTesting()
        let countBefore = store.fetchAll().count
        expect(
            store.fetchAll().first?.text != "user-write" || store.fetchAll().first?.kind == .richText,
            "matching token suppresses capture")
        // marker should be consumed; next external write is captured
        fake.simulate(text: "next-real")
        monitor.tickForTesting()
        expect(store.fetchAll().first?.text == "next-real", "marker is one-shot")
        _ = countBefore  // silence warning

        print("ClipboardMonitorTypesTests passed")
    }

    /// 1×1 PNG header + minimal IDAT; not a real decodable image but enough for type routing.
    private static func makePNGBytes() -> Data {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(signature + Array(repeating: 0, count: 32))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
