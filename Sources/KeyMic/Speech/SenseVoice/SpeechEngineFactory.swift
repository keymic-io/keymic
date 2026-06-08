import Foundation

enum SpeechEngineChoice { case apple, senseVoice, speechAnalyzer }

enum SpeechEngineFactory {
    /// Pick the speech backend.
    /// Priority:
    ///   1. SenseVoice — user toggle on + model ready + macOS 15+ (unchanged).
    ///   2. Apple default path:
    ///      - macOS 26+ AND locale ∈ SpeechAnalyzer supported set AND its on-device
    ///        asset installed → .speechAnalyzer (more accurate).
    ///      - otherwise → .apple (legacy SFSpeechRecognizer, always available).
    static func choose(
        osIsSonomaOrEarlier: Bool,
        enabled: Bool,
        modelReady: Bool,
        isMacOS26OrLater: Bool,
        localeSupportedBySpeechAnalyzer: Bool,
        speechAnalyzerAssetReady: Bool
    ) -> SpeechEngineChoice {
        // Pre-macOS-15 has neither SenseVoice nor SpeechAnalyzer — always legacy Apple.
        // Also makes the (impossible-at-runtime) Sonoma+macOS26 input deterministic.
        if osIsSonomaOrEarlier { return .apple }
        // 1. SenseVoice keeps its exact original gate (macOS 15+ is its only OS requirement;
        //    isMacOS26OrLater is intentionally NOT checked here).
        if enabled && modelReady {
            return .senseVoice
        }
        // 2. Apple default path — upgrade to SpeechAnalyzer only when fully ready.
        if isMacOS26OrLater && localeSupportedBySpeechAnalyzer && speechAnalyzerAssetReady {
            return .speechAnalyzer
        }
        return .apple
    }
}
