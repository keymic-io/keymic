import Foundation

/// Which engine the live voice path resolved to — for display in Settings.
/// Pure value type; no Speech import, NOT behind #if (referenced unconditionally
/// by AppDelegate + SettingsUI).
enum SpeechEngineStatus: Equatable {
    case senseVoice
    case speechAnalyzer
    case sfSpeechRecognizer
    /// Apple path is on legacy SFSpeechRecognizer while a SpeechAnalyzer language
    /// pack is downloading for the current locale; the path upgrades once ready.
    case sfSpeechRecognizerDownloadingAnalyzerAsset

    /// Localized label naming the concrete engine currently in use.
    static func displayLabel(for status: SpeechEngineStatus) -> String {
        switch status {
        case .senseVoice:
            return String(localized: "SenseVoice (on-device)")
        case .speechAnalyzer:
            return String(localized: "Apple SpeechAnalyzer")
        case .sfSpeechRecognizer:
            return String(localized: "Apple SFSpeechRecognizer")
        case .sfSpeechRecognizerDownloadingAnalyzerAsset:
            return String(localized: "Apple SFSpeechRecognizer (downloading SpeechAnalyzer language pack…)")
        }
    }
}
