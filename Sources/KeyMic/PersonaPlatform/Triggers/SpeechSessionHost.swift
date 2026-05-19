import Foundation

protocol SpeechClient: AnyObject {
    func handlePartial(_ text: String)
    func handleFinal(_ text: String)
    func handleError(_ msg: String)
    func handleAudioLevel(_ level: Float)
}

protocol SpeechSessionHost: AnyObject {
    /// Acquire an exclusive recording session. Throws `.busy` when another
    /// client already holds the session. Returned `SpeechSession.release()`
    /// returns control to the host.
    func acquire(client: SpeechClient) throws -> SpeechSession
}

enum SpeechSessionError: Error {
    case busy
}

final class SpeechSession {
    fileprivate weak var host: DefaultSpeechSessionHost?
    fileprivate weak var client: SpeechClient?

    fileprivate init(host: DefaultSpeechSessionHost, client: SpeechClient) {
        self.host = host
        self.client = client
    }

    func start() { host?.engineStart() }
    func stop()  { host?.engineStop() }
    func cancel(){ host?.engineCancel() }

    func release() { host?.release(self) }
}

final class DefaultSpeechSessionHost: SpeechSessionHost {
    private let speechEngine: SpeechEngine
    private weak var currentClient: SpeechClient?
    private weak var currentSession: SpeechSession?

    init(speechEngine: SpeechEngine) {
        self.speechEngine = speechEngine
    }

    func acquire(client: SpeechClient) throws -> SpeechSession {
        if currentClient != nil, currentClient !== client {
            throw SpeechSessionError.busy
        }
        let session = SpeechSession(host: self, client: client)
        currentClient = client
        currentSession = session
        return session
    }

    fileprivate func engineStart()  { speechEngine.startRecording() }
    fileprivate func engineStop()   { speechEngine.stopRecording() }
    fileprivate func engineCancel() { speechEngine.cancel() }

    fileprivate func release(_ session: SpeechSession) {
        guard session === currentSession else { return }
        currentClient = nil
        currentSession = nil
    }

    // Routing — called from AppDelegate's SpeechEngine callbacks.
    func routePartial(_ text: String)    { currentClient?.handlePartial(text) }
    func routeFinal(_ text: String)      { currentClient?.handleFinal(text) }
    func routeError(_ msg: String)       { currentClient?.handleError(msg) }
    func routeAudioLevel(_ level: Float) { currentClient?.handleAudioLevel(level) }
}
