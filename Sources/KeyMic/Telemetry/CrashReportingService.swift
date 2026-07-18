import Foundation
import os
import Sentry

/// The single entry point call sites use for crash/error reporting. Wraps the Sentry-free
/// `CrashReportingGate` (consent + threading) and wires it to the Sentry-backed sink. Every
/// call site talks to this — never to `SentrySDK` directly — so the opt-out toggle and the
/// privacy scrub live in exactly one place.
final class CrashReportingService {
    static let shared = CrashReportingService()

    private let gate: CrashReportingGate

    private init() {
        gate = CrashReportingGate()
        gate.sinkProvider = { SentryCrashSink.makeIfConfigured() }
    }

    /// Thread-safe snapshot of the shared consent flag.
    var isEnabled: Bool { gate.isEnabled }

    /// Called once at launch. Initializes Sentry only when the shared `telemetryEnabled`
    /// flag is true and a `SentryDSN` is present; otherwise no-op.
    func startIfEnabled() { gate.startIfEnabled() }

    /// Runtime toggle driven by the shared Settings consent switch (owned by child-1).
    /// Turning off calls `SentrySDK.close()`; re-enable fully re-initializes next launch.
    func setEnabled(_ on: Bool) { gate.setEnabled(on) }

    /// Capture a coarse, content-free error category at a curated `catch` site. No-ops when
    /// disabled. Only the `ErrorKind` case name and the source file id are attached.
    func capture(_ kind: ErrorKind, file: StaticString = #fileID) {
        gate.capture(kind, file: "\(file)")
    }
}

/// The one and only `import Sentry` site. Everything else in the app talks to
/// `CrashReportingService` / `CrashReportingSink`, so the SDK can be swapped or removed by
/// touching this file alone. Owns SDK init, the privacy hardening options, the `beforeSend`
/// scrub hook, and the content-free `capture`.
final class SentryCrashSink: CrashReportingSink {
    private static let dsnKey = "SentryDSN"
    private static let log = Logger(subsystem: "io.keymic.app", category: "Telemetry")

    /// Reads the DSN from `Info.plist`, starts the SDK with privacy hardening, and returns a
    /// sink. Returns `nil` when no DSN is configured (expected during local dev), so a missing
    /// key never crashes and no SDK is initialized — mirrors `TelemetryDeckSink.makeIfConfigured`.
    static func makeIfConfigured() -> SentryCrashSink? {
        guard let dsn = Bundle.main.object(forInfoDictionaryKey: dsnKey) as? String,
              !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.info("Sentry DSN missing; crash reporting SDK not initialized")
            return nil
        }
        SentrySDK.start { options in
            options.dsn = dsn
            // Privacy hardening (parent red-lines): no PII, no IP, crashes only.
            options.sendDefaultPii = false           // also suppresses auto IP capture
            options.enableCrashHandler = true        // automatic crash capture (default)
            options.tracesSampleRate = 0             // performance tracing OFF (deferred)
            options.attachStacktrace = true
            #if DEBUG
            options.environment = "debug"            // keep Debug events out of production stream
            #else
            options.environment = "production"
            #endif
            // The privacy core: allowlist scrub on every outgoing event.
            options.beforeSend = { event in
                CrashScrub.scrub(SentryEventBox(event)).event
            }
        }
        return SentryCrashSink()
    }

    /// Capture a coarse error category. Attaches only the `ErrorKind` and file id as tags —
    /// never a thrown-error message that could embed user content.
    func capture(_ kind: ErrorKind, file: String) {
        let error = NSError(
            domain: "io.keymic.app.crash",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: CrashScrub.syntheticMessage(for: kind)]
        )
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: kind.rawValue, key: "error_kind")
            scope.setTag(value: file, key: "capture_site")
        }
    }

    func shutdown() {
        SentrySDK.close()
    }
}

/// Adapts Sentry's `Event` to the Sentry-free `ScrubbableEvent` protocol so the pure
/// `CrashScrub` logic (unit-tested without linking Sentry) can operate on real events.
private final class SentryEventBox: ScrubbableEvent {
    let event: Event

    init(_ event: Event) { self.event = event }

    var scrubMessage: String? {
        get { event.message?.formatted }
        set {
            if let newValue {
                event.message = SentryMessage(formatted: newValue)
            } else {
                event.message = nil
            }
        }
    }

    var scrubHasBreadcrumbs: Bool { !(event.breadcrumbs?.isEmpty ?? true) }
    var scrubHasExtra: Bool { !(event.extra?.isEmpty ?? true) }
    func scrubDropBreadcrumbs() { event.breadcrumbs = nil }
    func scrubDropExtra() { event.extra = nil }
}
