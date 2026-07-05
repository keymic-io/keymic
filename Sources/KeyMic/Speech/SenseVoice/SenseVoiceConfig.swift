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
    /// int8 导出图是 CoreML EnumeratedShapes:`speech` 仅接受 T ∈ modelFrameBuckets。
    /// 喂入前 zero-pad 到最近 bucket,真实帧数走 `speech_lengths`。超过最大 bucket
    ///(1800 帧 ≈ 1.8 分钟连续语音)截断丢尾,宁可部分结果也好过整段 final 丢失。
    static let modelFrameBuckets = [128, 256, 512, 1024, 1800]
    static let modelMaxFrames = 1800
    /// 模型在输出前前置的控制帧数(T' = T_padded + controlFrames)。
    static let controlFrames = 4

    // 模型 I/O 名(Task 0 实测确认:加载 .mlmodelc 跑真实前向 + 对照上游 export_meta.py)
    // 导出图共 4 个输入,Task 7 wrapper 必须全部喂入(不可省略 length/language/textnorm):
    //   speech         Float32 [1,T,560]  (int8 导出图为 EnumeratedShapes,T ∈ modelFrameBuckets)
    //   speech_lengths Int32   [1]         = 有效帧数 T(zero-pad 前的真实值)
    //   language       Int32   [1]         = 直接喂 embedding 下标(见 languageIds)
    //   textnorm       Int32   [1]         = embedding 下标:14=withitn 开 ITN / 15=woitn 关
    // 输出:ctc_logits Float16 [1,T',25055](raw logits,未 log_softmax)。encoder_out_lens Int32 [1]
    // 是 fp16 导出图的输出,int8 导出图没有,`infer` 缺失时回退 trueT + controlFrames 做 trim。
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

    // 模型分发:FluidInference int8 量化版(225MB,精度与 fp16 持平:
    // LibriSpeech WER 3.22→3.25%,AISHELL CER 3.09→3.09%),重打包为顶层
    // SenseVoiceSmall.mlmodelc 的 zip,托管在用户 Hugging Face repo。
    // 注意:模型最低部署目标为 macOS 15;KeyMic 工程目标 macOS 14。macOS 14 上 MLModel 加载会失败,
    // 加载返回 nil/抛错时回退到系统 SpeechEngine。
    static let modelDownloadURLString = "https://huggingface.co/lorneluo/sensevoice-small-coreml-int8/resolve/main/SenseVoiceSmall.mlmodelc.zip"
    static let modelSHA256 = "373d314c339d2d9c93fb0646ea3bca2efb0aa6c553cd4425b1364f76894dbba4"
    static let modelDirName = "SenseVoiceSmall.mlmodelc"
}
