import Foundation

/// 一个待下载文件:远端 URL + 期望 SHA256 + 相对落盘路径(可含子目录,如 Qwen3-0.6B/x)。
struct AssetFile {
    let url: URL
    let sha256: String
    let relPath: String
    /// 备用镜像 URL,主 `url` 失败时按序重试(如 HF 不可达 → ModelScope)。
    let mirrors: [URL]

    init(url: URL, sha256: String, relPath: String, mirrors: [URL] = []) {
        self.url = url
        self.sha256 = sha256
        self.relPath = relPath
        self.mirrors = mirrors
    }
}

/// 一组一起下载、放进同一目录的文件(runtime dylib 集 / 某模型文件集)。
struct AssetBundle {
    let id: String
    let destDirName: String   // App Support/KeyMic/<destDirName>
    let files: [AssetFile]
}

extension AssetBundle {
    /// 该 bundle 是否有对应可下载资产(runtime / funasrNano / funasrMltNano 均为 true)。
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
    private static func hfMlt(_ file: String) -> URL {
        URL(string: "https://huggingface.co/lorneluo/sherpa-onnx-funasr-mlt-nano-int8-2512/resolve/main/\(file)")!
    }
    private static func msMlt(_ file: String) -> URL {
        URL(string: "https://www.modelscope.cn/models/lorneluo2/sherpa-onnx-funasr-mlt-nano-int8-2512/resolve/master/\(file)")!
    }
    private static func hfStreaming(_ file: String) -> URL {
        URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/main/\(file)")!
    }
    private static func hfPyannote(_ file: String) -> URL {
        URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/\(file)")!
    }
    private static func hf3DSpeaker(_ file: String) -> URL {
        URL(string: "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/\(file)")!
    }
    private static func hfOnlinePunct(_ file: String) -> URL {
        URL(string: "https://huggingface.co/lorneluo/sherpa-onnx-online-punct-en-2024-08-06/resolve/main/\(file)")!
    }
    private static func msOnlinePunct(_ file: String) -> URL {
        URL(string: "https://www.modelscope.cn/models/lorneluo2/sherpa-onnx-online-punct-en-2024-08-06/resolve/master/\(file)")!
    }
    private static func hfCtPunct(_ file: String) -> URL {
        URL(string: "https://huggingface.co/lorneluo/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/resolve/main/\(file)")!
    }
    private static func msCtPunct(_ file: String) -> URL {
        URL(string: "https://www.modelscope.cn/models/lorneluo2/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/resolve/master/\(file)")!
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

    static let funasrMltNano = AssetBundle(
        id: "funasr-mlt-nano-int8-2512",
        destDirName: "models/funasr-mlt-nano-ar",
        files: [
            AssetFile(url: hfMlt("encoder_adaptor.int8.onnx"),
                      sha256: "d38cf070a354f5166bc24a4cd885cceb0fa465c7b0410b11d6c376ce77e256bd",
                      relPath: "encoder_adaptor.int8.onnx",
                      mirrors: [msMlt("encoder_adaptor.int8.onnx")]),
            AssetFile(url: hfMlt("llm.int8.onnx"),
                      sha256: "ef4308d86844c7f3ddb90b237014ca0a3830aadcfc5551e65d813e63098b131b",
                      relPath: "llm.int8.onnx",
                      mirrors: [msMlt("llm.int8.onnx")]),
            AssetFile(url: hfMlt("embedding.int8.onnx"),
                      sha256: "8bc272cde3148b17fbef94f34fa25605f5a98fdb6fd0bc71a8410148f2b1d217",
                      relPath: "embedding.int8.onnx",
                      mirrors: [msMlt("embedding.int8.onnx")]),
            // Qwen3-0.6B tokenizer files are byte-identical to funasrNano's (same tokenizer); each
            // bundle keeps its own copy under its destDir — intentional, not a copy-paste error.
            AssetFile(url: hfMlt("Qwen3-0.6B/tokenizer.json"),
                      sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
                      relPath: "Qwen3-0.6B/tokenizer.json",
                      mirrors: [msMlt("Qwen3-0.6B/tokenizer.json")]),
            AssetFile(url: hfMlt("Qwen3-0.6B/vocab.json"),
                      sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
                      relPath: "Qwen3-0.6B/vocab.json",
                      mirrors: [msMlt("Qwen3-0.6B/vocab.json")]),
            AssetFile(url: hfMlt("Qwen3-0.6B/merges.txt"),
                      sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
                      relPath: "Qwen3-0.6B/merges.txt",
                      mirrors: [msMlt("Qwen3-0.6B/merges.txt")]),
        ])

    /// Streaming bilingual (zh/en) zipformer transducer for meeting transcription (M1).
    /// 4 files: int8 encoder + decoder + int8 joiner + tokens. relPaths are normalized to
    /// fixed short names so the bridge config can hardcode them regardless of upstream naming.
    /// SHA256 baked from the real HF download verified by the M1 streaming-decode smoke (2026-06-19).
    static let streamingZipformerBilingual = AssetBundle(
        id: "streaming-zipformer-bilingual-zh-en-2023-02-20",
        destDirName: "models/streaming-zipformer-bilingual-zh-en",
        files: [
            AssetFile(url: hfStreaming("encoder-epoch-99-avg-1.int8.onnx"),
                      sha256: "8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b", relPath: "encoder.onnx"),
            AssetFile(url: hfStreaming("decoder-epoch-99-avg-1.onnx"),
                      sha256: "2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d", relPath: "decoder.onnx"),
            AssetFile(url: hfStreaming("joiner-epoch-99-avg-1.int8.onnx"),
                      sha256: "1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0", relPath: "joiner.onnx"),
            AssetFile(url: hfStreaming("tokens.txt"),
                      sha256: "a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3", relPath: "tokens.txt"),
        ])

    /// Offline speaker-diarization models (P2.2): pyannote segmentation + 3D-Speaker campplus
    /// embedding. relPaths normalized to fixed names so the bridge config can hardcode them.
    /// SHA256 baked from the verified real downloads (computed at implementation time).
    static let speakerDiarization = AssetBundle(
        id: "speaker-diarization-pyannote-3dspeaker-1",
        destDirName: "models/speaker-diarization",
        files: [
            AssetFile(url: hfPyannote("model.onnx"),
                      sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
                      relPath: "segmentation.onnx"),
            AssetFile(url: hf3DSpeaker("3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"),
                      sha256: "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11",
                      relPath: "embedding.onnx"),
        ])

    /// English online punctuation + truecasing (sherpa-onnx-online-punct-en-2024-08-06). Applied to
    /// streaming meeting transcripts to turn the all-caps, punctuation-free zipformer English into
    /// normal-cased, punctuated text. 2 files; relPaths normalized to fixed names so the bridge
    /// config can hardcode them. SHA256 baked from the real upstream tarball download (2026-06-25).
    static let onlinePunctEn = AssetBundle(
        id: "online-punct-en-2024-08-06",
        destDirName: "models/online-punct-en",
        files: [
            AssetFile(url: hfOnlinePunct("model.int8.onnx"),
                      sha256: "9d611f445fe4a46186080fe161be6059d87d72eb88d3a8cb00c1a06e83a6067e",
                      relPath: "model.int8.onnx",
                      mirrors: [msOnlinePunct("model.int8.onnx")]),
            AssetFile(url: hfOnlinePunct("bpe.vocab"),
                      sha256: "e118b7ad88c54db562517df49e1cffd4836d166c34fb190fd311d7f34eb238f5",
                      relPath: "bpe.vocab",
                      mirrors: [msOnlinePunct("bpe.vocab")]),
        ])

    /// CT-transformer zh-en offline punctuation (sherpa-onnx-punct-ct-transformer-zh-en-vocab272727,
    /// int8). Adds punctuation (。，？！…) to Chinese (and mixed zh-en) transcript segments; does NOT
    /// change casing — Chinese has none. 1 file (~72 MB). SHA256 baked from the real upstream tarball
    /// (2026-06-25). English segments still use `onlinePunctEn` (it truecases; CT-transformer doesn't).
    static let ctPunctZhEn = AssetBundle(
        id: "punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8",
        destDirName: "models/punct-ct-zh-en",
        files: [
            AssetFile(url: hfCtPunct("model.int8.onnx"),
                      sha256: "65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1",
                      relPath: "model.int8.onnx",
                      mirrors: [msCtPunct("model.int8.onnx")]),
        ])

    /// picker 选择项。Apple/SenseVoice 走各自既有引擎;funasrNano / funasrMltNano 均走 ONNX(sherpa funasr runtime)。
    static let selectableModels: [VoiceModelOption] = [
        VoiceModelOption(id: "apple", displayName: "Apple (system)", available: true, sizeText: nil,
                         supportedLanguages: nil),
        VoiceModelOption(id: "senseVoice", displayName: "SenseVoice Small", available: true, sizeText: "≈ 198 MB",
                         supportedLanguages: ["zh", "yue", "en", "ja", "ko"]),
        VoiceModelOption(id: "funasrNano", displayName: "Fun-ASR-Nano (zh/en/ja)", available: true, sizeText: "≈ 1 GB",
                         supportedLanguages: ["zh", "en", "ja"]),
        VoiceModelOption(id: "funasrMltNano", displayName: "Fun-ASR-MLT-Nano (31 langs)", available: true,
                         sizeText: "≈ 1 GB",
                         supportedLanguages: ["zh", "en", "yue", "ja", "ko", "vi", "id", "th", "ms", "fil",
                                              "ar", "hi", "bg", "hr", "cs", "da", "nl", "et", "fi", "el",
                                              "hu", "ga", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "sv"]),
    ]
}
