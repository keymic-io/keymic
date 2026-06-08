import Foundation

enum SpeechEngineChoice { case apple, senseVoice, onnx, speechAnalyzer }

enum SpeechEngineFactory {
    /// 按 picker 选中的 model + 各引擎就绪度选后端。SenseVoice 与 ONNX 均需 macOS 15;
    /// 选中项未就绪一律回退 Apple 默认路径。Apple 默认/回退路径在 macOS 26 且 locale 受
    /// SpeechAnalyzer 支持、其本地资产就绪时升级为 .speechAnalyzer(更准),否则 .apple
    /// (legacy SFSpeechRecognizer,始终可用)。
    static func choose(model: String,
                       osIsSonomaOrEarlier: Bool,
                       senseVoiceReady: Bool,
                       onnxRuntimeReady: Bool,
                       onnxModelReady: Bool,
                       isMacOS26OrLater: Bool,
                       localeSupportedBySpeechAnalyzer: Bool,
                       speechAnalyzerAssetReady: Bool) -> SpeechEngineChoice {
        // Pre-macOS-15 has neither SenseVoice/ONNX nor SpeechAnalyzer — always legacy Apple.
        // Also makes the (impossible-at-runtime) Sonoma+macOS26 input deterministic.
        if osIsSonomaOrEarlier { return .apple }
        switch model {
        case "senseVoice":
            if senseVoiceReady { return .senseVoice }
        case "funasrNano", "funasrMltNano":
            if onnxRuntimeReady && onnxModelReady { return .onnx }
        default:
            break
        }
        // Apple 默认/回退路径 —— 完整就绪时升级 SpeechAnalyzer,否则 legacy Apple。
        if isMacOS26OrLater && localeSupportedBySpeechAnalyzer && speechAnalyzerAssetReady {
            return .speechAnalyzer
        }
        return .apple
    }
}
