import Foundation

/// 一个待下载文件:远端 URL + 期望 SHA256 + 相对落盘路径(可含子目录,如 Qwen3-0.6B/x)。
struct AssetFile {
    let url: URL
    let sha256: String
    let relPath: String
}

/// 一组一起下载、放进同一目录的文件(runtime dylib 集 / 某模型文件集)。
struct AssetBundle {
    let id: String
    let destDirName: String   // App Support/KeyMic/<destDirName>
    let files: [AssetFile]
}

extension AssetBundle {
    /// 该 bundle 是否有对应可下载资产(runtime / funasrNano 均为 true)。MLT 不建 AssetBundle。
    var available: Bool { true }
}

/// 设置 picker 里可选的一项语音模型。
struct VoiceModelOption {
    let id: String            // "apple" | "senseVoice" | "funasrNano" | "funasrMltNano"
    let displayName: String
    let available: Bool       // false → picker 置灰「暂不可用」
    /// 下载体积(约值,unit 跨语言通用,不本地化);nil = 系统内置/无需下载。
    let sizeText: String?
    /// 该模型支持的语言码(与 `SpeechLanguageCatalog` 同源);nil = 支持全部(Apple)。
    /// 注意:macOS 的 SFSpeechRecognizer 把 yue(粤语)/wuu(上海话)当独立语言码暴露,
    /// 故语言栏里它们是独立项;SenseVoice 支持 yue,所以要显式列出。
    let supportedLanguages: [String]?

    /// 是否支持某语言码。nil(Apple)→ 永远 true。
    func supports(_ languageCode: String) -> Bool {
        guard let supportedLanguages else { return true }
        return supportedLanguages.contains(languageCode)
    }
}

/// 静态注册表:URL/SHA256 实测 baked。
enum VoiceModelCatalog {
    private static func hf(_ file: String) -> URL {
        URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30/resolve/main/\(file)")!
    }
    private static func runtimeURL(_ file: String) -> URL {
        URL(string: "https://github.com/keymic-io/keymic/releases/download/onnx-runtime-v1.13.2/\(file)")!
    }

    static let runtime = AssetBundle(
        id: "onnx-runtime-v1.13.2",
        destDirName: "onnx-runtime",
        files: [
            AssetFile(url: runtimeURL("libonnxruntime.1.24.4.dylib"),
                      sha256: "e9a9534fc92910d9bd6ffd155c13ce7920417c652c5c1920178520880627513e",
                      relPath: "libonnxruntime.1.24.4.dylib"),
            AssetFile(url: runtimeURL("libsherpa-onnx-c-api.dylib"),
                      sha256: "a392340c0da4fea1b5c79663b39fdd638f74397a6c938f38e45c63e95df09084",
                      relPath: "libsherpa-onnx-c-api.dylib"),
        ])

    static let funasrNano = AssetBundle(
        id: "funasr-nano-int8-2025-12-30",
        destDirName: "models/funasr-nano-ar",
        files: [
            AssetFile(url: hf("encoder_adaptor.int8.onnx"),
                      sha256: "f36dea2e30fbc33b5db1d7a7265cc976c5e5586c77b042d5adb1ad27c72db422",
                      relPath: "encoder_adaptor.int8.onnx"),
            AssetFile(url: hf("llm.int8.onnx"),
                      sha256: "dfbf9aa3be41bccc257587f151e15c63fbe1b549f2b517f5ccd5bdce3bf4322a",
                      relPath: "llm.int8.onnx"),
            AssetFile(url: hf("embedding.int8.onnx"),
                      sha256: "95e61cd0c9c3b9543339a4cf973c95c116815e745ccc1e0285cbd81f76d18644",
                      relPath: "embedding.int8.onnx"),
            AssetFile(url: hf("Qwen3-0.6B/tokenizer.json"),
                      sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
                      relPath: "Qwen3-0.6B/tokenizer.json"),
            AssetFile(url: hf("Qwen3-0.6B/vocab.json"),
                      sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
                      relPath: "Qwen3-0.6B/vocab.json"),
            AssetFile(url: hf("Qwen3-0.6B/merges.txt"),
                      sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
                      relPath: "Qwen3-0.6B/merges.txt"),
        ])

    /// picker 选择项。Apple/SenseVoice 走各自既有引擎;funasrNano 走 ONNX;MLT 暂不可用(无 sherpa 包)。
    static let selectableModels: [VoiceModelOption] = [
        VoiceModelOption(id: "apple", displayName: "Apple (system)", available: true, sizeText: nil,
                         supportedLanguages: nil),
        VoiceModelOption(id: "senseVoice", displayName: "SenseVoice Small", available: true, sizeText: "≈ 432 MB",
                         supportedLanguages: ["zh", "yue", "en", "ja", "ko"]),
        VoiceModelOption(id: "funasrNano", displayName: "Fun-ASR-Nano (zh/en/ja)", available: true, sizeText: "≈ 1 GB",
                         supportedLanguages: ["zh", "en", "ja"]),
        VoiceModelOption(id: "funasrMltNano", displayName: "Fun-ASR-MLT-Nano (31 langs) — coming soon", available: false,
                         sizeText: nil, supportedLanguages: nil),
    ]
}
