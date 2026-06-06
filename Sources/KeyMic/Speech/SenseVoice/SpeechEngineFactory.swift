import Foundation

enum SpeechEngineChoice { case apple, senseVoice }

enum SpeechEngineFactory {
    /// Pick the speech backend. SenseVoice requires macOS 15, the user toggle on, and a ready model;
    /// every other case falls back to Apple's recognizer.
    static func choose(osIsSonomaOrEarlier: Bool, enabled: Bool, modelReady: Bool) -> SpeechEngineChoice {
        if osIsSonomaOrEarlier { return .apple }
        if !enabled { return .apple }
        if !modelReady { return .apple }
        return .senseVoice
    }
}
