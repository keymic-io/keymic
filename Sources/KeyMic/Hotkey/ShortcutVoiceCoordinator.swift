import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "ShortcutVoiceCoordinator")

// MARK: - Protocols (declared in this file per 04-CONTEXT.md MUST-NOT-touch list)

/// Test-injectable overlay seam. `OverlayPanel` (Sources/KeyMic/OverlayPanel.swift)
/// satisfies this protocol via the empty conformance extension below — zero
/// behavioral change to OverlayPanel. Tests substitute a `MockOverlay` that
/// records every call for assertion.
///
/// Per 04-PATTERNS.md (Test seam) the protocol lives ALONGSIDE the
/// coordinator (not in OverlayPanel.swift) so OverlayPanel.swift stays on
/// the MUST-NOT-touch list (04-CONTEXT.md `<canonical_refs>`).
protocol OverlayDisplaying: AnyObject {
    func show(text: String)
    func updateText(_ text: String)
    func dismiss()
}

extension OverlayPanel: OverlayDisplaying {}

/// Test-injectable LLM seam. `LLMRefiner` (Sources/KeyMic/LLMRefiner.swift)
/// satisfies this protocol via the empty conformance extension below — zero
/// behavioral change to LLMRefiner. Tests substitute a `MockRefiner` whose
/// `refine` captures the completion closure so the test can manually fire
/// late results (verifying the `currentRequestToken` discard path of
/// Plan 04-04).
///
/// The `refine` signature MUST match LLMRefiner.swift:37-42 EXACTLY — the
/// PRD's fictional `refine(text:persona:context:completion:)` does NOT
/// compile (carried as STATE.md API-correction note for Phase 4).
protocol LLMRefining: AnyObject {
    var isReady: Bool { get }
    func refine(
        _ userText: String,
        systemPrompt: String,
        temperature: Double,
        completion: @escaping (Result<String, Error>) -> Void
    )
    func cancel()
}

extension LLMRefiner: LLMRefining {}

// MARK: - PlaceholderOverlay (used before bootstrap)

/// Stub `OverlayDisplaying` installed when the eager `.shared` singleton is
/// constructed BEFORE `AppDelegate.applicationDidFinishLaunching` runs.
/// Replaced via `ShortcutVoiceCoordinator.bootstrap(overlayPanel:)` with the
/// real `OverlayPanel`. Each method logs a warning so any accidental
/// pre-bootstrap call is loud in the log stream.
///
/// Production never observes the placeholder because Plan 04-05 wires
/// `bootstrap(overlayPanel:)` into `applicationDidFinishLaunching` BEFORE
/// any voice trigger can fire. Tests bypass the placeholder entirely by
/// constructing the coordinator via the DI init.
fileprivate final class PlaceholderOverlay: OverlayDisplaying {
    func show(text: String) {
        logger.warning("OverlayDisplaying called before bootstrap — show(text:) ignored")
    }
    func updateText(_ text: String) {
        logger.warning("OverlayDisplaying called before bootstrap — updateText ignored")
    }
    func dismiss() {
        logger.warning("OverlayDisplaying called before bootstrap — dismiss ignored")
    }
}

// MARK: - ShortcutVoiceCoordinator

/// `@MainActor` voice-mode state machine — the SINGLE owner of
/// `pendingVoiceMode` / `activeVoiceMode` / `armTimer` / `currentRequestToken`.
/// Extracted from `AppDelegate` flat fields (PRD's original placement) per
/// the BLOCKER mitigation tracked in `.planning/STATE.md` — every reset path
/// flows through `resetAllState(reason:)` so a normal voice dictation can
/// never be mis-routed into a shortcut import.
///
/// All public methods inherit `@MainActor` isolation: compile-time guarantee
/// that the caller is on the main thread. Stronger than Phase 3's
/// `ShortcutYAMLImporter` runtime `dispatchPrecondition(condition:.onQueue(.main))`
/// because all coordinator callsites are already main-thread (AppKit,
/// AppDelegate lifecycle, `KeyMonitor` callbacks dispatched via
/// `DispatchQueue.main.async`).
///
/// Plan boundary: `handleTranscription(_:)` is intentionally OMITTED in
/// Plan 04-03. Plan 04-04 adds it — that method requires Plan 04-01's
/// importer hook (`recordLLMFailure`) + the token-discard logic. Keeping
/// 04-03 focused on the state-machine primitives means this file lands as
/// ~210 LOC of a single new file with no other source changes.
@MainActor
final class ShortcutVoiceCoordinator {
    /// THE single production instance per 04-CONTEXT.md D-A-1.
    ///
    /// (a) This IS the production instance — there is no parallel
    ///     `lazy var coordinator` on `AppDelegate`. The wiring change in
    ///     Plan 04-05 routes every voice-flow call through `.shared`.
    /// (b) `AppDelegate.applicationDidFinishLaunching` calls
    ///     `ShortcutVoiceCoordinator.bootstrap(overlayPanel:)` exactly once
    ///     BEFORE any voice flow runs — the `PlaceholderOverlay` is replaced
    ///     by the real `OverlayPanel` instance.
    /// (c) Tests bypass `.shared` entirely by calling the DI-flavoured
    ///     `init(importer:overlayPanel:refiner:armDuration:)` directly — no
    ///     shared global state pollution across test runs.
    /// (d) Calling `bootstrap` twice is idempotent: the later call replaces
    ///     the overlay reference (used only if a future Phase swaps panels).
    static let shared = ShortcutVoiceCoordinator()

    // MARK: - Nested types

    enum VoiceMode: Equatable {
        case normal
        case shortcutConfig
    }

    /// 7-case cancel reason. Strict scope separation per 04-CONTEXT.md D-F-1:
    ///
    /// - Used by `cancel(reason:)` — clears arm state ONLY:
    ///   `.userEscape`, `.timeout`, `.settingsReload`, `.captureStarted`
    /// - Used by `resetAllState(reason:)` — clears arm + active + LLM state:
    ///   `.appQuit`, `.secureInputEnter`, `.cancelRecording`
    ///
    /// `.keyMonitorReset` was considered and DROPPED — covered by the
    /// `onTriggerInterrupted` → `cancelRecording` chain per
    /// 04-RESEARCH.md §5 constraint #7.
    enum CancelReason {
        case userEscape
        case timeout
        case settingsReload
        case captureStarted
        case appQuit
        case secureInputEnter
        case cancelRecording
    }

    // MARK: - State (all private(set) per COORD-02; external readers see modes only via the getter)

    private(set) var pendingVoiceMode: VoiceMode = .normal
    private(set) var activeVoiceMode: VoiceMode = .normal
    private var armTimer: DispatchSourceTimer?
    private var currentRequestToken: UUID?

    // MARK: - Dependencies

    private let importer: ShortcutYAMLImporter
    private var overlayPanel: OverlayDisplaying  // var so `configure(overlayPanel:)` can replace placeholder
    private let refiner: LLMRefining
    private let armDuration: TimeInterval

    // MARK: - Inits

    /// Production init used by `.shared`. Resolves dependencies to defaults
    /// (`ShortcutYAMLImporter.shared`, `LLMRefiner.shared`, 30-second arm
    /// duration) and installs a `PlaceholderOverlay` until
    /// `bootstrap(overlayPanel:)` replaces it.
    ///
    /// `private` so the only legitimate `.init()` consumer is the
    /// `.shared` initialiser line above. Production code must access the
    /// coordinator via `.shared`; tests use the DI init below.
    private init() {
        self.importer = .shared
        self.overlayPanel = PlaceholderOverlay()
        self.refiner = LLMRefiner.shared
        self.armDuration = 30.0
    }

    /// Test-DI init. ALL four parameters are required (no defaults) so the
    /// test harness is forced to be explicit about every dependency — no
    /// accidental leakage of `.shared` singletons into test state.
    ///
    /// Used ONLY by `Tests/ShortcutVoiceCoordinatorTests.swift` (Plan 04-06).
    /// Production accesses the coordinator via `.shared`.
    init(
        importer: ShortcutYAMLImporter,
        overlayPanel: OverlayDisplaying,
        refiner: LLMRefining,
        armDuration: TimeInterval = 30.0
    ) {
        self.importer = importer
        self.overlayPanel = overlayPanel
        self.refiner = refiner
        self.armDuration = armDuration
    }

    // MARK: - Bootstrap

    /// Production lifecycle entry — called by
    /// `AppDelegate.applicationDidFinishLaunching` exactly ONCE (Plan 04-05),
    /// replacing the `PlaceholderOverlay` with the real `OverlayPanel`.
    /// Idempotent: a second call replaces the overlay reference.
    static func bootstrap(overlayPanel: OverlayDisplaying) {
        ShortcutVoiceCoordinator.shared.configure(overlayPanel: overlayPanel)
    }

    /// Internal-only overlay mutator. `private` so NO outside caller can
    /// swap the overlay mid-flow — only `static bootstrap(overlayPanel:)`
    /// can reach it. Idempotent.
    private func configure(overlayPanel: OverlayDisplaying) {
        self.overlayPanel = overlayPanel
        logger.info("ShortcutVoiceCoordinator configured with overlay")
    }

    // MARK: - State machine

    /// Enter armed state per COORD-03. Shows the overlay hint, sets
    /// `pendingVoiceMode = .shortcutConfig`, and schedules a one-shot
    /// `DispatchSourceTimer` that fires `cancel(reason: .timeout)` after
    /// `armDuration` seconds (30s production; ~0.1s in tests).
    ///
    /// If already armed, logs a warning and REPLACES the prior arm: the
    /// existing timer is cancelled before a new one is scheduled
    /// (04-CONTEXT.md `<deferred>` recommendation (a) — replace + reset).
    func arm() {
        if pendingVoiceMode == .shortcutConfig {
            logger.warning("arm() called while already armed — replacing previous arm")
            armTimer?.cancel()
            armTimer = nil
        }

        pendingVoiceMode = .shortcutConfig
        overlayPanel.show(text: "Speak your shortcut (30s)…")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + armDuration)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Race guard per 04-RESEARCH Pitfall §3: a concurrent
            // cancel()/beforeTriggerDown() may have already cleared the
            // pending mode between timer fire and handler execution.
            guard self.pendingVoiceMode == .shortcutConfig else { return }
            self.cancel(reason: .timeout)
        }
        armTimer = timer
        timer.resume()

        logger.info("arm — armDuration=\(self.armDuration, privacy: .public)s")
    }

    /// Clear arm state ONLY per D-F-1 (`pendingVoiceMode`, `armTimer`,
    /// overlay if showing arm hint). Does NOT touch `activeVoiceMode`,
    /// `currentRequestToken`, or call `refiner.cancel()` — those belong
    /// to `resetAllState(reason:)`.
    func cancel(reason: CancelReason) {
        // Always pair cancel + nil per 04-RESEARCH Anti-Patterns.
        armTimer?.cancel()
        armTimer = nil
        pendingVoiceMode = .normal
        overlayPanel.dismiss()
        logger.info("cancel reason=\(String(describing: reason), privacy: .public)")
    }

    /// Hard reset per COORD-09: clears arm state + `activeVoiceMode` +
    /// in-flight LLM call + token. Used by `applicationWillTerminate`,
    /// secure-input enter, `cancelRecording`. Composes `cancel(reason:)`
    /// for the arm-clearing half so the two methods stay in lockstep.
    func resetAllState(reason: CancelReason) {
        cancel(reason: reason)
        activeVoiceMode = .normal
        // Hard-cancel any in-flight LLM call (URLSession task.cancel()).
        // Per LLMRefiner.swift:99-102 the completion still fires with
        // URLError(.cancelled); the token-discard below is the source
        // of truth for "did this request belong to the current arm cycle?"
        refiner.cancel()
        currentRequestToken = nil
        logger.info("resetAllState reason=\(String(describing: reason), privacy: .public)")
    }

    /// APP-02 light reset — clears `activeVoiceMode` + `currentRequestToken`
    /// only. Does NOT touch `pendingVoiceMode`, `armTimer`, or overlay.
    /// Used by `finishTranscription` empty-transcript early-return: the
    /// user dictated nothing; just zero out active so the next press
    /// starts clean.
    func resetActiveMode() {
        activeVoiceMode = .normal
        currentRequestToken = nil
        logger.info("resetActiveMode")
    }

    /// COORD-05 transition: consume `pendingVoiceMode` into `activeVoiceMode`
    /// and cancel the arm timer (the trigger arrived within the arm
    /// window). Called from `AppDelegate.triggerDown` BEFORE recording
    /// starts (Plan 04-05 wires this).
    func beforeTriggerDown() {
        activeVoiceMode = pendingVoiceMode
        pendingVoiceMode = .normal
        armTimer?.cancel()
        armTimer = nil
        logger.info("beforeTriggerDown — activeVoiceMode=\(String(describing: self.activeVoiceMode), privacy: .public)")
    }
}
