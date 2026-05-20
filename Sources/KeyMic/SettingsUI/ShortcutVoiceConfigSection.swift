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

            // Esc handling (Task 3) and status line / Undo (05-04) land in
            // subsequent commits.
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
        // Defensive cleanup safety net per D-D-3. UI-11 (cancel(.settingsReload)
        // on disappear) lands in plan 05-05.
        .onDisappear {
            unregisterEscMonitor()
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

    // MARK: UI-07 status text router (mirror of Phase 4 routeOutcomeToOverlay)

    /// UI-07 status text router. Mirrors
    /// `ShortcutVoiceCoordinator.routeOutcomeToOverlay`
    /// (ShortcutVoiceCoordinator.swift:458-477) — same disposition order,
    /// same English literals, all routed through `String(localized:)` so
    /// `Localizable.xcstrings` is the single source of truth for the four
    /// overlapping keys. Phase 5 adds one extra branch for `"llm-error"`
    /// that Phase 4 collapses into the generic parse-error message.
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
}
