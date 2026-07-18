import Foundation
import os
import TelemetryDeck

/// The one and only `import TelemetryDeck` site. Everything else in the app talks
/// to `TelemetryService` / `TelemetrySink`, so the SDK can be swapped or removed by
/// touching this file alone. Emit methods map the typed, content-free arguments to
/// TelemetryDeck signal names (snake_case) + string parameters.
final class TelemetryDeckSink: TelemetrySink {
    private static let appIDKey = "TelemetryDeckAppID"
    private static let log = Logger(subsystem: "io.keymic.app", category: "Telemetry")

    /// Reads the app ID from `Info.plist`, initializes the SDK, and returns a sink.
    /// Returns `nil` when no app ID is configured (expected during local dev), so a
    /// missing key never crashes and no SDK is initialized.
    static func makeIfConfigured() -> TelemetryDeckSink? {
        guard let appID = Bundle.main.object(forInfoDictionaryKey: appIDKey) as? String,
              !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.info("TelemetryDeck app ID missing; telemetry SDK not initialized")
            return nil
        }
        let config = TelemetryDeck.Config(appID: appID)
        #if DEBUG
        // Debug emissions are flagged as test signals so they can be self-tested
        // via the TelemetryDeck dashboard Test Mode without polluting production.
        config.testMode = true
        #endif
        TelemetryDeck.initialize(config: config)
        return TelemetryDeckSink()
    }

    private func send(_ name: String, _ parameters: [String: String]) {
        TelemetryDeck.signal(name, parameters: parameters)
    }

    // MARK: - Diagnostics

    func engineSelected(model: String, engine: String, osMajor: String, locale: String) {
        // NB: `locale` is a TelemetryDeck reserved key (auto-added to every signal),
        // so send our value under `speechLocale` to avoid collision / a reserved-key warning.
        send("engine_selected", ["model": model, "engine": engine, "osMajor": osMajor, "speechLocale": locale])
    }

    func modelDownload(model: String, result: String, durationMs: Int, source: String, errorKind: String?) {
        var params = ["model": model, "result": result, "durationMs": String(durationMs), "source": source]
        if let errorKind { params["errorKind"] = errorKind }
        send("model_download", params)
    }

    func engineColdStart(engine: String, firstBufferMs: Int, scoWatchdogFired: Bool) {
        send("engine_cold_start", ["engine": engine,
                                   "firstBufferMs": String(firstBufferMs),
                                   "scoWatchdogFired": String(scoWatchdogFired)])
    }

    func transcribeError(engine: String, errorKind: String) {
        send("transcribe_error", ["engine": engine, "errorKind": errorKind])
    }

    func permissionState(mic: String, speech: String, accessibility: String, screenCapture: String) {
        send("permission_state", ["mic": mic, "speech": speech,
                                  "accessibility": accessibility, "screenCapture": screenCapture])
    }

    func eventTapFailed() {
        send("event_tap_failed", [:])
    }

    // MARK: - Adoption

    func featureUsed(_ feature: String) {
        send("feature_used", ["feature": feature])
    }

    func personaInvoked(persona: String, injectionStrategy: String) {
        send("persona_invoked", ["persona": persona, "injectionStrategy": injectionStrategy])
    }

    func hotkeyAction(_ action: String) {
        send("hotkey_action", ["action": action])
    }

    func activationFirstTranscription() {
        send("activation_first_transcription", [:])
    }

    func terminate() {
        TelemetryDeck.terminate()
    }
}
