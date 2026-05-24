import Foundation

@main
struct VoiceStateMachineTestRunner {
    static func main() {
        testIdleTriggerDownEntersListening()
        testListeningTriggerUpEntersTranscribingAndStopsAudio()
        testListeningExtraneousKeyCancelsAndReturnsToIdle()
        testListeningRecordingTimeoutEntersTranscribing()
        testListeningErrorClearsSession()
        testListeningVoiceDisabledCancelsSession()
        testListeningFinalResultInjectsDirectly()
        testTranscribingFinalResultInjectsAndReturnsToIdle()
        testTranscribingGraceTimeoutInjectsLastPartial()
        testTranscribingExtraneousKeyDiscardsResult()
        testTranscribingTriggerDownAbortsAndRestarts()
        testTranscribingErrorClearsSession()
        testTranscribingVoiceDisabledCancelsSession()
        testIdleIgnoresStrayEvents()
        testIdleErrorShowsOverlay()
        print("VoiceStateMachineTests passed")
    }

    // -- helpers ----------------------------------------------------------
    private static func makeSession() -> VoiceSession {
        VoiceSession { /* cancel hook unused in pure tests */ }
    }
    private static func expect(_ cond: @autoclosure () -> Bool, _ msg: String) {
        if !cond() { FileHandle.standardError.write("FAIL: \(msg)\n".data(using: .utf8)!); exit(1) }
    }
    private static func contains(_ haystack: [VoiceSideEffect], _ needle: VoiceSideEffect) -> Bool {
        haystack.contains(where: { $0 == needle })
    }

    // -- cases ------------------------------------------------------------

    static func testIdleTriggerDownEntersListening() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        let effects = sm.handle(.triggerDown(session: s))
        if case .listening = sm.state {} else { expect(false, "idle+triggerDown should enter listening, got \(sm.state)") }
        expect(contains(effects, .updateStatusIcon(recording: true)), "missing updateStatusIcon true")
        expect(contains(effects, .startRecordingTimeoutTimer(s)), "missing timeout timer")
        expect(contains(effects, .playSound(name: "Tink")), "missing tink")
    }

    static func testListeningTriggerUpEntersTranscribingAndStopsAudio() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        let effects = sm.handle(.triggerUp)
        if case .transcribing = sm.state {} else { expect(false, "expected transcribing, got \(sm.state)") }
        expect(contains(effects, .stopAudio(s)), "missing stopAudio")
        expect(contains(effects, .startGraceTimer), "missing startGraceTimer")
        expect(contains(effects, .updateStatusIcon(recording: false)), "missing icon-off")
    }

    static func testListeningExtraneousKeyCancelsAndReturnsToIdle() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        let effects = sm.handle(.extraneousKey)
        if case .idle = sm.state {} else { expect(false, "expected idle, got \(sm.state)") }
        expect(contains(effects, .cancelSession(s)), "missing cancelSession")
        expect(contains(effects, .overlayShowCanceled), "missing overlayShowCanceled")
        expect(contains(effects, .cancelRecordingTimeoutTimer), "missing cancelRecordingTimeoutTimer")
    }

    static func testListeningRecordingTimeoutEntersTranscribing() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        let effects = sm.handle(.recordingTimeout)
        if case .transcribing = sm.state {} else { expect(false, "expected transcribing, got \(sm.state)") }
        expect(contains(effects, .stopAudio(s)), "missing stopAudio")
        expect(contains(effects, .startGraceTimer), "missing startGraceTimer")
    }

    static func testListeningErrorClearsSession() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        let effects = sm.handle(.error(.audioEngineFailed("boom")))
        if case .idle = sm.state {} else { expect(false, "expected idle, got \(sm.state)") }
        expect(contains(effects, .cancelSession(s)), "missing cancelSession on error")
        expect(contains(effects, .overlayShowError(.audioEngineFailed("boom"))), "missing overlay error")
    }

    static func testListeningVoiceDisabledCancelsSession() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        let effects = sm.handle(.voiceDisabled)
        if case .idle = sm.state {} else { expect(false, "expected idle, got \(sm.state)") }
        expect(contains(effects, .cancelSession(s)), "missing cancel on disable")
    }

    static func testListeningFinalResultInjectsDirectly() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        let effects = sm.handle(.finalResult("short utterance"))
        if case .idle = sm.state {} else { expect(false, "expected idle after listening+finalResult, got \(sm.state)") }
        expect(contains(effects, .cancelRecordingTimeoutTimer), "missing cancelRecordingTimeoutTimer")
        expect(contains(effects, .cancelSession(s)), "missing cancelSession")
        expect(contains(effects, .updateStatusIcon(recording: false)), "missing updateStatusIcon false")
        expect(contains(effects, .injectAndFinish(text: "short utterance")), "missing injectAndFinish")
        expect(sm.lastPartial.isEmpty, "lastPartial must reset after final")
    }

    static func testTranscribingFinalResultInjectsAndReturnsToIdle() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        _ = sm.handle(.triggerUp)
        let effects = sm.handle(.finalResult("hello"))
        if case .idle = sm.state {} else { expect(false, "expected idle, got \(sm.state)") }
        expect(contains(effects, .cancelGraceTimer), "missing cancelGraceTimer")
        expect(contains(effects, .injectAndFinish(text: "hello")), "missing injectAndFinish")
        expect(contains(effects, .cancelSession(s)), "missing cancelSession")
    }

    static func testTranscribingGraceTimeoutInjectsLastPartial() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        _ = sm.handle(.partialResult("hi"))
        _ = sm.handle(.triggerUp)
        let effects = sm.handle(.graceTimeout)
        if case .idle = sm.state {} else { expect(false, "expected idle, got \(sm.state)") }
        expect(contains(effects, .injectAndFinish(text: "hi")), "missing injectAndFinish 'hi'")
    }

    static func testTranscribingExtraneousKeyDiscardsResult() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        _ = sm.handle(.partialResult("hello"))
        _ = sm.handle(.triggerUp)
        let effects = sm.handle(.extraneousKey)
        if case .idle = sm.state {} else { expect(false, "expected idle, got \(sm.state)") }
        expect(contains(effects, .cancelSession(s)), "missing cancelSession")
        expect(contains(effects, .overlayShowCanceled), "missing overlayShowCanceled")
        expect(!effects.contains(where: { if case .injectAndFinish = $0 { return true } else { return false } }), "must NOT inject")
    }

    static func testTranscribingTriggerDownAbortsAndRestarts() {
        var sm = VoiceStateMachine()
        let s1 = makeSession()
        _ = sm.handle(.triggerDown(session: s1))
        _ = sm.handle(.triggerUp)
        let s2 = makeSession()
        let effects = sm.handle(.triggerDown(session: s2))
        if case .listening(let live) = sm.state {
            expect(live.id == s2.id, "expected new session in state, got \(live.id) vs \(s2.id)")
        } else {
            expect(false, "expected listening, got \(sm.state)")
        }
        expect(contains(effects, .cancelSession(s1)), "missing cancel of old session")
        expect(contains(effects, .startRecordingTimeoutTimer(s2)), "missing new timeout timer")
        let cancelIdx = effects.firstIndex(where: { $0 == .cancelSession(s1) })
        let newTimerIdx = effects.firstIndex(where: { $0 == .startRecordingTimeoutTimer(s2) })
        expect(cancelIdx != nil && newTimerIdx != nil, "expected both cancel and new timer effects")
        if let c = cancelIdx, let t = newTimerIdx {
            expect(c < t, "cancelSession(oldSession) must precede startRecordingTimeoutTimer(newSession); got cancelIdx=\(c), newTimerIdx=\(t)")
        }
    }

    static func testTranscribingErrorClearsSession() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        _ = sm.handle(.triggerUp)
        let effects = sm.handle(.error(.recognizerUnavailable("en-US")))
        if case .idle = sm.state {} else { expect(false, "expected idle, got \(sm.state)") }
        expect(contains(effects, .cancelSession(s)), "missing cancelSession on error")
    }

    static func testTranscribingVoiceDisabledCancelsSession() {
        var sm = VoiceStateMachine()
        let s = makeSession()
        _ = sm.handle(.triggerDown(session: s))
        _ = sm.handle(.triggerUp)
        let effects = sm.handle(.voiceDisabled)
        if case .idle = sm.state {} else { expect(false, "expected idle after transcribing+voiceDisabled, got \(sm.state)") }
        expect(contains(effects, .cancelGraceTimer), "missing cancelGraceTimer")
        expect(contains(effects, .cancelSession(s)), "missing cancelSession")
        expect(contains(effects, .overlayDismiss), "missing overlayDismiss")
    }

    static func testIdleErrorShowsOverlay() {
        var sm = VoiceStateMachine()
        let effects = sm.handle(.error(.microphoneAccessDenied(.denied)))
        expect(effects.count == 1, "idle/error should produce exactly one effect (overlayShowError)")
        if case .overlayShowError(let err) = effects[0] {
            if case .microphoneAccessDenied = err {} else { expect(false, "wrong VoiceError kind in overlayShowError") }
        } else {
            expect(false, "expected overlayShowError effect, got \(effects[0])")
        }
        if case .idle = sm.state {} else { expect(false, "must remain idle after preflight error") }
    }

    static func testIdleIgnoresStrayEvents() {
        var sm = VoiceStateMachine()
        let e1 = sm.handle(.triggerUp)
        let e2 = sm.handle(.partialResult("noise"))
        let e3 = sm.handle(.extraneousKey)
        if case .idle = sm.state {} else { expect(false, "must stay idle") }
        expect(e1.isEmpty && e2.isEmpty && e3.isEmpty, "idle must ignore stray events")
    }
}
