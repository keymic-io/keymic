import Foundation
import os

/// Lightweight, main-thread timing tracer for diagnosing **slow clipboard-panel opens**.
///
/// Each stage boundary logs the elapsed time since `begin()` and the delta since the
/// previous mark, so you can see which step dominates the open latency. The whole open
/// is also wrapped in an `OSSignposter` interval (`panel-open`) for Instruments.
///
/// Watch it live in Terminal:
/// ```
/// log stream --predicate 'subsystem == "io.keymic.app" && category == "ClipboardOpen"' --info
/// ```
/// or in Console.app, filter by category `ClipboardOpen`.
///
/// All calls are no-ops unless a trace is active (`begin` was called), so the marks
/// sprinkled across the open path are safe even when the panel is created out-of-band
/// (e.g. by `isPanelVisible` or `preferencesChanged`).
///
/// Not actor-isolated on purpose: every call site is on the main thread (the open
/// path and SwiftUI `onAppear`/`onChange` callbacks), and keeping it un-isolated
/// avoids spurious actor-isolation warnings at those SwiftUI call sites.
final class ClipboardOpenTrace {
    static let shared = ClipboardOpenTrace()

    private let logger = Logger(subsystem: "io.keymic.app", category: "ClipboardOpen")
    private let signposter = OSSignposter(subsystem: "io.keymic.app", category: "ClipboardOpen")
    private var intervalState: OSSignpostIntervalState?

    private var start: CFAbsoluteTime = 0
    private var last: CFAbsoluteTime = 0
    private var active = false

    private init() {}

    /// Begin a new open trace, resetting the clock. Safe to call again mid-flight.
    func begin(reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        start = now
        last = now
        active = true
        intervalState = signposter.beginInterval("panel-open")
        logger.debug("[clip-open] ▶︎ begin (\(reason, privacy: .public))")
    }

    /// Record a stage boundary: elapsed since `begin` and delta since the previous mark.
    func mark(_ label: String) {
        guard active else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = (now - start) * 1000
        let delta = (now - last) * 1000
        last = now
        logger.debug(
            "[clip-open] \(label, privacy: .public) +\(elapsed, format: .fixed(precision: 1))ms (Δ\(delta, format: .fixed(precision: 1))ms)"
        )
    }

    /// Close the trace and print the total. Repeated calls are no-ops (first one wins),
    /// so both the first-open `onAppear` path and the reuse `onChange(requestID)` path
    /// can safely call it.
    func end(_ label: String = "shown") {
        guard active else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = (now - start) * 1000
        if let intervalState {
            signposter.endInterval("panel-open", intervalState)
        }
        logger.debug("[clip-open] ✓ \(label, privacy: .public) — total \(elapsed, format: .fixed(precision: 1))ms")
        active = false
        intervalState = nil
    }
}
