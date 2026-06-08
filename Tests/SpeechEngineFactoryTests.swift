import Foundation

@main
struct SpeechEngineFactoryTests {
    static func main() {
        // ===== Model-picker routing (no SpeechAnalyzer in play) =====
        // apple -> always apple
        assertEqual(SpeechEngineFactory.choose(model: "apple", osIsSonomaOrEarlier: false,
            senseVoiceReady: true, onnxRuntimeReady: true, onnxModelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .apple, "apple -> apple")
        // senseVoice ready -> senseVoice; not ready -> apple
        assertEqual(SpeechEngineFactory.choose(model: "senseVoice", osIsSonomaOrEarlier: false,
            senseVoiceReady: true, onnxRuntimeReady: false, onnxModelReady: false,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .senseVoice, "senseVoice ready -> senseVoice")
        assertEqual(SpeechEngineFactory.choose(model: "senseVoice", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: false,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .apple, "senseVoice not ready -> apple")
        // funasrNano ready -> onnx; runtime/model not ready -> apple
        assertEqual(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .onnx, "Nano ready -> onnx")
        assertEqual(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .apple, "Nano runtime not ready -> apple")
        assertEqual(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: false,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .apple, "Nano model not ready -> apple")
        // funasrMltNano ready -> onnx; model not ready -> apple
        assertEqual(SpeechEngineFactory.choose(model: "funasrMltNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .onnx, "MLT ready -> onnx")
        assertEqual(SpeechEngineFactory.choose(model: "funasrMltNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: false,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .apple, "MLT model not ready -> apple")
        assertEqual(SpeechEngineFactory.choose(model: "funasrMltNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .apple, "MLT runtime not ready -> apple")
        // Sonoma-or-earlier -> always apple (both onnx models + senseVoice need macOS 15+)
        assertEqual(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: true,
            senseVoiceReady: true, onnxRuntimeReady: true, onnxModelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .apple, "Nano on old OS -> apple")
        assertEqual(SpeechEngineFactory.choose(model: "funasrMltNano", osIsSonomaOrEarlier: true,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false), .apple, "MLT on old OS -> apple")

        // ===== Apple default path: SpeechAnalyzer upgrade (model == "apple") =====
        // SenseVoice 优先(选中且就绪):即便 SpeechAnalyzer 也合格,仍走 SenseVoice(不分流)。
        assertEqual(SpeechEngineFactory.choose(model: "senseVoice", osIsSonomaOrEarlier: false,
            senseVoiceReady: true, onnxRuntimeReady: false, onnxModelReady: false,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: true), .senseVoice, "senseVoice beats speechAnalyzer")
        // Sonoma 同时标 macOS26 + 全就绪 → 前置守卫确保 .apple。
        assertEqual(SpeechEngineFactory.choose(model: "apple", osIsSonomaOrEarlier: true,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: false,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: true), .apple, "Sonoma guard beats speechAnalyzer")
        // macOS26 + 支持 + 资产就绪 → .speechAnalyzer。
        assertEqual(SpeechEngineFactory.choose(model: "apple", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: false,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: true), .speechAnalyzer, "macOS26 ready -> speechAnalyzer")
        // macOS26 + 支持 + 资产未就绪 → .apple(回退)。
        assertEqual(SpeechEngineFactory.choose(model: "apple", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: false,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: false), .apple, "asset not ready -> apple")
        // macOS26 + 不支持 locale → .apple。
        assertEqual(SpeechEngineFactory.choose(model: "apple", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: false,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: true), .apple, "locale unsupported -> apple")
        // 非 macOS26(即便资产标记就绪)→ .apple。
        assertEqual(SpeechEngineFactory.choose(model: "apple", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: false,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: true), .apple, "not macOS26 -> apple")

        // ===== Combined: selected-but-not-ready falls back to SpeechAnalyzer when eligible =====
        // senseVoice 选中但未就绪 + macOS26 资产就绪 → 回退路径升级 .speechAnalyzer。
        assertEqual(SpeechEngineFactory.choose(model: "senseVoice", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: false,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: true), .speechAnalyzer, "senseVoice not ready -> speechAnalyzer fallback")
        // funasrMltNano 选中但 runtime 未就绪 + macOS26 资产就绪 → 回退升级 .speechAnalyzer。
        assertEqual(SpeechEngineFactory.choose(model: "funasrMltNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: true,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: true), .speechAnalyzer, "onnx not ready -> speechAnalyzer fallback")

        print("SpeechEngineFactoryTests passed")
    }

    static func assertEqual(_ a: SpeechEngineChoice, _ b: SpeechEngineChoice, _ msg: String) {
        if a != b { print("FAIL: \(msg): got \(a), want \(b)"); exit(1) }
    }
}
