import Foundation

@main
struct AssetStoreTests {
    static func main() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("assetstore-test-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 造一个源文件 + 其真实 sha256
        let src = tmp.appendingPathComponent("src.bin")
        let payload = Data("hello-onnx".utf8)
        try! payload.write(to: src)
        let sha = sha256Hex(payload)

        let bundle = AssetBundle(id: "t", destDirName: "dest",
            files: [AssetFile(url: src, sha256: sha, relPath: "sub/a.bin")])
        let store = AssetStore(bundle: bundle, baseDir: tmp)

        // 初始 notDownloaded
        guard case .notDownloaded = store.state else { fatalError("want notDownloaded") }

        // 校验逻辑:对的 sha 通过,错的不过
        assert(store.verifySHA256(fileURL: src, expected: sha))
        assert(!store.verifySHA256(fileURL: src, expected: String(repeating: "0", count: 64)))

        // 下载(file:// 源)→ ready,且文件按 relPath 落入 dest/sub/a.bin。
        // 注:onState 回调在 app 内于 main 触发;CLI 单测中 main 线程被阻塞无法 drain main queue,
        // 故直接轮询 store.state —— 它是后台线程在锁内同步置位的真值来源。
        store.ensureDownloaded { _ in }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .ready = store.state { break }
            if case .failed(let m) = store.state { fatalError("download failed: \(m)") }
            usleep(20_000)
        }
        guard case .ready = store.state else { fatalError("want ready, got \(store.state)") }
        let placed = tmp.appendingPathComponent("dest/sub/a.bin")
        assert(FileManager.default.fileExists(atPath: placed.path), "file placed at relPath")
        print("AssetStoreTests passed")
    }

    static func sha256Hex(_ d: Data) -> String {
        // 复用 AssetStore 的算法以对齐
        return AssetStore.sha256Hex(d)
    }
}
