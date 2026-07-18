import Foundation

/// Coarse, content-free error categories that may be captured to the crash-reporting
/// backend. Only the case name ever leaves the device — never a message string derived
/// from user data (transcripts, clipboard, keys, OCR, secrets).
enum ErrorKind: String, CaseIterable {
    case llm
    case modelDownload
    case configSync
    case engineStart
}

/// The seam every call site talks to instead of the Sentry SDK, so the consent gate is
/// enforced in exactly one place and the SDK stays behind a single import boundary. The
/// production implementation (`SentryCrashSink`) is the *only* file that imports Sentry;
/// tests inject a spy. Both methods are content-free by construction.
protocol CrashReportingSink: AnyObject {
    /// Capture a coarse error category plus the originating source file id. No thrown
    /// error message, no user content.
    func capture(_ kind: ErrorKind, file: String)
    /// Shut the SDK down so nothing further is sent after consent is withdrawn.
    func shutdown()
}

/// The mutable surface of a crash/error event that the privacy scrub touches. Sentry's
/// `Event` is adapted to this in `SentryCrashSink` (the sole SDK site), so the scrub
/// *decisions* are unit-testable without linking Sentry.
protocol ScrubbableEvent: AnyObject {
    /// The event's formatted message string, or nil when absent.
    var scrubMessage: String? { get set }
    /// True while the event still carries any breadcrumbs.
    var scrubHasBreadcrumbs: Bool { get }
    /// True while the event still carries any `extra` payload.
    var scrubHasExtra: Bool { get }
    /// Drop every breadcrumb. We never rely on breadcrumbs and they are the highest
    /// inadvertent-content-leak surface, so they are always removed.
    func scrubDropBreadcrumbs()
    /// Drop the whole `extra` bag. We never set `extra` ourselves, so anything present
    /// is foreign and removed.
    func scrubDropExtra()
}

/// Pure, allowlist-based privacy scrub — the privacy core of the crash layer. It keeps
/// only known-safe fields and blanks/drops anything that could carry user content. Kept
/// free of any SDK import so the standalone `swiftc` test runners can exercise it.
enum CrashScrub {
    /// The fixed, content-free message string attached to a captured `ErrorKind`.
    static func syntheticMessage(for kind: ErrorKind) -> String {
        "KeyMic error: \(kind.rawValue)"
    }

    /// The only message strings our own captures legitimately produce. Anything else is
    /// treated as potentially content-bearing and blanked.
    static let allowedMessages: Set<String> = Set(ErrorKind.allCases.map { syntheticMessage(for: $0) })

    /// A `nil`/absent message is safe; otherwise it must be one of our fixed strings.
    static func isMessageAllowed(_ message: String?) -> Bool {
        guard let message else { return true }
        return allowedMessages.contains(message)
    }

    /// Scrub an event in place and return it. Never returns an event that still carries
    /// breadcrumbs, foreign `extra`, or a message outside the fixed allowlist.
    @discardableResult
    static func scrub<E: ScrubbableEvent>(_ event: E) -> E {
        if !isMessageAllowed(event.scrubMessage) {
            event.scrubMessage = nil
        }
        event.scrubDropBreadcrumbs()
        event.scrubDropExtra()
        return event
    }
}

/// The consent gate for all crash/error emission. Reads the *shared* `telemetryEnabled`
/// key (owned by `TelemetryService`; not a new key) and no-ops every capture while
/// disabled. Sentry-free so the gate is testable by the standalone runners; the app wires
/// its `sinkProvider` to the Sentry-backed sink at launch.
final class CrashReportingGate {
    /// Shared consent key — the same one `TelemetryService` owns. Default `true`.
    static let enabledKey = "telemetryEnabled"

    /// Guards `_isEnabled` / `sink` / `started`. `capture` may run on background queues
    /// (download / request completions) while `setEnabled` mutates on the main thread, so
    /// every access to that shared state goes through this lock.
    private let lock = NSLock()
    private var _isEnabled: Bool
    private var sink: CrashReportingSink?
    private var started: Bool
    private let defaults: UserDefaults

    /// Builds the production sink lazily. Left as a no-op provider here so this file never
    /// imports Sentry (and stays compilable by the standalone `swiftc` test runners). The
    /// app wires it to `SentryCrashSink.makeIfConfigured` during launch.
    var sinkProvider: () -> CrashReportingSink? = { nil }

    init(sink: CrashReportingSink? = nil,
         enabled: Bool? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self._isEnabled = enabled ?? (defaults.object(forKey: CrashReportingGate.enabledKey) as? Bool ?? true)
        self.sink = sink
        self.started = sink != nil
    }

    /// Thread-safe snapshot of the consent flag.
    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isEnabled
    }

    /// Called once at launch. Initializes the production sink only when enabled; otherwise
    /// nothing is created and no event can be sent.
    func startIfEnabled() {
        lock.lock(); defer { lock.unlock() }
        guard _isEnabled, !started else { return }
        sink = sinkProvider()
        started = sink != nil
    }

    /// Runtime toggle from the shared Settings consent switch. Turning off shuts the SDK
    /// down and drops the sink so `capture` no-ops immediately.
    ///
    /// Note: `SentrySDK.close()` is effectively terminal for the current process session.
    /// Turning the toggle back on rebuilds the sink here, but a fully clean SDK
    /// re-initialization is only guaranteed on the next app launch.
    func setEnabled(_ on: Bool) {
        lock.lock()
        _isEnabled = on
        if !on {
            sink?.shutdown()
            sink = nil
            started = false
        }
        lock.unlock()
        defaults.set(on, forKey: CrashReportingGate.enabledKey)
        if on { startIfEnabled() }
    }

    /// Capture a coarse error category. No-ops when disabled.
    func capture(_ kind: ErrorKind, file: String) {
        liveSink()?.capture(kind, file: file)
    }

    /// The active sink, or `nil` when disabled. Captured under the lock and used outside it
    /// so SDK calls never run while the lock is held.
    private func liveSink() -> CrashReportingSink? {
        lock.lock(); defer { lock.unlock() }
        return _isEnabled ? sink : nil
    }
}
