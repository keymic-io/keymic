import Foundation

/// 进程级共享的 ONNX 模型下载 store。AppDelegate(引擎决策)与设置下载控制器共用同一实例,
/// 保证下载进度/就绪状态在 UI 与引擎间一致。runtime store 已是单例(`ONNXRuntimeLoader.shared.store`)。
enum OnnxStores {
    static let model = AssetStore(bundle: VoiceModelCatalog.funasrNano)
    /// Fun-ASR-MLT-Nano (31 langs) store — distinct destDir (`models/funasr-mlt-nano-ar`), so it
    /// coexists on disk with `model`. The active engine uses whichever the picker selects.
    static let mltModel = AssetStore(bundle: VoiceModelCatalog.funasrMltNano)
    /// Streaming model store (meeting transcription). Distinct destDir from the offline models.
    static let streaming = AssetStore(bundle: VoiceModelCatalog.streamingZipformerBilingual)
    /// Offline speaker-diarization model store (P2.2). Distinct destDir from the ASR models.
    static let diarization = AssetStore(bundle: VoiceModelCatalog.speakerDiarization)
    /// English online punctuation + truecasing store (meeting transcript post-processing). Tiny
    /// (~7 MB); piggybacks the streaming-model download from meeting setup.
    static let punct = AssetStore(bundle: VoiceModelCatalog.onlinePunctEn)
    /// CT-transformer zh-en offline punctuation store (Chinese transcript segments, ~72 MB).
    static let ctPunct = AssetStore(bundle: VoiceModelCatalog.ctPunctZhEn)
}
