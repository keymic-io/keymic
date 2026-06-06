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
    /// 导出图 `speech` 输入帧数 T 的上界(弹性 1...3000)。超过会让 `model.prediction`
    /// 因 shape/range 不匹配抛错(约 3 分钟连续语音)。前端在喂入前截断到该上界,
    /// 宁可丢尾部也好过整段 final 丢失。
    static let modelMaxFrames = 3000

    // 模型 I/O 名(Task 0 实测确认:加载 .mlmodelc 跑真实前向 + 对照上游 export_meta.py)
    // 导出图共 4 个输入,Task 7 wrapper 必须全部喂入(不可省略 length/language/textnorm):
    //   speech         Float32 [1,T,560]  (T 弹性 1...3000)
    //   speech_lengths Int32   [1]         = 有效帧数 T
    //   language       Int32   [1]         = 直接喂 embedding 下标(见 languageIds)
    //   textnorm       Int32   [1]         = embedding 下标:14=withitn 开 ITN / 15=woitn 关
    // 输出 2 个:ctc_logits Float16 [1,T',25055](raw logits,未 log_softmax),encoder_out_lens Int32 [1]
    static let inputFeatureName = "speech"
    static let inputLengthName = "speech_lengths"
    static let inputLanguageName = "language"
    static let inputTextNormName = "textnorm"      // Task 0 新增:导出图存在 textnorm 输入
    static let outputLogitsName = "ctc_logits"     // Task 0 修正:实测名为 ctc_logits(非 logits)
    static let outputLengthName = "encoder_out_lens"

    // textnorm embedding 下标(上游 textnorm_dict)。默认 woitn=15(不做逆文本规整,与转换/sanity 脚本一致)。
    static let textNormWithITN = 14
    static let textNormWithoutITN = 15
    static let defaultTextNorm = 15

    // 解码
    static let blankId = 0                          // Task 0 确认:config.json ctc_blank_id=0;SPM piece[0]=<unk> 复用为 blank
    static let vocabResource = "chn_jpn_yue_eng_ko_spectok.bpe"   // SPM .model 资源名(运行时解析 protobuf 词表)
    static let vocabSize = 25055                    // Task 0 实测:ctc_logits 末维 == SPM piece 数 == 25055

    // 语言 id(直接作为 language 输入的 Int32 值,= 上游 model.py lid_dict)
    static let languageIds: [String: Int] = [
        "auto": 0, "zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12, "nospeech": 13,
    ]

    // 模型分发(Task 0 实测确认)
    // 注意:模型最低部署目标为 macOS 15;KeyMic 工程目标 macOS 14。macOS 14 上 MLModel 加载会失败,
    // Task 7/8 需在加载返回 nil/抛错时回退到系统 SpeechEngine。
    static let modelDownloadURLString = "https://huggingface.co/mefengl/SenseVoiceSmall-coreml/resolve/main/coreml/SenseVoiceSmall.mlmodelc.zip"
    static let modelSHA256 = "880711fa03577363e6c1b1b6e9321f130ea1a53d5c065d92e1abd8a431bad6be"
    static let modelDirName = "SenseVoiceSmall.mlmodelc"
}
