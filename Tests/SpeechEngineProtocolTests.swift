import Foundation

@MainActor
final class FakeSpeechEngine: SpeechEngineProtocol {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onLocaleUnavailable: ((String) -> Void)?
    var locale: Locale = Locale(identifier: "en-US")
    var startCount = 0
    var endCount = 0
    func startSession() throws -> VoiceSession { startCount += 1; return VoiceSession {} }
    func endAudio() { endCount += 1 }
}

@MainActor
final class CaptureClient: SpeechClient {
    var finals: [String] = []
    func handlePartial(_ text: String) {}
    func handleFinal(_ text: String) { finals.append(text) }
    func handleError(_ msg: String) {}
    func handleAudioLevel(_ level: Float) {}
}

@main
struct SpeechEngineProtocolTestRunner {
    @MainActor static func main() {
        let fake = FakeSpeechEngine()
        let host = DefaultSpeechSessionHost(engine: fake)
        let client = CaptureClient()
        let session = try! host.acquire(client: client)
        try! session.start()
        precondition(fake.startCount == 1, "start must reach engine (\(fake.startCount))")
        host.routeFinal("你好 world")
        precondition(client.finals == ["你好 world"], "final must route to client")
        session.stop()
        precondition(fake.endCount == 1, "stop must reach engine.endAudio")
        print("SpeechEngineProtocolTests passed")
    }
}
