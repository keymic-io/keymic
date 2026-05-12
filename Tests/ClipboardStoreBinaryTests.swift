import CryptoKit
import Foundation
import SwiftData

@main
struct ClipboardStoreBinaryTestRunner {
    static func main() throws {
        let tmp = URL(fileURLWithPath: "/tmp/keymic-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardItem.self, configurations: config)
        let store = ClipboardStore(container: container, maxHistory: 100, cacheDirectory: tmp)

        // 1. Inserting an image writes a cache file and a row tagged .image.
        let bytes = sampleImageBytes(byte: 0xAB, size: 4096)
        store.add(
            image: bytes, format: .png, width: 10, height: 10,
            sourceBundleID: "com.apple.Preview", sourceAppName: "Preview")

        let all = store.fetchAll()
        expect(all.count == 1, "image insert produced one row")
        let row = all[0]
        expect(row.kind == .image, "row kind is .image")
        expect(row.imageWidth == 10 && row.imageHeight == 10, "dimensions persisted")
        expect(row.byteSize == bytes.count, "byteSize persisted")
        expect(row.contentHash != nil, "contentHash set")
        guard let rel = row.imageRelativePath else { fatalError("FAIL: imageRelativePath missing") }
        let onDisk = tmp.appendingPathComponent(rel)
        expect(FileManager.default.fileExists(atPath: onDisk.path), "cache file written")
        expect(row.text.contains("10×10"), "searchable text describes image")

        // 2. Adding the same bytes again is a dedup; cache file count stays 1.
        store.add(
            image: bytes, format: .png, width: 10, height: 10,
            sourceBundleID: nil, sourceAppName: nil)
        expect(store.fetchAll().count == 1, "image dedup by contentHash")
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        expect(cacheFiles.count == 1, "no extra cache file written on dedup")

        // 3. > 20 MB image is skipped entirely.
        let huge = Data(repeating: 0x00, count: 21 * 1024 * 1024)
        store.add(
            image: huge, format: .png, width: 1, height: 1,
            sourceBundleID: nil, sourceAppName: nil)
        expect(store.fetchAll().count == 1, "oversized image rejected")

        // 4. Deleting the row also deletes the cache file.
        let id = store.fetchAll()[0].id
        store.delete(id: id)
        expect(store.fetchAll().isEmpty, "row deleted")
        expect(!FileManager.default.fileExists(atPath: onDisk.path), "cache file cleaned up")

        // 5. File URL insert dedups by path.
        let fileStore = ClipboardStore(container: container, maxHistory: 100, cacheDirectory: tmp)
        let fileURL = URL(fileURLWithPath: "/tmp/sample-\(UUID().uuidString).txt")
        fileStore.add(fileURL: fileURL, sourceBundleID: "com.apple.finder", sourceAppName: "Finder")
        expect(
            fileStore.fetchAll().contains(where: { $0.kind == .file && $0.fileURLPath == fileURL.path }),
            "file row stored with path")
        let firstFileCount = fileStore.fetchAll().count
        fileStore.add(fileURL: fileURL, sourceBundleID: nil, sourceAppName: nil)
        expect(fileStore.fetchAll().count == firstFileCount, "duplicate file URL dedups by path")

        // 6. Rich text insert stores blob + plain text, dedup by plain text.
        let rtStore = ClipboardStore(container: container, maxHistory: 100, cacheDirectory: tmp)
        let html = Data("<b>hello</b>".utf8)
        rtStore.add(
            richText: html, format: .html, plainText: "hello",
            sourceBundleID: "com.apple.Safari", sourceAppName: "Safari")
        let rtRow = rtStore.fetchAll().first { $0.kind == .richText }!
        expect(rtRow.richBlob == html, "html blob persisted")
        expect(rtRow.richBlobFormat == .html, "format persisted")
        expect(rtRow.text == "hello", "plain text fallback persisted")
        let rtCount = rtStore.fetchAll().count
        let rtf = Data("{\\rtf1 hello}".utf8)
        rtStore.add(
            richText: rtf, format: .rtf, plainText: "hello",
            sourceBundleID: nil, sourceAppName: nil)
        expect(rtStore.fetchAll().count == rtCount, "rich text dedup by plain text")

        print("ClipboardStoreBinaryTests passed")
    }

    private static func sampleImageBytes(byte: UInt8, size: Int) -> Data {
        Data(repeating: byte, count: size)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
