import Foundation

/// Stable telemetry name for each speech-engine choice. Kept 1:1 with
/// `SpeechEngineChoice` so `engine_selected.engine` is a fixed low-cardinality enum.
/// Lives apart from `TelemetryService` so the wrapper stays free of any SDK/type
/// dependency and can be dropped into the standalone `swiftc` test runners on its own.
extension SpeechEngineChoice {
    var telemetryName: String {
        switch self {
        case .apple: return "apple"
        case .senseVoice: return "senseVoice"
        case .onnx: return "onnx"
        case .speechAnalyzer: return "speechAnalyzer"
        }
    }
}
