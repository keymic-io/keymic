import Foundation
import AppKit
import CoreGraphics

// Plan 04-06 Task 1 — ShortcutVoiceCoordinator standalone @main runner.
//
// 9 tests covering ROADMAP Phase 4 success criteria 1, 2, 3, 5:
//   1. testArmShowsOverlayHintAndSetsPendingMode (SC 1)
//   2. testBeforeTriggerDownConsumesPendingIntoActive (SC 1)
//   3. testArmTimeoutFires (SC 2)
//   4. testCancelClearsPendingOnly (SC 3 / D-F-1)
//   5. testResetAllStateClearsBothModes (SC 3)
//   6. testHandleTranscriptionHappyPath (SC 1)
//   7. testHandleTranscriptionLLMFailure (SC 5 partial)
//   8. testTokenDiscardOnStaleCompletion (SC 5 — BLOCKER closure)
//   9. testEmptyTranscriptResetsActiveMode (APP-02 surface)
//
// EVERY test constructs a fresh `ShortcutVoiceCoordinator` via the
// DI init — NO test touches the production singleton. The
// singleton-as-truth invariant from Plan 04-03 forbids singleton
// access in tests; verifier asserts the literal "Coordinator dot
// shared" appears zero times in this file (DI-only).
//
// Mocks (MockOverlay, MockRefiner) are declared fileprivate inside
// this runner so they cannot leak into production targets.

@main
struct ShortcutVoiceCoordinatorTestRunner {
    @MainActor
    static func main() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-coordinator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try testArmShowsOverlayHintAndSetsPendingMode(tmp: tmp)
        try testBeforeTriggerDownConsumesPendingIntoActive(tmp: tmp)
        try testArmTimeoutFires(tmp: tmp)
        try testCancelClearsPendingOnly(tmp: tmp)
        try testResetAllStateClearsBothModes(tmp: tmp)
        try testHandleTranscriptionHappyPath(tmp: tmp)
        try testHandleTranscriptionLLMFailure(tmp: tmp)
        try testTokenDiscardOnStaleCompletion(tmp: tmp)
        try testEmptyTranscriptResetsActiveMode(tmp: tmp)

        print("ShortcutVoiceCoordinatorTests passed")
    }

    // MARK: - DI helper

    /// Per-test isolation bundle — fresh UserDefaults suite, audit URL,
    /// HotkeyBindingsStore, ShortcutAuditLog, ShortcutYAMLImporter,
    /// MockOverlay, MockRefiner, and the coordinator under test.
    ///
    /// `armDuration: 0.1` (100ms) keeps the timer tests under 200ms wall
    /// clock per RESEARCH §"30-second timer".
    @MainActor
    private static func makeFixture(tmp: URL, name: String, armDuration: TimeInterval = 0.1)
        -> (coord: ShortcutVoiceCoordinator,
            importer: ShortcutYAMLImporter,
            store: HotkeyBindingsStore,
            overlay: MockOverlay,
            refiner: MockRefiner,
            auditURL: URL,
            suiteName: String,
            defaults: UserDefaults)
    {
        let suiteName = "test.ShortcutVoiceCoordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let auditURL = tmp.appendingPathComponent("\(name)-\(UUID().uuidString).log")
        let auditLog = ShortcutAuditLog(logURL: auditURL, maxBytes: 5 * 1024 * 1024)
        let store = HotkeyBindingsStore(defaults: defaults)
        let importer = ShortcutYAMLImporter(
            store: store,
            registry: HotkeyRegistry.shared,
            auditLog: auditLog,
            userDefaults: defaults
        )
        let overlay = MockOverlay()
        let refiner = MockRefiner()
        let coord = ShortcutVoiceCoordinator(
            importer: importer,
            overlayPanel: overlay,
            refiner: refiner,
            armDuration: armDuration
        )
        return (coord, importer, store, overlay, refiner, auditURL, suiteName, defaults)
    }

    // MARK: - Tests

    /// SC 1: arm() shows the localized hint AND sets pendingVoiceMode.
    @MainActor
    private static func testArmShowsOverlayHintAndSetsPendingMode(tmp: URL) throws {
        let f = makeFixture(tmp: tmp, name: "arm-shows-hint")
        defer { f.defaults.removePersistentDomain(forName: f.suiteName) }

        expect(f.coord.pendingVoiceMode == .normal, "pending starts as .normal")
        expect(f.coord.activeVoiceMode == .normal, "active starts as .normal")

        f.coord.arm()

        expect(f.coord.pendingVoiceMode == .shortcutConfig,
               "arm() sets pendingVoiceMode = .shortcutConfig (got \(f.coord.pendingVoiceMode))")
        expect(f.coord.activeVoiceMode == .normal,
               "arm() leaves activeVoiceMode unchanged (got \(f.coord.activeVoiceMode))")
        expect(f.overlay.showCalls.last == "Speak your shortcut (30s)…",
               "overlay arm hint matches D-B-1 literal (got '\(f.overlay.showCalls.last ?? "<nil>")')")

        // Clean up the live armTimer before exiting (defensive — avoids the
        // timer firing during a sibling test's setup).
        f.coord.cancel(reason: .userEscape)

        print("testArmShowsOverlayHintAndSetsPendingMode: ok")
    }

    /// SC 1: beforeTriggerDown() transitions pending → active in one step.
    @MainActor
    private static func testBeforeTriggerDownConsumesPendingIntoActive(tmp: URL) throws {
        let f = makeFixture(tmp: tmp, name: "trigger-down-consume")
        defer { f.defaults.removePersistentDomain(forName: f.suiteName) }

        f.coord.arm()
        expect(f.coord.pendingVoiceMode == .shortcutConfig, "pending == .shortcutConfig after arm")

        f.coord.beforeTriggerDown()

        expect(f.coord.activeVoiceMode == .shortcutConfig,
               "beforeTriggerDown promotes to activeVoiceMode = .shortcutConfig (got \(f.coord.activeVoiceMode))")
        expect(f.coord.pendingVoiceMode == .normal,
               "beforeTriggerDown clears pendingVoiceMode (got \(f.coord.pendingVoiceMode))")

        // Reset to keep state clean.
        f.coord.resetActiveMode()

        print("testBeforeTriggerDownConsumesPendingIntoActive: ok")
    }

    /// SC 2: armDuration timer fires → both modes back to .normal + overlay dismissed.
    @MainActor
    private static func testArmTimeoutFires(tmp: URL) throws {
        let f = makeFixture(tmp: tmp, name: "arm-timeout", armDuration: 0.1)
        defer { f.defaults.removePersistentDomain(forName: f.suiteName) }

        f.coord.arm()
        expect(f.coord.pendingVoiceMode == .shortcutConfig, "pending armed")

        // Pump the main runloop long enough for the 100ms timer to fire.
        // Thread.sleep would block main and prevent the DispatchSourceTimer
        // from firing — RunLoop.run(until:) processes pending events.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        expect(f.coord.pendingVoiceMode == .normal,
               "armTimer fired and called cancel(.timeout) (got \(f.coord.pendingVoiceMode))")
        expect(f.overlay.dismissCalls >= 1,
               "overlay was dismissed at least once (got \(f.overlay.dismissCalls))")

        print("testArmTimeoutFires: ok")
    }

    /// SC 3 / D-F-1: cancel(reason:) clears pending ONLY; active is untouched.
    @MainActor
    private static func testCancelClearsPendingOnly(tmp: URL) throws {
        let f = makeFixture(tmp: tmp, name: "cancel-pending-only")
        defer { f.defaults.removePersistentDomain(forName: f.suiteName) }

        // Cycle 1: arm + triggerDown so active becomes .shortcutConfig.
        f.coord.arm()
        f.coord.beforeTriggerDown()
        expect(f.coord.activeVoiceMode == .shortcutConfig,
               "active=.shortcutConfig after first arm+trigger")
        expect(f.coord.pendingVoiceMode == .normal,
               "pending cleared by beforeTriggerDown")

        // Cycle 2: arm again — pending becomes .shortcutConfig AGAIN while
        // active is STILL .shortcutConfig from the in-flight cycle.
        f.coord.arm()
        expect(f.coord.pendingVoiceMode == .shortcutConfig, "pending re-armed")
        expect(f.coord.activeVoiceMode == .shortcutConfig, "active unchanged by arm()")

        // The whole point of cancel(): clear pending WITHOUT touching active.
        f.coord.cancel(reason: .userEscape)

        expect(f.coord.pendingVoiceMode == .normal,
               "cancel(.userEscape) cleared pending (got \(f.coord.pendingVoiceMode))")
        expect(f.coord.activeVoiceMode == .shortcutConfig,
               "cancel(.userEscape) did NOT touch active (got \(f.coord.activeVoiceMode)) — D-F-1")

        // resetAllState to drain the active state (cancel does NOT call refiner.cancel,
        // so the MockRefiner.cancelCalls would remain 0 here — that's fine).

        print("testCancelClearsPendingOnly: ok")
    }

    /// SC 3: resetAllState clears BOTH modes + currentRequestToken + calls refiner.cancel.
    /// Runs the parameterised loop over the 3 hard-reset reasons.
    @MainActor
    private static func testResetAllStateClearsBothModes(tmp: URL) throws {
        let reasons: [ShortcutVoiceCoordinator.CancelReason] = [
            .appQuit, .secureInputEnter, .cancelRecording,
        ]
        for reason in reasons {
            let f = makeFixture(tmp: tmp, name: "reset-all-\(String(describing: reason))")
            defer { f.defaults.removePersistentDomain(forName: f.suiteName) }

            f.coord.arm()
            f.coord.beforeTriggerDown()
            expect(f.coord.activeVoiceMode == .shortcutConfig,
                   "active=.shortcutConfig pre-reset (reason=\(reason))")

            f.coord.resetAllState(reason: reason)

            expect(f.coord.pendingVoiceMode == .normal,
                   "resetAllState(\(reason)) cleared pending")
            expect(f.coord.activeVoiceMode == .normal,
                   "resetAllState(\(reason)) cleared active")
            expect(f.refiner.cancelCalls >= 1,
                   "resetAllState(\(reason)) called refiner.cancel (got \(f.refiner.cancelCalls))")
        }

        print("testResetAllStateClearsBothModes: ok")
    }

    /// SC 1: handleTranscription happy path — mock refiner returns valid YAML;
    /// importer inserts binding; activeVoiceMode resets to .normal; token cleared.
    @MainActor
    private static func testHandleTranscriptionHappyPath(tmp: URL) throws {
        let f = makeFixture(tmp: tmp, name: "happy-path")
        defer { f.defaults.removePersistentDomain(forName: f.suiteName) }

        f.coord.arm()
        f.coord.beforeTriggerDown()
        expect(f.coord.activeVoiceMode == .shortcutConfig, "active=.shortcutConfig pre-transcription")
        expect(f.store.bindings.isEmpty, "store empty pre-import")

        f.coord.handleTranscription("按 alt+g 打开 chrome")

        expect(f.refiner.capturedTranscript == "按 alt+g 打开 chrome",
               "refiner captured the user transcript (got \(String(describing: f.refiner.capturedTranscript)))")
        expect(f.refiner.capturedTemperature == 0.0,
               "refiner called with temperature=0.0 (COORD-06) (got \(String(describing: f.refiner.capturedTemperature)))")
        expect(f.refiner.capturedCompletion != nil,
               "refiner captured the completion closure")

        // Fire the mock refiner with a valid YAML body.
        let yaml = """
            version: 1
            shortcut: "alt+g"
            label: "Open Chrome"
            actions:
              - text: "hello"
            """
        f.refiner.fire(.success(yaml))

        expect(f.store.bindings.count == 1,
               "importer inserted exactly one binding (got \(f.store.bindings.count))")
        expect(f.coord.activeVoiceMode == .normal,
               "active reset to .normal post-completion (got \(f.coord.activeVoiceMode))")
        // No public getter for currentRequestToken — verified indirectly by
        // calling handleTranscription a second time and observing the refiner
        // captures a NEW completion (the prior token must be cleared for the
        // new one to take effect later). Below we just sanity-check that the
        // overlay received an "Added:" toast.
        let updates = f.overlay.updateCalls
        let hasAddedToast = updates.contains(where: { $0.hasPrefix("Added") })
        expect(hasAddedToast,
               "overlay received an 'Added' toast on happy path (got updates=\(updates))")

        // CR-02 regression: the success-toast must be auto-dismissed by the
        // coordinator's DispatchQueue.main.asyncAfter scheduled inside the
        // refiner completion. Pump the main runloop past the 1.5s delay.
        let dismissCallsBefore = f.overlay.dismissCalls
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.7))
        expect(f.overlay.dismissCalls > dismissCallsBefore,
               "overlay.dismiss() must be called after success toast (before=\(dismissCallsBefore), after=\(f.overlay.dismissCalls)) — CR-02")

        print("testHandleTranscriptionHappyPath: ok")
    }

    /// SC 5 partial: handleTranscription LLM failure — mock refiner fires
    /// .failure → recordLLMFailure called + audit line with llm-error kind +
    /// overlay shows "Could not configure shortcut" + active reset.
    @MainActor
    private static func testHandleTranscriptionLLMFailure(tmp: URL) throws {
        let f = makeFixture(tmp: tmp, name: "llm-failure")
        defer { f.defaults.removePersistentDomain(forName: f.suiteName) }

        f.coord.arm()
        f.coord.beforeTriggerDown()

        f.coord.handleTranscription("anything")
        expect(f.refiner.capturedCompletion != nil, "refiner captured completion")

        // Fire a .failure result.
        f.refiner.fire(.failure(URLError(.timedOut)))

        // Drain the audit-log queue so the on-disk read below is deterministic.
        // The importer's auditLog is a private property; the only deterministic
        // way to wait is via importer.terminate() which calls auditLog.close()
        // (which drains the queue). Per the importer doc-comment it's
        // idempotent and safe to call here.
        f.importer.terminate()

        // Active reset post-completion.
        expect(f.coord.activeVoiceMode == .normal,
               "active reset to .normal after LLM failure (got \(f.coord.activeVoiceMode))")

        // Overlay received the failure literal.
        expect(f.overlay.updateCalls.contains("Could not configure shortcut"),
               "overlay shows failure literal (got updates=\(f.overlay.updateCalls))")

        // CR-02 regression: failure-toast must also auto-dismiss after the 1.5s
        // linger window. Without the scheduled dismiss, the overlay set by
        // arm() then replaced by updateText("Could not configure shortcut")
        // would remain on screen until the next show()/dismiss() call.
        let dismissCallsBefore = f.overlay.dismissCalls
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.7))
        expect(f.overlay.dismissCalls > dismissCallsBefore,
               "overlay.dismiss() must be called after failure toast (before=\(dismissCallsBefore), after=\(f.overlay.dismissCalls)) — CR-02")

        // Audit-log line written with kind=llm-error.
        let content = (try? String(contentsOf: f.auditURL, encoding: .utf8)) ?? ""
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        expect(lines.count >= 1,
               "at least one audit line on llm-error path (got \(lines.count))")
        let hasLLMErrorLine = lines.contains(where: { $0.contains("\"kind\":\"llm-error\"") })
        expect(hasLLMErrorLine,
               "an audit line contains kind=llm-error (got \(lines.map(String.init)))")

        print("testHandleTranscriptionLLMFailure: ok")
    }

    /// SC 5 BLOCKER: token-discard on stale LLM completion.
    ///
    /// 1. arm + beforeTriggerDown.
    /// 2. handleTranscription("first") — refiner CAPTURES the completion
    ///    (does NOT fire); coordinator's currentRequestToken == tokenA.
    /// 3. resetAllState(.cancelRecording) — clears currentRequestToken AND
    ///    calls refiner.cancel (mock just bumps the counter).
    /// 4. Record store + audit state BEFORE the stale fire.
    /// 5. fire the captured completion with .success("valid YAML") —
    ///    the closure compares its captured tokenA against
    ///    self.currentRequestToken == nil → MISMATCH → silent discard.
    /// 6. Assert: store unchanged, NO new audit line, NO "Added" toast.
    @MainActor
    private static func testTokenDiscardOnStaleCompletion(tmp: URL) throws {
        let f = makeFixture(tmp: tmp, name: "token-discard")
        defer { f.defaults.removePersistentDomain(forName: f.suiteName) }

        // Step 1-2: arm + handleTranscription captures the completion.
        f.coord.arm()
        f.coord.beforeTriggerDown()
        f.coord.handleTranscription("first cycle")
        expect(f.refiner.capturedCompletion != nil,
               "refiner captured the first-cycle completion (not yet fired)")

        // Step 3: hard reset → currentRequestToken := nil.
        f.coord.resetAllState(reason: .cancelRecording)
        expect(f.coord.pendingVoiceMode == .normal, "pending cleared post-reset")
        expect(f.coord.activeVoiceMode == .normal, "active cleared post-reset")

        // Drain any audit queue state so the BEFORE-snapshot is stable.
        f.importer.terminate()

        // Step 4: BEFORE-snapshot of store + audit.
        let bindingsBefore = f.store.bindings.count
        let preContent = (try? String(contentsOf: f.auditURL, encoding: .utf8)) ?? ""
        let preLines = preContent.split(separator: "\n", omittingEmptySubsequences: true).count

        let updatesBefore = f.overlay.updateCalls.count

        // Step 5: STALE FIRE — first-cycle completion fires AFTER the reset.
        // The closure must see currentRequestToken == nil and silently return.
        let yaml = """
            version: 1
            shortcut: "alt+g"
            actions:
              - text: "x"
            """
        f.refiner.fire(.success(yaml))

        // Step 6: post-state must equal pre-state — no insert, no audit, no toast.
        f.importer.terminate()
        let postContent = (try? String(contentsOf: f.auditURL, encoding: .utf8)) ?? ""
        let postLines = postContent.split(separator: "\n", omittingEmptySubsequences: true).count

        expect(f.store.bindings.count == bindingsBefore,
               "store unchanged by stale completion (before=\(bindingsBefore), after=\(f.store.bindings.count))")
        expect(postLines == preLines,
               "audit-log line count unchanged by stale completion (before=\(preLines), after=\(postLines))")

        // overlay.updateCalls must NOT have grown with an "Added" toast.
        let updatesAfter = f.overlay.updateCalls
        expect(updatesAfter.count == updatesBefore,
               "no new overlay.updateText calls from the stale path (before=\(updatesBefore), after=\(updatesAfter.count))")

        print("testTokenDiscardOnStaleCompletion: ok")
    }

    /// APP-02 surface: resetActiveMode() clears active + token but does NOT
    /// touch pending or armTimer (the latter is already cleared by
    /// beforeTriggerDown in this scenario, so we just check the two modes).
    @MainActor
    private static func testEmptyTranscriptResetsActiveMode(tmp: URL) throws {
        let f = makeFixture(tmp: tmp, name: "empty-transcript")
        defer { f.defaults.removePersistentDomain(forName: f.suiteName) }

        f.coord.arm()
        f.coord.beforeTriggerDown()
        expect(f.coord.activeVoiceMode == .shortcutConfig, "active=.shortcutConfig pre-reset")
        expect(f.coord.pendingVoiceMode == .normal,
               "pending cleared by beforeTriggerDown")

        f.coord.resetActiveMode()

        expect(f.coord.activeVoiceMode == .normal,
               "resetActiveMode cleared active (got \(f.coord.activeVoiceMode))")
        expect(f.coord.pendingVoiceMode == .normal,
               "resetActiveMode did NOT touch pending (got \(f.coord.pendingVoiceMode))")

        print("testEmptyTranscriptResetsActiveMode: ok")
    }

    // MARK: - Helpers (verbatim project-wide test idiom from Tests/ShortcutYAMLImporterTests.swift:1014-1026)

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Mocks

/// Records every show/updateText/dismiss call so tests can assert the exact
/// overlay sequence the coordinator drove.
fileprivate final class MockOverlay: OverlayDisplaying {
    var showCalls: [String] = []
    var updateCalls: [String] = []
    var dismissCalls = 0
    func show(text: String) { showCalls.append(text) }
    func updateText(_ text: String) { updateCalls.append(text) }
    func dismiss() { dismissCalls += 1 }
}

/// Captures the LLMRefiner.refine call args + the completion closure so the
/// test can manually fire late results via `fire(_:)`. This is the seam that
/// enables testTokenDiscardOnStaleCompletion to reproduce the race
/// deterministically.
fileprivate final class MockRefiner: LLMRefining {
    var isReady: Bool { true }
    var capturedTranscript: String?
    var capturedSystemPrompt: String?
    var capturedTemperature: Double?
    // WR-01: protocol now declares completion `@escaping @MainActor (Result) -> Void`.
    // The mock's captured-closure storage type tracks the protocol exactly.
    var capturedCompletion: (@MainActor (Result<String, Error>) -> Void)?
    var cancelCalls = 0

    func refine(
        _ userText: String,
        systemPrompt: String,
        temperature: Double,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        capturedTranscript = userText
        capturedSystemPrompt = systemPrompt
        capturedTemperature = temperature
        capturedCompletion = completion
    }

    func cancel() {
        cancelCalls += 1
    }

    /// Manually fire the captured completion to simulate a late LLM return.
    /// Used by `testTokenDiscardOnStaleCompletion` to deliver a stale result
    /// AFTER `resetAllState` has cleared the coordinator's request token.
    /// Marked `@MainActor` because the completion closure is `@MainActor`;
    /// tests already run on main (see @main runner annotation).
    @MainActor
    func fire(_ result: Result<String, Error>) {
        capturedCompletion?(result)
    }
}
