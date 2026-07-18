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
    /// Shut the underlying SDK down so no further session tracking or queued sends
    /// happen after the consent toggle is turned off.
    func terminate()
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

    /// Guards `_isEnabled` / `sink` / `started`. Emit methods run on background
    /// queues (model-download completions) while `setEnabled` mutates on the main
    /// thread, so every access to that shared state must go through this lock.
    private let lock = NSLock()
    private var _isEnabled: Bool
    private var sink: TelemetrySink?
    private var started = false

    /// Thread-safe snapshot of the consent flag. Read by the first-run notice /
    /// Settings toggle on the main thread.
    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isEnabled
    }

    /// Builds the production sink lazily. Left as a no-op provider here so this
    /// file never imports TelemetryDeck (and stays compilable by the standalone
    /// swiftc test runners). The app wires it to `TelemetryDeckSink.makeIfConfigured`
    /// during launch (see the AppDelegate wiring step).
    var sinkProvider: () -> TelemetrySink? = { nil }

    init(sink: TelemetrySink? = nil,
         enabled: Bool? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self._isEnabled = enabled ?? (defaults.object(forKey: TelemetryService.enabledKey) as? Bool ?? true)
        self.sink = sink
        self.started = sink != nil
    }

    /// Called once at launch. Initializes the production sink only when telemetry
    /// is enabled; otherwise nothing is created and no signal can be sent.
    func startIfEnabled() {
        lock.lock(); defer { lock.unlock() }
        guard _isEnabled, !started else { return }
        sink = sinkProvider()
        started = sink != nil
    }

    /// Runtime toggle from the Settings consent switch. Turning off terminates the
    /// SDK (stops session tracking + queued sends) and drops the sink so a later
    /// turn-on re-runs `startIfEnabled()` and reinitializes cleanly.
    func setEnabled(_ on: Bool) {
        lock.lock()
        _isEnabled = on
        if !on {
            sink?.terminate()
            sink = nil
            started = false
        }
        lock.unlock()
        defaults.set(on, forKey: TelemetryService.enabledKey)
        if on { startIfEnabled() }
    }

    /// The active sink, or `nil` when disabled. Captured under the lock and used
    /// outside it so SDK calls never run while the lock is held.
    private func liveSink() -> TelemetrySink? {
        lock.lock(); defer { lock.unlock() }
        return _isEnabled ? sink : nil
    }

    // MARK: - Emit surface (each no-ops when disabled)

    func engineSelected(model: String, engine: String, osMajor: String, locale: String) {
        liveSink()?.engineSelected(model: model, engine: engine, osMajor: osMajor, locale: locale)
    }

    func modelDownload(model: String, result: String, durationMs: Int, source: String, errorKind: String? = nil) {
        liveSink()?.modelDownload(model: model, result: result, durationMs: durationMs, source: source, errorKind: errorKind)
    }

    func engineColdStart(engine: String, firstBufferMs: Int, scoWatchdogFired: Bool) {
        liveSink()?.engineColdStart(engine: engine, firstBufferMs: firstBufferMs, scoWatchdogFired: scoWatchdogFired)
    }

    func transcribeError(engine: String, errorKind: String) {
        liveSink()?.transcribeError(engine: engine, errorKind: errorKind)
    }

    func permissionState(mic: String, speech: String, accessibility: String, screenCapture: String) {
        liveSink()?.permissionState(mic: mic, speech: speech, accessibility: accessibility, screenCapture: screenCapture)
    }

    func eventTapFailed() {
        liveSink()?.eventTapFailed()
    }

    func featureUsed(_ feature: String) {
        liveSink()?.featureUsed(feature)
    }

    func personaInvoked(persona: String, injectionStrategy: String) {
        liveSink()?.personaInvoked(persona: persona, injectionStrategy: injectionStrategy)
    }

    func hotkeyAction(_ action: String) {
        liveSink()?.hotkeyAction(action)
    }

    func activationFirstTranscription() {
        liveSink()?.activationFirstTranscription()
    }
}
