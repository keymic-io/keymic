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
    /// fires; flipped back to `false` by the Esc local monitor (Task 3),
    /// the 30s UI-side timeout mirror (Task 3), and (in 05-04) the
    /// `.shortcutImportDidComplete` notification handler.
    @State private var isArmed: Bool = false

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
}
