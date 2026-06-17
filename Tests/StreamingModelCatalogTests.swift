import Foundation

@main
struct StreamingModelCatalogTests {
    static func main() {
        let b = VoiceModelCatalog.streamingZipformerBilingual
        assert(b.id == "streaming-zipformer-bilingual-zh-en-2023-02-20", "unexpected id: \(b.id)")
        assert(b.destDirName == "models/streaming-zipformer-bilingual-zh-en", "unexpected destDir: \(b.destDirName)")
        assert(b.files.count == 4, "streaming bundle should have 4 files, got \(b.files.count)")
        // Required transducer files land at fixed relPaths the bridge config depends on.
        let rels = Set(b.files.map { $0.relPath })
        assert(rels == ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"],
               "unexpected relPaths: \(rels)")
        // Every file has a non-empty sha256 field (sentinel until first download bakes the real
        // hash — see plan Task 1 Step 1) and a real URL scheme.
        assert(b.files.allSatisfy { !$0.sha256.isEmpty && $0.url.scheme != nil }, "missing sha256/url")
        assert(b.available, "streaming bundle should be available")
        print("StreamingModelCatalogTests passed")
    }
}
