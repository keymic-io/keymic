import Foundation

@main
struct VoiceModelCatalogTests {
    static func main() {
        // runtime bundle:2 文件,版本化 onnxruntime 名在列
        let rt = VoiceModelCatalog.runtime
        assert(rt.files.count == 2, "runtime should have 2 dylibs")
        assert(rt.files.contains { $0.relPath == "libonnxruntime.1.24.4.dylib" })
        assert(rt.files.allSatisfy { !$0.sha256.isEmpty && $0.url.scheme != nil })

        // funasr-nano:6 文件(3 onnx + 3 tokenizer),tokenizer 在 Qwen3-0.6B 子目录
        let fa = VoiceModelCatalog.funasrNano
        assert(fa.files.count == 6, "funasr-nano should have 6 files")
        assert(fa.files.contains { $0.relPath == "Qwen3-0.6B/tokenizer.json" })
        assert(fa.files.allSatisfy { !$0.sha256.isEmpty })
        assert(fa.available, "funasr-nano available")

        // online-punct-en:2 文件(model.int8.onnx + bpe.vocab),含 ModelScope 镜像,
        // SHA256 须为 64 位十六进制(防哈希长度缺陷)。
        let punct = VoiceModelCatalog.onlinePunctEn
        assert(punct.files.count == 2, "online-punct-en should have 2 files")
        assert(punct.files.contains { $0.relPath == "model.int8.onnx" })
        assert(punct.files.contains { $0.relPath == "bpe.vocab" })
        assert(punct.files.allSatisfy { $0.sha256.count == 64 }, "sha256 must be 64 hex chars")
        assert(punct.files.allSatisfy { !$0.mirrors.isEmpty && $0.url.scheme != nil })

        // ct-transformer zh-en:1 文件(model.int8.onnx),含 ModelScope 镜像,SHA256 64 位十六进制。
        let ctPunct = VoiceModelCatalog.ctPunctZhEn
        assert(ctPunct.files.count == 1, "ct-punct should have 1 file")
        assert(ctPunct.files.contains { $0.relPath == "model.int8.onnx" })
        assert(ctPunct.files.allSatisfy { $0.sha256.count == 64 }, "sha256 must be 64 hex chars")
        assert(ctPunct.files.allSatisfy { !$0.mirrors.isEmpty && $0.url.scheme != nil })

        // 选择项:含 apple/senseVoice/funasrNano/funasrMltNano,均 available
        // (MLT 自 151a4c0 起有 HF+ModelScope 镜像资产,故可用)。
        let models = VoiceModelCatalog.selectableModels
        assert(models.contains { $0.id == "funasrNano" && $0.available })
        assert(models.contains { $0.id == "funasrMltNano" && $0.available })
        print("VoiceModelCatalogTests passed")
    }
}
