import Foundation
import CryptoKit

@main
struct SenseVoiceModelStoreTestRunner {
    static func main() {
        let dir = NSTemporaryDirectory() + "svstore_\(UUID().uuidString)/"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = dir + "blob.bin"
        let data = Data([1,2,3,4,5])
        try! data.write(to: URL(fileURLWithPath: f))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let store = SenseVoiceModelStore(baseDir: URL(fileURLWithPath: dir))
        precondition(store.verifySHA256(fileURL: URL(fileURLWithPath: f), expected: sha), "matching sha must pass")
        precondition(!store.verifySHA256(fileURL: URL(fileURLWithPath: f), expected: "deadbeef"), "wrong sha must fail")
        precondition(store.state == .notDownloaded, "fresh dir → notDownloaded (\(store.state))")

        // --- version marker: stale model dir must be evicted ---
        do {
            let dir2 = NSTemporaryDirectory() + "svstore_\(UUID().uuidString)/"
            let base = URL(fileURLWithPath: dir2)
            let modelDir = base.appendingPathComponent(SenseVoiceConfig.modelDirName)
            try! FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            // no marker file → stale (pre-marker install, e.g. old fp16 model)
            let s1 = SenseVoiceModelStore(baseDir: base)
            precondition(s1.state == .notDownloaded, "model dir without marker → evict + notDownloaded (\(s1.state))")
            precondition(!FileManager.default.fileExists(atPath: modelDir.path), "stale model dir must be removed")
        }
        do {
            let dir3 = NSTemporaryDirectory() + "svstore_\(UUID().uuidString)/"
            let base = URL(fileURLWithPath: dir3)
            let modelDir = base.appendingPathComponent(SenseVoiceConfig.modelDirName)
            try! FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            let marker = base.appendingPathComponent(SenseVoiceConfig.modelDirName + ".version")
            try! "deadbeef".write(to: marker, atomically: true, encoding: .utf8)
            let s2 = SenseVoiceModelStore(baseDir: base)
            precondition(s2.state == .notDownloaded, "mismatched marker → evict (\(s2.state))")
        }
        do {
            let dir4 = NSTemporaryDirectory() + "svstore_\(UUID().uuidString)/"
            let base = URL(fileURLWithPath: dir4)
            let modelDir = base.appendingPathComponent(SenseVoiceConfig.modelDirName)
            try! FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            let marker = base.appendingPathComponent(SenseVoiceConfig.modelDirName + ".version")
            try! SenseVoiceConfig.modelSHA256.write(to: marker, atomically: true, encoding: .utf8)
            let s3 = SenseVoiceModelStore(baseDir: base)
            precondition(s3.state == .ready, "matching marker → ready (\(s3.state))")
        }

        print("SenseVoiceModelStoreTests passed")
    }
}
