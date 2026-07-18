import Foundation

/// Spy sink that records every call as a `name|payload` string so the test can
/// assert both gating behaviour and the emitted signal name + payload keys.
final class SpyTelemetrySink: TelemetrySink {
    private(set) var calls: [String] = []
    var count: Int { calls.count }

    func engineSelected(model: String, engine: String, osMajor: String, locale: String) {
        calls.append("engine_selected|model=\(model),engine=\(engine),osMajor=\(osMajor),locale=\(locale)")
    }
    func modelDownload(model: String, result: String, durationMs: Int, source: String, errorKind: String?) {
        calls.append("model_download|model=\(model),result=\(result),durationMs=\(durationMs),source=\(source),errorKind=\(errorKind ?? "nil")")
    }
    func engineColdStart(engine: String, firstBufferMs: Int, scoWatchdogFired: Bool) {
        calls.append("engine_cold_start|engine=\(engine),firstBufferMs=\(firstBufferMs),scoWatchdogFired=\(scoWatchdogFired)")
    }
    func transcribeError(engine: String, errorKind: String) {
        calls.append("transcribe_error|engine=\(engine),errorKind=\(errorKind)")
    }
    func permissionState(mic: String, speech: String, accessibility: String, screenCapture: String) {
        calls.append("permission_state|mic=\(mic),speech=\(speech),accessibility=\(accessibility),screenCapture=\(screenCapture)")
    }
    func eventTapFailed() { calls.append("event_tap_failed|") }
    func featureUsed(_ feature: String) { calls.append("feature_used|feature=\(feature)") }
    func personaInvoked(persona: String, injectionStrategy: String) {
        calls.append("persona_invoked|persona=\(persona),injectionStrategy=\(injectionStrategy)")
    }
    func hotkeyAction(_ action: String) { calls.append("hotkey_action|action=\(action)") }
    func activationFirstTranscription() { calls.append("activation_first_transcription|") }
}

@main
struct TelemetryGatingTests {
    static func main() {
        // Scratch defaults so setEnabled doesn't touch the real domain.
        let defaults = UserDefaults(suiteName: "io.keymic.app.telemetry.test")!
        defaults.removePersistentDomain(forName: "io.keymic.app.telemetry.test")

        // 1. Disabled -> zero sink calls.
        let spy1 = SpyTelemetrySink()
        let disabled = TelemetryService(sink: spy1, enabled: false, defaults: defaults)
        disabled.featureUsed("voice")
        disabled.engineSelected(model: "apple", engine: "apple", osMajor: "15", locale: "en-US")
        disabled.eventTapFailed()
        assert(spy1.count == 0, "disabled service must not emit; got \(spy1.count)")

        // 2. Enabled -> sink receives the expected signal name + payload keys.
        let spy2 = SpyTelemetrySink()
        let enabled = TelemetryService(sink: spy2, enabled: true, defaults: defaults)
        enabled.featureUsed("clipboard")
        enabled.engineSelected(model: "senseVoice", engine: "senseVoice", osMajor: "15", locale: "zh-CN")
        assert(spy2.count == 2, "enabled service should emit 2; got \(spy2.count)")
        assert(spy2.calls[0] == "feature_used|feature=clipboard",
               "unexpected feature_used payload: \(spy2.calls[0])")
        assert(spy2.calls[1] == "engine_selected|model=senseVoice,engine=senseVoice,osMajor=15,locale=zh-CN",
               "unexpected engine_selected payload: \(spy2.calls[1])")

        // 3. Toggling off mid-run -> no further calls.
        enabled.setEnabled(false)
        enabled.featureUsed("persona")
        enabled.hotkeyAction("toggleClipboard")
        assert(spy2.count == 2, "no emission after toggle-off; got \(spy2.count)")
        // ...and back on resumes emission.
        enabled.setEnabled(true)
        enabled.activationFirstTranscription()
        assert(spy2.count == 3, "emission resumes after toggle-on; got \(spy2.count)")
        assert(spy2.calls[2] == "activation_first_transcription|",
               "unexpected activation payload: \(spy2.calls[2])")

        // 4. SpeechEngineChoice -> engine string is 1:1 for all 4 cases.
        let mapping: [(SpeechEngineChoice, String)] = [
            (.apple, "apple"),
            (.senseVoice, "senseVoice"),
            (.onnx, "onnx"),
            (.speechAnalyzer, "speechAnalyzer"),
        ]
        var seen = Set<String>()
        for (choice, expected) in mapping {
            assert(choice.telemetryName == expected,
                   "\(choice) mapped to \(choice.telemetryName), want \(expected)")
            assert(seen.insert(choice.telemetryName).inserted,
                   "duplicate telemetry name \(choice.telemetryName) — mapping not 1:1")
        }
        assert(seen.count == 4, "expected 4 distinct engine names; got \(seen.count)")

        defaults.removePersistentDomain(forName: "io.keymic.app.telemetry.test")
        print("TelemetryGatingTests passed")
    }

    static func assert(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
