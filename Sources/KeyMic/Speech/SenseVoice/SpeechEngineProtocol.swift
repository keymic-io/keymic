import Foundation

@MainActor
protocol SpeechEngineProtocol: AnyObject {
    var onPartialResult: ((String) -> Void)? { get set }
    var onFinalResult: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onLocaleUnavailable: ((String) -> Void)? { get set }
    var locale: Locale { get set }
    func startSession() throws -> VoiceSession
    func endAudio()
}
