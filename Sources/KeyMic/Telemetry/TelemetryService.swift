import Foundation
import os

/// Sink abstraction so every emission funnels through one seam. The production
/// implementation (`TelemetryDeckSink`) is the *only* file that imports the
/// TelemetryDeck SDK; tests inject a spy. One method per signal keeps the
/// content-free boundary explicit — call sites can only pass enums / durations /
/// bools / short ids, never free text from transcripts, clipboard, or OCR.
protocol TelemetrySink {
    // diagnostics
    func engineSelected(model: String, engine: String, osMajor: String, locale: String)
    func modelDownload(model: String, result: String, durationMs: Int, source: String, errorKind: String?)
    func engineColdStart(engine: String, firstBufferMs: Int, scoWatchdogFired: Bool)
    func transcribeError(engine: String, errorKind: String)
    func permissionState(mic: String, speech: String, accessibility: String, screenCapture: String)
    func eventTapFailed()
    // adoption
    func featureUsed(_ feature: String)
    func personaInvoked(persona: String, injectionStrategy: String)
    func hotkeyAction(_ action: String)
    func activationFirstTranscription()
}

/// The single gate for all telemetry emission. Every call site talks to this
/// wrapper, never to the SDK directly, so the opt-out toggle is enforced in
/// exactly one place and swapping providers touches one file.
final class TelemetryService {
    static let shared = TelemetryService()

    /// Shared UserDefaults key (also read by the Sentry sibling task). Default `true`.
    static let enabledKey = "telemetryEnabled"

    private let log = Logger(subsystem: "io.keymic.app", category: "Telemetry")
    private let defaults: UserDefaults

    private(set) var isEnabled: Bool
    private var sink: TelemetrySink?
    private var started = false

    /// Builds the production sink lazily. Left as a no-op provider here so this
    /// file never imports TelemetryDeck (and stays compilable by the standalone
    /// swiftc test runners). The app wires it to `TelemetryDeckSink.makeIfConfigured`
    /// during launch (see the AppDelegate wiring step).
    var sinkProvider: () -> TelemetrySink? = { nil }

    init(sink: TelemetrySink? = nil,
         enabled: Bool? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = enabled ?? (defaults.object(forKey: TelemetryService.enabledKey) as? Bool ?? true)
        self.sink = sink
        self.started = sink != nil
    }

    /// Called once at launch. Initializes the production sink only when telemetry
    /// is enabled; otherwise nothing is created and no signal can be sent.
    func startIfEnabled() {
        guard isEnabled, !started else { return }
        sink = sinkProvider()
        started = sink != nil
    }

    /// Runtime toggle from the Settings consent switch. Turning off makes every
    /// emit method short-circuit immediately (the SDK has no mid-session stop).
    func setEnabled(_ on: Bool) {
        isEnabled = on
        defaults.set(on, forKey: TelemetryService.enabledKey)
        if on { startIfEnabled() }
    }

    // MARK: - Emit surface (each no-ops when disabled)

    func engineSelected(model: String, engine: String, osMajor: String, locale: String) {
        guard isEnabled, let sink else { return }
        sink.engineSelected(model: model, engine: engine, osMajor: osMajor, locale: locale)
    }

    func modelDownload(model: String, result: String, durationMs: Int, source: String, errorKind: String? = nil) {
        guard isEnabled, let sink else { return }
        sink.modelDownload(model: model, result: result, durationMs: durationMs, source: source, errorKind: errorKind)
    }

    func engineColdStart(engine: String, firstBufferMs: Int, scoWatchdogFired: Bool) {
        guard isEnabled, let sink else { return }
        sink.engineColdStart(engine: engine, firstBufferMs: firstBufferMs, scoWatchdogFired: scoWatchdogFired)
    }

    func transcribeError(engine: String, errorKind: String) {
        guard isEnabled, let sink else { return }
        sink.transcribeError(engine: engine, errorKind: errorKind)
    }

    func permissionState(mic: String, speech: String, accessibility: String, screenCapture: String) {
        guard isEnabled, let sink else { return }
        sink.permissionState(mic: mic, speech: speech, accessibility: accessibility, screenCapture: screenCapture)
    }

    func eventTapFailed() {
        guard isEnabled, let sink else { return }
        sink.eventTapFailed()
    }

    func featureUsed(_ feature: String) {
        guard isEnabled, let sink else { return }
        sink.featureUsed(feature)
    }

    func personaInvoked(persona: String, injectionStrategy: String) {
        guard isEnabled, let sink else { return }
        sink.personaInvoked(persona: persona, injectionStrategy: injectionStrategy)
    }

    func hotkeyAction(_ action: String) {
        guard isEnabled, let sink else { return }
        sink.hotkeyAction(action)
    }

    func activationFirstTranscription() {
        guard isEnabled, let sink else { return }
        sink.activationFirstTranscription()
    }
}
