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
        print("SenseVoiceModelStoreTests passed")
    }
}
