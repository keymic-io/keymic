import Foundation

@main
struct SpeechEngineFactoryTests {
    static func main() {
        // model="apple" → 永远 apple
        assert(SpeechEngineFactory.choose(model: "apple", osIsSonomaOrEarlier: false,
            senseVoiceReady: true, onnxRuntimeReady: true, onnxModelReady: true) == .apple)
        // model="funasrNano" 且 runtime+model 就绪 → onnx
        assert(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: true) == .onnx)
        // funasrNano 但 runtime 未就绪 → 回退 apple
        assert(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: true) == .apple)
        // funasrNano 但 model 未就绪 → 回退 apple
        assert(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: true, onnxModelReady: false) == .apple)
        // senseVoice 就绪 → senseVoice;未就绪 → apple
        assert(SpeechEngineFactory.choose(model: "senseVoice", osIsSonomaOrEarlier: false,
            senseVoiceReady: true, onnxRuntimeReady: false, onnxModelReady: false) == .senseVoice)
        assert(SpeechEngineFactory.choose(model: "senseVoice", osIsSonomaOrEarlier: false,
            senseVoiceReady: false, onnxRuntimeReady: false, onnxModelReady: false) == .apple)
        // Sonoma 及更早 → 永远 apple(SenseVoice/ONNX 都需 15+)
        assert(SpeechEngineFactory.choose(model: "funasrNano", osIsSonomaOrEarlier: true,
            senseVoiceReady: true, onnxRuntimeReady: true, onnxModelReady: true) == .apple)
        print("SpeechEngineFactoryTests passed")
    }
}
