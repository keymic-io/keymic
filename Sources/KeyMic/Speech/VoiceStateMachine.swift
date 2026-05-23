import Foundation

/// External events that drive the voice state machine. Produced by
/// `AppDelegate` from KeyMonitor callbacks, SpeechEngine callbacks, timers,
/// and menu toggles.
enum VoiceEvent {
    /// Voice trigger key went down (Fn / Right Option / persona hotkey).
    case triggerDown(session: VoiceSession)
    /// Voice trigger key was released.
    case triggerUp
    /// Streaming partial transcript update from `SFSpeechRecognizer`.
    case partialResult(String)
    /// Final transcript from `SFSpeechRecognizer`.
    case finalResult(String)
    /// 2 s grace period elapsed with no final result.
    case graceTimeout
    /// 6 minute recording cap reached while `.listening`.
    case recordingTimeout
    /// User pressed any non-trigger key while voice was active.
    case extraneousKey
    /// Recognition / audio engine surfaced an error.
    case error(VoiceError)
    /// User toggled voice off via menu / settings.
    case voiceDisabled
}

/// Effects the reducer asks the runtime to perform after a transition.
enum VoiceSideEffect: Equatable {
    case cancelSession(VoiceSession)
    case stopAudio(VoiceSession)        // endAudio without canceling the recognition task
    case startGraceTimer
    case cancelGraceTimer
    case startRecordingTimeoutTimer(VoiceSession)
    case cancelRecordingTimeoutTimer
    case updateStatusIcon(recording: Bool)
    case overlayShow(text: String)
    case overlayUpdate(text: String)
    case overlayShowRefining
    case overlayDismiss
    case overlayShowCanceled
    case overlayShowError(VoiceError)
    case injectAndFinish(text: String)
    case playSound(name: String)
    case bufferPartial(String)
    case clearPartial

    static func == (lhs: VoiceSideEffect, rhs: VoiceSideEffect) -> Bool {
        switch (lhs, rhs) {
        case (.cancelSession(let a), .cancelSession(let b)),
             (.stopAudio(let a), .stopAudio(let b)),
             (.startRecordingTimeoutTimer(let a), .startRecordingTimeoutTimer(let b)):
            return a.id == b.id
        case (.startGraceTimer, .startGraceTimer),
             (.cancelGraceTimer, .cancelGraceTimer),
             (.cancelRecordingTimeoutTimer, .cancelRecordingTimeoutTimer),
             (.overlayShowRefining, .overlayShowRefining),
             (.overlayDismiss, .overlayDismiss),
             (.overlayShowCanceled, .overlayShowCanceled),
             (.clearPartial, .clearPartial):
            return true
        case (.updateStatusIcon(let a), .updateStatusIcon(let b)):
            return a == b
        case (.overlayShow(let a), .overlayShow(let b)),
             (.overlayUpdate(let a), .overlayUpdate(let b)),
             (.injectAndFinish(let a), .injectAndFinish(let b)),
             (.bufferPartial(let a), .bufferPartial(let b)),
             (.playSound(let a), .playSound(let b)):
            return a == b
        case (.overlayShowError(let a), .overlayShowError(let b)):
            return a == b
        default:
            return false
        }
    }
}

struct VoiceStateMachine {
    private(set) var state: VoiceState = .idle
    /// Latest partial transcript. Replayed when a grace timeout fires with no
    /// final result so we can still inject the user's last words.
    private(set) var lastPartial: String = ""

    @discardableResult
    mutating func handle(_ event: VoiceEvent) -> [VoiceSideEffect] {
        switch (state, event) {

        // --- idle ----------------------------------------------------------
        case (.idle, .triggerDown(let session)):
            state = .listening(session: session)
            lastPartial = ""
            return [
                .updateStatusIcon(recording: true),
                .overlayShow(text: String(localized: "Listening...")),
                .playSound(name: "Tink"),
                .startRecordingTimeoutTimer(session),
            ]

        case (.idle, .error(let err)):
            return [.overlayShowError(err)]

        case (.idle, _):
            return []  // ignore stray events

        // --- listening -----------------------------------------------------
        case (.listening(let session), .triggerUp):
            state = .transcribing(session: session)
            return [
                .updateStatusIcon(recording: false),
                .cancelRecordingTimeoutTimer,
                .stopAudio(session),
                .startGraceTimer,
            ]

        case (.listening(let session), .recordingTimeout):
            state = .transcribing(session: session)
            return [
                .updateStatusIcon(recording: false),
                .stopAudio(session),
                .startGraceTimer,
            ]

        case (.listening(let session), .extraneousKey):
            state = .idle
            return [
                .cancelRecordingTimeoutTimer,
                .cancelSession(session),
                .updateStatusIcon(recording: false),
                .overlayShowCanceled,
                .clearPartial,
            ]

        case (.listening, .partialResult(let text)):
            lastPartial = text
            return [.bufferPartial(text), .overlayUpdate(text: text)]

        case (.listening(let session), .finalResult(let text)):
            // Final result while still listening is rare but possible —
            // recognizer can emit isFinal=true before triggerUp on short
            // utterances. Treat as straight-through inject.
            state = .idle
            lastPartial = ""
            return [
                .cancelRecordingTimeoutTimer,
                .cancelSession(session),
                .updateStatusIcon(recording: false),
                .injectAndFinish(text: text),
            ]

        case (.listening(let session), .error(let err)):
            state = .idle
            lastPartial = ""
            return [
                .cancelRecordingTimeoutTimer,
                .cancelSession(session),
                .updateStatusIcon(recording: false),
                .overlayShowError(err),
            ]

        case (.listening(let session), .voiceDisabled):
            state = .idle
            lastPartial = ""
            return [
                .cancelRecordingTimeoutTimer,
                .cancelSession(session),
                .updateStatusIcon(recording: false),
                .overlayDismiss,
            ]

        case (.listening, .triggerDown), (.listening, .graceTimeout):
            return []

        // --- transcribing --------------------------------------------------
        case (.transcribing, .partialResult(let text)):
            lastPartial = text
            return [.bufferPartial(text), .overlayUpdate(text: text)]

        case (.transcribing(let session), .finalResult(let text)):
            state = .idle
            lastPartial = ""
            return [
                .cancelGraceTimer,
                .cancelSession(session),
                .injectAndFinish(text: text),
            ]

        case (.transcribing(let session), .graceTimeout):
            state = .idle
            let partial = lastPartial
            lastPartial = ""
            return [
                .cancelSession(session),
                .injectAndFinish(text: partial),
            ]

        case (.transcribing(let session), .extraneousKey):
            state = .idle
            lastPartial = ""
            return [
                .cancelGraceTimer,
                .cancelSession(session),
                .overlayShowCanceled,
            ]

        case (.transcribing(let oldSession), .triggerDown(let newSession)):
            state = .listening(session: newSession)
            lastPartial = ""
            return [
                .cancelGraceTimer,
                .cancelSession(oldSession),
                .updateStatusIcon(recording: true),
                .overlayShow(text: String(localized: "Listening...")),
                .playSound(name: "Tink"),
                .startRecordingTimeoutTimer(newSession),
            ]

        case (.transcribing(let session), .error(let err)):
            state = .idle
            lastPartial = ""
            return [
                .cancelGraceTimer,
                .cancelSession(session),
                .overlayShowError(err),
            ]

        case (.transcribing(let session), .voiceDisabled):
            state = .idle
            lastPartial = ""
            return [
                .cancelGraceTimer,
                .cancelSession(session),
                .overlayDismiss,
            ]

        case (.transcribing, .triggerUp), (.transcribing, .recordingTimeout):
            return []
        }
    }
}
