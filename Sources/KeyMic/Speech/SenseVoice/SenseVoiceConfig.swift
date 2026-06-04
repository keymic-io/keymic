import Foundation

/// SenseVoiceSmall 前端 + 模型 I/O 常量。带 REPLACE_* 的字段由后续 Task 0 spike 经 `make inspect` 实测填入。
enum SenseVoiceConfig {
    // 音频
    static let sampleRate: Double = 16_000

    // fbank(kaldi 兼容)
    static let melBins = 80
    static let frameLengthMs: Double = 25
    static let frameShiftMs: Double = 10
    static let ditherDisabled = true

    // LFR(low frame rate 堆叠)
    static let lfrM = 7
    static let lfrN = 6
    static let modelFeatureDim = melBins * lfrM   // 560

    // 模型 I/O 名(Task 0 inspect 确认)
    static let inputFeatureName = "speech"
    static let inputLengthName = "speech_lengths"
    static let inputLanguageName = "language"
    static let outputLogitsName = "logits"

    // 解码
    static let blankId = 0
    static let vocabResource = "vocab"

    // 语言 id(SenseVoice:auto/zh/en/yue/ja/ko)
    static let languageIds: [String: Int] = [
        "auto": 0, "zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12,
    ]

    // 模型分发
    static let modelDownloadURL = URL(string: "REPLACE_WITH_RELEASE_ASSET_URL")!
    static let modelSHA256 = "REPLACE_WITH_SHA256"
    static let modelDirName = "SenseVoiceSmall.mlmodelc"
}
