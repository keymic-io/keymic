import Foundation

@main
struct SpeechEngineFactoryTests {
    static func main() {
        // apple -> always apple
        assertEqual(SpeechEngineFactory.choose(model: "apple", osIsSonomaOrEarlier: false,
            senseVoiceReady: true, onnxRuntimeReady: true, onnxModelReady: true), .apple, "apple -> apple")
        // senseVoice ready -> senseVoice; not ready -> apple
        assertEqual(SpeechEngineFactory.choose(model: "senseVoice", osIsSonomaOrEarlier: false,
            senseVoiceReady: true, onnxRuntimeReady: false, onnxModelReady: false), .senseVoice, "senseVoice ready -> senseVoice")
        assertEqual(SpeechEngineFactory.choose(model: "senseVoice", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: false), .apple, "senseVoice not ready -> apple")
        // funasrNano ready -> onnx; runtime/model not ready -> apple
        assertEqual(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: true), .onnx, "Nano ready -> onnx")
        assertEqual(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: true), .apple, "Nano runtime not ready -> apple")
        assertEqual(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: false), .apple, "Nano model not ready -> apple")
        // funasrMltNano ready -> onnx; model not ready -> apple
        assertEqual(SpeechEngineFactory.choose(model: "funasrMltNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: true), .onnx, "MLT ready -> onnx")
        assertEqual(SpeechEngineFactory.choose(model: "funasrMltNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: false), .apple, "MLT model not ready -> apple")
        assertEqual(SpeechEngineFactory.choose(model: "funasrMltNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: true), .apple, "MLT runtime not ready -> apple")
        // Sonoma-or-earlier -> always apple (both onnx models + senseVoice need macOS 15+)
        assertEqual(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: true,
            senseVoiceReady: true, onnxRuntimeReady: true, onnxModelReady: true), .apple, "Nano on old OS -> apple")
        assertEqual(SpeechEngineFactory.choose(model: "funasrMltNano", osIsSonomaOrEarlier: true,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: true), .apple, "MLT on old OS -> apple")
        print("SpeechEngineFactoryTests passed")
    }

    static func assertEqual(_ a: SpeechEngineChoice, _ b: SpeechEngineChoice, _ msg: String) {
        if a != b { print("FAIL: \(msg): got \(a), want \(b)"); exit(1) }
    }
}
