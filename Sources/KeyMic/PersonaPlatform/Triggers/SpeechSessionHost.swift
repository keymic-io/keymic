import Foundation

@MainActor
protocol SpeechClient: AnyObject {
    func handlePartial(_ text: String)
    func handleFinal(_ text: String)
    func handleError(_ msg: String)
    func handleAudioLevel(_ level: Float)
}

@MainActor
protocol SpeechSessionHost: AnyObject {
    func acquire(client: SpeechClient) throws -> SpeechSession
}

enum SpeechSessionError: Error {
    case busy
}

@MainActor
final class SpeechSession {
    fileprivate weak var host: DefaultSpeechSessionHost?
    fileprivate var voiceSession: VoiceSession?

    fileprivate init(host: DefaultSpeechSessionHost) {
        self.host = host
    }

    func start() throws {
        try host?.engineStart(self)
    }

    func stop() {
        host?.engineStop(self)
    }

    func cancel() {
        host?.engineCancel(self)
    }

    func release() {
        host?.release(self)
    }
}

@MainActor
final class DefaultSpeechSessionHost: SpeechSessionHost {
    private let speechEngine: any SpeechEngineProtocol
    private weak var currentClient: SpeechClient?
    private weak var currentSession: SpeechSession?

    init(engine: any SpeechEngineProtocol) {
        self.speechEngine = engine
    }

    func acquire(client: SpeechClient) throws -> SpeechSession {
        if let currentClient, currentClient !== client {
            throw SpeechSessionError.busy
        }
        if let currentSession {
            return currentSession
        }
        let session = SpeechSession(host: self)
        currentClient = client
        currentSession = session
        return session
    }

    fileprivate func engineStart(_ session: SpeechSession) throws {
        guard session === currentSession else { return }
        session.voiceSession = try speechEngine.startSession()
    }

    fileprivate func engineStop(_ session: SpeechSession) {
        guard session === currentSession else { return }
        speechEngine.endAudio()
    }

    fileprivate func engineCancel(_ session: SpeechSession) {
        guard session === currentSession else { return }
        session.voiceSession?.cancel()
        session.voiceSession = nil
    }

    fileprivate func release(_ session: SpeechSession) {
        guard session === currentSession else { return }
        session.voiceSession?.cancel()
        session.voiceSession = nil
        currentClient = nil
        currentSession = nil
    }

    func routePartial(_ text: String) {
        currentClient?.handlePartial(text)
    }

    func routeFinal(_ text: String) {
        currentClient?.handleFinal(text)
    }

    func routeError(_ msg: String) {
        currentClient?.handleError(msg)
    }

    func routeAudioLevel(_ level: Float) {
        currentClient?.handleAudioLevel(level)
    }
}
