import Foundation

@main
struct SpeechEngineFactoryTestRunner {
    static func main() {
        // SenseVoice 优先(不变):macOS15+、开关开、模型就绪。
        precondition(SpeechEngineFactory.choose(
            osIsSonomaOrEarlier: false, enabled: true, modelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false) == .senseVoice)
        // 即便 SpeechAnalyzer 也合格,SenseVoice 仍优先(不分流)。
        precondition(SpeechEngineFactory.choose(
            osIsSonomaOrEarlier: false, enabled: true, modelReady: true,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: true) == .senseVoice)
        // Sonoma 及更早 → Apple。
        precondition(SpeechEngineFactory.choose(
            osIsSonomaOrEarlier: true, enabled: true, modelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false) == .apple)
        // SenseVoice 关 + 非 macOS26 → .apple。
        precondition(SpeechEngineFactory.choose(
            osIsSonomaOrEarlier: false, enabled: false, modelReady: true,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false) == .apple)
        // SenseVoice 开但模型未就绪 → .apple。
        precondition(SpeechEngineFactory.choose(
            osIsSonomaOrEarlier: false, enabled: true, modelReady: false,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: false) == .apple)
        // macOS26 + 支持 + 资产就绪 → .speechAnalyzer。
        precondition(SpeechEngineFactory.choose(
            osIsSonomaOrEarlier: false, enabled: false, modelReady: false,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: true) == .speechAnalyzer)
        // macOS26 + 支持 + 资产未就绪 → .apple(回退)。
        precondition(SpeechEngineFactory.choose(
            osIsSonomaOrEarlier: false, enabled: false, modelReady: false,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: false) == .apple)
        // macOS26 + 不支持 locale → .apple。
        precondition(SpeechEngineFactory.choose(
            osIsSonomaOrEarlier: false, enabled: false, modelReady: false,
            isMacOS26OrLater: true, localeSupportedBySpeechAnalyzer: false,
            speechAnalyzerAssetReady: true) == .apple)
        // 非 macOS26(即便资产标记就绪)→ .apple。
        precondition(SpeechEngineFactory.choose(
            osIsSonomaOrEarlier: false, enabled: false, modelReady: false,
            isMacOS26OrLater: false, localeSupportedBySpeechAnalyzer: true,
            speechAnalyzerAssetReady: true) == .apple)
        print("SpeechEngineFactoryTests passed")
    }
}
