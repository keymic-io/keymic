import AVFoundation
import Foundation

/// Errors emitted by the voice input pipeline. Owned by `VoiceStateMachine`
/// and `SpeechEngine`; surface to the user via `OverlayPanel`.
enum VoiceError: Error, Equatable {
    /// Microphone TCC authorization is not `.authorized` at the moment a
    /// session was requested. Carries the observed status for logging.
    case microphoneAccessDenied(AVAuthorizationStatus)
    /// User pressed an extraneous key during `.listening` or `.transcribing`.
    case canceledByUserKey
    /// New trigger press arrived during `.transcribing`; previous session
    /// was aborted to begin a new one.
    case canceledByTrigger
    /// `SFSpeechRecognizer` returned `nil` or `isAvailable == false` for the
    /// active locale. Carries the locale identifier for the overlay message.
    case recognizerUnavailable(String)
    /// `AVAudioEngine.start()` threw. Carries the underlying message.
    case audioEngineFailed(String)
    /// 6-minute hard cap on `.listening` was hit.
    case recordingTimedOut

    var displayMessage: String {
        switch self {
        case .microphoneAccessDenied:
            return String(localized: "Microphone access denied.\nGrant in System Settings → Privacy & Security → Microphone.")
        case .canceledByUserKey, .canceledByTrigger:
            return String(localized: "Canceled")
        case .recognizerUnavailable(let locale):
            return String(localized: "Speech recognizer not available for \(locale)")
        case .audioEngineFailed(let underlying):
            return String(localized: "Audio engine failed: \(underlying)")
        case .recordingTimedOut:
            return String(localized: "Recording stopped after 6 minutes")
        }
    }
}
