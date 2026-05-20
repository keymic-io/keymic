// ShortcutVoiceConfigSection.swift
//
// Phase 5 (Settings UI Section & Undo Toast) — UI surface for the speak-to-bind
// voice-shortcut flow. Embedded inside `ShortcutsSettingsSection` (SettingsRoot.swift)
// in plan 05-06.
//
// Populated incrementally by Phase 5 plans:
//   - 05-02 (this plan): scaffold + file-local ArmShortcutVoiceKey EnvironmentKey
//   - 05-03: view skeleton (voice trigger label + "Start Voice Recording" button)
//   - 05-04: status line + undo toast (NotificationCenter consumption + TTL)
//   - 05-05: reveal-audit-log button + shell-action toggle + warning banner

import AppKit
import Foundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: "io.keymic.app", category: "ShortcutVoiceConfigSection")

// MARK: - EnvironmentKey for AppDelegate-injected arm closure (UI-03)

/// File-local EnvironmentKey carrying the AppDelegate-supplied arm closure.
/// The view consumes this via `@Environment(\.armShortcutVoice)` rather than
/// reaching for `ShortcutVoiceCoordinator.shared` directly, satisfying UI-03
/// ("no global singleton access from the SwiftUI view for the arm action").
///
/// The default value is an intentional no-op fallback that logs a warning so
/// accidental missing injection (e.g. in SwiftUI previews or test harnesses
/// without the AppDelegate wiring) is loud during development.
private struct ArmShortcutVoiceKey: EnvironmentKey {
    static let defaultValue: () -> Void = {
        logger.warning("armShortcutVoice invoked but no closure was injected via .environment(...)")
    }
}

extension EnvironmentValues {
    /// AppDelegate-supplied closure that arms `ShortcutVoiceCoordinator.shared`.
    /// Injected at the SwiftUI root in `SwiftUISettingsWindow.init(armShortcutVoice:)`.
    var armShortcutVoice: () -> Void {
        get { self[ArmShortcutVoiceKey.self] }
        set { self[ArmShortcutVoiceKey.self] = newValue }
    }
}

// MARK: - Section view (skeleton populated in 05-03; status/reveal/toggle in 05-04/05-05)

/// SwiftUI section for the speak-to-bind voice-shortcut flow.
///
/// Plan 05-03 populates the load-bearing skeleton:
///   - Subtitle / explanation row (D-B-2)
///   - Voice trigger label sourced from `HotkeySettingsStore.shared`,
///     reactive to `UserDefaults.didChangeNotification` (UI-02)
///
/// Subsequent plans extend this view:
///   - 05-04: status line + Undo toast (NotificationCenter consumption + TTL)
///   - 05-05: Reveal Audit Log button + shell-action toggle + warning banner
///   - 05-06: embedding into ShortcutsSettingsSection
struct ShortcutVoiceConfigSection: View {
    // MARK: AppDelegate-injected arm closure (UI-03)
    //
    // Captured here (declared at the View struct scope) so Task 2's Start
    // button action can invoke it. The closure is set by
    // `SwiftUISettingsWindow.init(armShortcutVoice:)` in plan 05-02 via the
    // file-local `ArmShortcutVoiceKey` EnvironmentKey above.
    @Environment(\.armShortcutVoice) private var armShortcutVoice

    // MARK: View-local state

    /// UI-02 source-of-truth mirror. Default fallback "fn" matches
    /// `HotkeyFeature.defaults` (HotkeySettingsStore.swift:26). Updated by
    /// `refreshVoiceTriggerLabel()` on `.onAppear` and whenever
    /// `UserDefaults.didChangeNotification` fires.
    @State private var voiceTriggerLabel: String = "fn"

    /// UI-04 caption-flip + button-disable driver. Flipped to `true` from
    /// `startArm()` immediately after the AppDelegate-injected arm closure
    /// fires; flipped back to `false` by the Esc local monitor, the 30s
    /// UI-side timeout mirror, and (in 05-04) the
    /// `.shortcutImportDidComplete` notification handler.
    @State private var isArmed: Bool = false

    /// UI-05: holds the opaque token returned by
    /// `NSEvent.addLocalMonitorForEvents` while the section is armed.
    /// Registered when `isArmed` flips true; removed when it flips false
    /// or `.onDisappear` fires (defensive). Per 05-RESEARCH Pitfall 4
    /// (token leak): always remove the prior token before reassigning.
    @State private var escMonitor: Any? = nil

    // MARK: UI-07 / UI-08 status-line state (Plan 05-04)
    //
    // The status line consumes `.shortcutImportDidComplete` notifications and
    // renders a transient message for ~3s. Three pieces of view-local state
    // drive it:
    //
    //   - `statusMessage`: the current displayed text (nil = hidden row).
    //   - `statusBindingId`: the bindingId of the most recent successful
    //     insert, used as the argument to `removeLastImport(id:)` when the
    //     user clicks the Undo button. Set only for true successful inserts
    //     (parseError nil AND conflictCleared false AND bindingId non-nil)
    //     per D-G-2 — non-success outcomes leave this `nil` so the Undo
    //     button stays hidden.
    //   - `messageGeneration`: monotonically-bumped counter feeding the
    //     `.task(id:)` modifier. Each new notification bumps the counter,
    //     which cancels the prior 3s sleep task and starts a fresh one.
    //     Race-free per 05-RESEARCH Pattern 3 cooperative-cancellation
    //     analysis.

    /// UI-07: transient status text shown after `.shortcutImportDidComplete`.
    /// `nil` collapses the status row. Auto-cleared by the 3s
    /// `.task(id: messageGeneration)` TTL or the Undo handler.
    @State private var statusMessage: String? = nil

    /// UI-08: bindingId of the most-recent SUCCESSFUL insert. `nil` when the
    /// last outcome was a parse error, conflict-cleared, or shell-stripped
    /// non-insert — Undo button stays hidden in those cases per D-G-2.
    @State private var statusBindingId: UUID? = nil

    /// UI-07: bumped on every notification so `.task(id: messageGeneration)`
    /// cancels the prior 3s task and starts a fresh one. Overflow-safe
    /// `&+= 1` because `.task(id:)` only cares about value change, not
    /// monotonicity.
    @State private var messageGeneration: Int = 0

    // MARK: UI-10 / UI-09 shell-actions toggle (Plan 05-05)

    /// UI-10: bound to UserDefaults key `"shortcutVoiceShellEnabled"`.
    ///
    /// Phase 3's `ShortcutYAMLImporter` reads
    /// `UserDefaults.standard.bool(forKey: "shortcutVoiceShellEnabled")`
    /// per call (IMP-08 / 03 P-05) — no caching, so toggle changes take
    /// effect on the NEXT import. Same `UserDefaults.standard` instance
    /// bridges to `@AppStorage`; no extra coordination needed.
    ///
    /// CRITICAL: `@AppStorage` does NOT write the default value to
    /// UserDefaults on first read. Absent key → returns the `false`
    /// default. `UserDefaults.standard.bool(forKey:)` ALSO returns `false`
    /// for absent keys. The contract holds without any defensive
    /// `.onAppear` writes (per 05-RESEARCH Anti-Patterns: writing a
    /// defensive default on appear pollutes UserDefaults and is forbidden).
    @AppStorage("shortcutVoiceShellEnabled") private var shellEnabled: Bool = false

    // MARK: Constants

    /// UI-side mirror of `ShortcutVoiceCoordinator.armDuration` (30s).
    ///
    /// Per 05-RESEARCH Assumption A5 + Pitfall §8 the Phase 4 coordinator
    /// silently expires after 30s with no UI-visible notification, so the
    /// view drives its own `Task.sleep(for: .seconds(30))` mirror to flip
    /// `isArmed` back to `false`. Keep this constant byte-identical with
    /// the coordinator's `armDuration` (Sources/KeyMic/Hotkey/ShortcutVoiceCoordinator.swift:218).
    /// Future audit item: hoist into a shared module-level constant once
    /// Phase 6 lands.
    private static let mirroredArmDuration: TimeInterval = 30.0

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // D-B-2: section subtitle / explanation (foregroundStyle secondary).
            Text(String(localized: "Press a hotkey, speak your shortcut. KeyMic configures it for you."))
                .font(.callout)
                .foregroundStyle(.secondary)

            // UI-02: voice-trigger label row. LabeledContent style mirrors
            // existing VoiceSettingsView (SettingsRoot.swift:427+).
            LabeledContent {
                Text(voiceTriggerLabel)
                    .font(.system(.body, design: .monospaced))
            } label: {
                Text(String(localized: "Voice trigger key:"))
            }

            // UI-04: "Start Voice Recording" button. Caption flips between
            // the idle and armed literals based on `isArmed`. While armed,
            // the button is disabled to prevent double-arming via the UI
            // (the coordinator's arm() is idempotent / replace-on-rearm,
            // but disabling makes the affordance clearer).
            //
            // The armed-state literal "Waiting for voice key… (Esc to cancel)"
            // uses the U+2026 single-character ellipsis to match the Phase 4
            // overlay literal "Speak your shortcut (30s)…" (verified
            // hexdump e2 80 a6). DO NOT replace with three ASCII dots.
            Button {
                startArm()
            } label: {
                Text(isArmed
                     ? String(localized: "Waiting for voice key… (Esc to cancel)")
                     : String(localized: "Start Voice Recording"))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isArmed)

            // UI-06: Reveal Audit Log button (Plan 05-05).
            //
            // Opens Finder with `shortcut-voice-audit.log` PRE-SELECTED (vs. just
            // opening the parent directory). NSWorkspace.activateFileViewerSelecting
            // requires the target file to exist for the selection to land — if the
            // file is absent it falls back to opening the parent dir with no
            // selection. Empty NDJSON is a valid first state (the Phase 3 writer
            // appends via seekToEnd at ShortcutAuditLog.swift:316-318) so we
            // lazily create an empty file (+ parent dir) before the reveal call.
            //
            // Placement: BELOW the Start button + status row, ABOVE the shell
            // toggle — visual grouping of "voice flow controls" precedes the
            // "permissions / safety" surface.
            Button {
                revealAuditLog()
            } label: {
                Label(String(localized: "Reveal Audit Log"), systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // UI-09 / UI-10: shell-actions toggle + warning banner (Plan 05-05).
            //
            // Order locked by D-E-1 recommendation: banner ABOVE the toggle.
            // When the user is about to toggle OFF, the banner is the LAST
            // thing they see before their click — the right safety affordance.
            // When the toggle is OFF (default), no banner is rendered (the
            // toggle's own label is sufficient).
            //
            // The `@AppStorage` binding is shared with the Phase 3 importer
            // (IMP-08): the importer reads `UserDefaults.standard.bool(...)`
            // per call so toggle changes take effect on the NEXT import.
            if shellEnabled {
                ShellWarningBanner()
            }
            Toggle(String(localized: "Allow voice-generated shell actions"), isOn: $shellEnabled)

            // UI-07 / UI-08: transient status row + Undo button (Plan 05-04).
            //
            // Layout choice (D-G-1): status text on the left, Undo button on
            // the right of the SAME HStack. Both disappear together when
            // `statusMessage` becomes nil.
            //
            // We use `.opacity` + `.animation(_:value:)` rather than wrapping
            // the entire HStack in `if let` so the row keeps its slot in the
            // VStack and the layout above/below does not reflow each time
            // the status appears/disappears.
            //
            // WR-01 (05-REVIEW.md): the inner HStack content is now
            // UNCONDITIONAL (Text + Spacer + Button always exist in the
            // view tree). Two reasons:
            //
            //  1. Animation: with `if let msg = statusMessage` inside the
            //     HStack, the children collapsed at the START of the
            //     250ms fade-out (because `statusMessage` was already nil),
            //     leaving only empty padding to "fade". Keeping children
            //     alive means Text + Button fade out together with the
            //     outer .opacity transition.
            //
            //  2. Undo race near T≈3s: with the children gated on
            //     `if let bid = statusBindingId`, the .task TTL could
            //     unmount the Button between the SwiftUI hit-test and the
            //     action dispatch — the click would land on whatever
            //     replaced it. Keeping the Button alive with
            //     `.disabled(statusBindingId == nil)` means the action
            //     handler captures the bindingId at tap time, not at
            //     render time, and a late click still completes safely.
            //
            // Tradeoff: empty `Text("")` collapses to zero-size in macOS
            // SwiftUI 14, so the row still appears empty when statusMessage
            // is nil — visually identical to the prior conditional design.
            HStack(spacing: 8) {
                Text(statusMessage ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Undo")) {
                    // Read bindingId at TAP time (not render time) — keeps
                    // the action correct even if the .task TTL clears
                    // statusBindingId between the hit-test and dispatch.
                    if let bid = statusBindingId {
                        undoLastImport(id: bid)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .opacity(statusBindingId == nil ? 0 : 1)
                .disabled(statusBindingId == nil)
            }
            .padding(.vertical, 4)
            .opacity(statusMessage == nil ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: statusMessage)
            .animation(.easeInOut(duration: 0.25), value: statusBindingId)
        }
        .onAppear { refreshVoiceTriggerLabel() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshVoiceTriggerLabel()
        }
        // UI-07: status-line driver. Mirrors Phase 4's `routeOutcomeToOverlay`
        // (ShortcutVoiceCoordinator.swift:458-477) — same 4-disposition order,
        // same `String(localized:)` keys so `Localizable.xcstrings` is the
        // single source of truth (no translation drift). Phase 5 adds one
        // extra branch ("llm-error" → "Could not configure shortcut") that
        // Phase 4 collapses into the generic parse-error literal.
        //
        // The handler also flips `isArmed = false` because reaching this
        // notification means the arm cycle completed (success OR failure) —
        // the view should return to the idle caption regardless of outcome.
        .onReceive(NotificationCenter.default.publisher(for: .shortcutImportDidComplete)) { notif in
            guard let outcome = notif.userInfo?["outcome"] as? Outcome else { return }
            statusMessage = computeStatusText(for: outcome)
            // D-G-2: Undo is offered ONLY for true successful inserts.
            statusBindingId = (outcome.parseError == nil
                               && !outcome.conflictCleared
                               && outcome.bindingId != nil)
                ? outcome.bindingId
                : nil
            messageGeneration &+= 1
            isArmed = false
        }
        // UI-05: register/unregister the Esc local monitor lifecycle.
        // Local monitors are app-scoped, NOT window-scoped (05-RESEARCH
        // Pitfall 4), so we must register only while armed and remove
        // promptly when armed flips false to avoid swallowing Esc app-wide.
        .onChange(of: isArmed) { _, armed in
            if armed {
                registerEscMonitor()
            } else {
                unregisterEscMonitor()
            }
        }
        // UI-05: UI-side 30s timeout mirror.
        //
        // The Phase 4 coordinator's armDuration (30s) silently cancels with
        // no notification when it expires (05-RESEARCH Pitfall §8), so the
        // view drives its own timer to flip `isArmed` back to false. When
        // `isArmed` flips false externally (Esc / success), `.task(id:)`
        // cancels this task, the sleep throws, and the post-sleep flip is
        // skipped — which is correct because something else already cleared
        // the state.
        .task(id: isArmed) {
            guard isArmed else { return }
            try? await Task.sleep(for: .seconds(Self.mirroredArmDuration))
            guard !Task.isCancelled else { return }
            if isArmed { isArmed = false }
        }
        // UI-07: 3s status-line TTL.
        //
        // `.task(id: messageGeneration)` launches a fresh sleep task on every
        // notification (each bump cancels the prior task). Cooperative
        // cancellation: when the id changes mid-window, `Task.sleep` throws
        // CancellationError → `try?` swallows it → control exits the function
        // BEFORE the `statusMessage = nil` line runs. So the post-sleep
        // clear only fires for the LATEST notification's window, not racing
        // any earlier one. Race-free per 05-RESEARCH Pattern 3 analysis.
        //
        // Multiple `.task(id:)` modifiers on the same view stack independently
        // — each has its own id keyspace.
        .task(id: messageGeneration) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            statusMessage = nil
            statusBindingId = nil
        }
        // UI-05 defensive cleanup safety net per D-D-3, +
        // UI-11 in-flight-arm cancellation per D-F-1 (Plan 05-05).
        //
        // `.onDisappear` fires for BOTH window-close AND tab-switch within
        // the settings sidebar (D-F-2). Both are sensible cancel signals —
        // the user has stopped attending to the arm flow either way. Do
        // NOT try to narrow this to "window-close only"; the dual-trigger
        // behavior is intentional and matches UI-11 wording
        // ("settings-window-close-while-armed").
        //
        // The cancel call is idempotent + silent when not armed (D-F-3 +
        // ShortcutVoiceCoordinator.cancel at ShortcutVoiceCoordinator.swift:
        // 306-322), so invoking it on every onDisappear regardless of state
        // is safe.
        .onDisappear {
            // 1. Defensive Esc-monitor cleanup. The `.onChange(of: isArmed)`
            //    handler already removes the monitor when isArmed flips
            //    false, but `.onDisappear` may fire BEFORE that flip in
            //    some lifecycles (e.g. window close while armed) so this
            //    second removal is a belt-and-braces safety net.
            unregisterEscMonitor()
            // 2. UI-11 / D-F-1: cancel any in-flight arm on settings-window-
            //    close or tab-switch. `.settingsReload` is the canonical
            //    reason; the coordinator's cancel() is idempotent and
            //    silent when not armed (no log noise, no state churn).
            ShortcutVoiceCoordinator.shared.cancel(reason: .settingsReload)
        }
    }

    // MARK: Helpers

    /// UI-02: reads the current voice-trigger hotkey from
    /// `HotkeySettingsStore.shared` and renders it via `displayString()`.
    /// Default fallback "fn" matches the seeded default in
    /// `HotkeyFeature.defaults`.
    private func refreshVoiceTriggerLabel() {
        voiceTriggerLabel = HotkeySettingsStore.shared.hotkey(for: .voiceTrigger)?.displayString() ?? "fn"
    }

    /// UI-03 + UI-04: arms the coordinator via the AppDelegate-injected
    /// closure, then flips view-local `isArmed` to drive the caption +
    /// disable state. Ordering matters: arm first (coordinator transitions
    /// to `.shortcutConfig`), THEN flip the view — keeps the state
    /// machines coherent if the closure ever becomes async.
    private func startArm() {
        armShortcutVoice()
        isArmed = true
    }

    /// UI-05: register the Esc local monitor. Per 05-RESEARCH Pitfall 4 we
    /// always remove a prior token before reassigning to avoid leaking
    /// stacked monitors.
    ///
    /// The monitor handler:
    ///   - lets every non-Esc keyDown pass through unchanged
    ///   - on Esc (`kVK_Escape == 0x35`): calls
    ///     `ShortcutVoiceCoordinator.shared.cancel(reason: .userEscape)`,
    ///     flips `isArmed = false` on the main actor, returns `nil` to
    ///     swallow the keystroke so it doesn't bubble up to other handlers.
    ///
    /// NSEvent.addLocalMonitorForEvents handlers run on the main thread
    /// already, but we still bounce the `isArmed = false` flip through
    /// `DispatchQueue.main.async` to defer the SwiftUI state mutation past
    /// the current event-dispatch frame (avoids re-entrancy weirdness).
    private func registerEscMonitor() {
        unregisterEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 0x35 /* kVK_Escape */ else { return event }
            ShortcutVoiceCoordinator.shared.cancel(reason: .userEscape)
            DispatchQueue.main.async {
                isArmed = false
            }
            return nil // swallow Esc
        }
    }

    /// UI-05: paired cleanup. Always nil out `escMonitor` after removal so
    /// the next `addLocalMonitorForEvents` can't double-register.
    private func unregisterEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    // MARK: UI-06 Reveal Audit Log

    /// UI-06: opens Finder with `shortcut-voice-audit.log` pre-selected.
    ///
    /// `NSWorkspace.shared.activateFileViewerSelecting([url])` requires the
    /// target file to exist for the selection affordance to land. If the file
    /// is missing it opens the parent directory with NO selection; if the
    /// parent dir is missing too it no-ops. To guarantee the user always sees
    /// the file (even on a fresh install where no shortcut-voice import has
    /// ever run), we lazily create the parent dir + empty file here.
    ///
    /// Empty content is a valid first state for the audit log:
    /// `ShortcutAuditLog.append(_:)` at lines 304-325 opens-fresh-per-write
    /// (no header expected) and appends via `seekToEnd()`. Phase 3's writer
    /// already creates the file itself on first write (`fileExists` →
    /// `createFile(atPath:contents:)` at lines 310-312), so this helper's
    /// pre-creation matches the existing audit-log file-shape contract.
    ///
    /// Errors during directory creation are silently swallowed (`try?`) —
    /// the reveal call's fallback (open parent dir) is acceptable degraded
    /// behaviour if the user's Application Support directory is unusual.
    private func revealAuditLog() {
        let url = ShortcutAuditLog.defaultURL
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            // contents: nil creates a zero-byte file — valid empty NDJSON.
            fm.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: UI-07 status text router (mirror of Phase 4 routeOutcomeToOverlay)

    /// UI-07 status text router. Mirrors
    /// `ShortcutVoiceCoordinator.routeOutcomeToOverlay`
    /// (ShortcutVoiceCoordinator.swift:458-477) — same disposition order,
    /// same English literals, all routed through `String(localized:)` so
    /// `Localizable.xcstrings` is the single source of truth for the four
    /// overlapping keys.
    ///
    /// CR-01 (05-REVIEW.md) reconciliation: Phase 4's router was updated to
    /// match Phase 5's wording byte-for-byte (defensive fallback "Shortcut
    /// updated", pretty-printed trigger via `displayString()`, label
    /// fallback `String(localized: "shortcut")`). Both surfaces now route
    /// through the SAME xcstrings keys ("Could not parse shortcut",
    /// "Trigger cleared (%@) — set it in Settings", "Added: %@ → %@",
    /// "shortcut", "Shortcut updated"). Phase 4's LLM-failure path sets
    /// `updateText("Could not configure shortcut")` BEFORE
    /// `routeOutcomeToOverlay` runs, so `routeOutcomeToOverlay` never sees
    /// `parseError == "llm-error"` — the "llm-error" branch below is
    /// reached only via the `.shortcutImportDidComplete` notification
    /// consumer (Phase 5).
    ///
    /// Disposition priority (locked, must match Phase 4):
    ///   1. `parseError != nil`:
    ///        - `"llm-error"` → "Could not configure shortcut"  (Phase 5-only)
    ///        - any other     → "Could not parse shortcut"      (matches Phase 4)
    ///   2. `conflictCleared == true` → "Trigger cleared (<source>) — set it in Settings"
    ///      The em-dash is U+2014 single-character, BYTE-IDENTICAL with
    ///      Phase 4 (ShortcutVoiceCoordinator.swift:465). Do NOT replace
    ///      with a hyphen-minus or two hyphens.
    ///   3. `bindingId != nil` + lookup hits store → "Added: <trigger> → <label>"
    ///      The arrow is U+2192 single-character, BYTE-IDENTICAL with
    ///      Phase 4 (ShortcutVoiceCoordinator.swift:470). Trigger is
    ///      pretty-printed via `HotkeyConfig.parse(...)?.displayString()`
    ///      (mirrors ShortcutRow.triggerDisplay precedent at
    ///      SettingsRoot.swift:1188); falls back to the raw trigger
    ///      string if parse fails.
    ///   4. Defensive fallback → "Shortcut updated"
    ///
    /// Returns a non-nil String in every branch (no nil return); the
    /// `String?` return type is preserved for future "no message" cases.
    private func computeStatusText(for outcome: Outcome) -> String? {
        if let kind = outcome.parseError {
            return kind == "llm-error"
                ? String(localized: "Could not configure shortcut")
                : String(localized: "Could not parse shortcut")
        }
        if outcome.conflictCleared {
            let source = outcome.conflictSource ?? ""
            return String(localized: "Trigger cleared (\(source)) — set it in Settings")
        }
        if let bindingId = outcome.bindingId,
           let binding = HotkeyBindingsStore.shared.bindings.first(where: { $0.id == bindingId }) {
            let triggerDisplay = HotkeyConfig.parse(binding.trigger)?.displayString() ?? binding.trigger
            let label = binding.label ?? String(localized: "shortcut")
            return String(localized: "Added: \(triggerDisplay) → \(label)")
        }
        return String(localized: "Shortcut updated")
    }

    // MARK: UI-08 Undo handler

    /// UI-08: removes the most-recent imported binding via the Phase 3
    /// importer.
    ///
    /// PITFALL #5 (05-RESEARCH "Importer notification posted with
    /// transcript == '' from undo path"):
    ///   `ShortcutYAMLImporter.removeLastImport(id:)` posts
    ///   `.shortcutImportDidComplete` with `userInfo["transcript"] == ""`
    ///   and `outcome.bindingId == id` (the just-removed binding's id) on
    ///   the success branch [VERIFIED: ShortcutYAMLImporter.swift:516-535].
    ///   The `.onReceive` handler in this view does NOT differentiate
    ///   "import" from "undo echo" — it just renders. If we called
    ///   `removeLastImport` FIRST, the echo notification would arrive
    ///   with the same bindingId, `computeStatusText` would find the
    ///   binding already removed from `HotkeyBindingsStore`, the
    ///   `Added: …` branch would fall through, and the row would re-render
    ///   as the defensive "Shortcut updated" fallback — confusing UX
    ///   ("did Undo work? why is there still a status?").
    ///
    /// MITIGATION: clear `statusMessage` and `statusBindingId` BEFORE
    /// calling `removeLastImport`. The KEY invariant is that the
    /// view's status state is already cleared by the time the importer
    /// posts its undo notification. The subsequent `.onReceive` will
    /// re-set them (because the binding is now gone, status text falls
    /// through to "Shortcut updated") and `messageGeneration` will bump
    /// → a fresh 3s TTL covers the brief echo flash. Acceptable v1
    /// behavior; the binding's removal from the list is the real
    /// confirmation of undo (D-G-4).
    private func undoLastImport(id: UUID) {
        statusMessage = nil
        statusBindingId = nil
        ShortcutYAMLImporter.shared.removeLastImport(id: id)
    }

    // MARK: - UI-09 Warning Banner (nested file-local View)

    /// UI-09: warning banner rendered when the shell-actions toggle is on.
    ///
    /// Style per 05-CONTEXT.md D-E-1 (locked):
    ///   - Background: `.yellow.opacity(0.15)` (light tint, not screaming).
    ///   - Leading SF Symbol: `exclamationmark.triangle.fill` (yellow).
    ///   - Copy: direct + factual ("Voice-generated shortcuts may include
    ///     shell actions. Only enable if you trust the LLM endpoint.") —
    ///     aims for accuracy without alarmism.
    ///   - Corner radius 8, padding 12.
    ///
    /// Renders conditionally only when `shellEnabled == true`; when the
    /// toggle flips off the banner disappears with SwiftUI's default
    /// insertion/removal transition.
    ///
    /// Nested inside `ShortcutVoiceConfigSection` (file-local, not exported)
    /// to keep the file's surface small — this banner has no consumers
    /// outside this section.
    private struct ShellWarningBanner: View {
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(String(localized: "Voice-generated shortcuts may include shell actions. Only enable if you trust the LLM endpoint."))
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
