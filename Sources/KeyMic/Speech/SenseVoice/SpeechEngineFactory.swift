import Foundation

enum SpeechEngineChoice { case apple, senseVoice, onnx }

enum SpeechEngineFactory {
    /// 按 picker 选中的 model + 各引擎就绪度选后端。SenseVoice 与 ONNX 均需 macOS 15;
    /// 选中项未就绪一律回退 Apple。
    static func choose(model: String,
                       osIsSonomaOrEarlier: Bool,
                       senseVoiceReady: Bool,
                       onnxRuntimeReady: Bool,
                       onnxModelReady: Bool) -> SpeechEngineChoice {
        if osIsSonomaOrEarlier { return .apple }
        switch model {
        case "senseVoice":
            return senseVoiceReady ? .senseVoice : .apple
        case "funasrNano", "funasrMltNano":
            return (onnxRuntimeReady && onnxModelReady) ? .onnx : .apple
        default:
            return .apple
        }
    }
}
