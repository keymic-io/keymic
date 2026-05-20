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

// MARK: - Section view (placeholder; body populated in 05-03..05-05)

/// Placeholder SwiftUI section for the speak-to-bind voice-shortcut flow.
/// Body is intentionally empty in plan 05-02 — only the file scaffold +
/// EnvironmentKey wiring lands here. Subsequent plans populate the body:
/// 05-03 (skeleton), 05-04 (status + undo), 05-05 (reveal + toggle + banner).
struct ShortcutVoiceConfigSection: View {
    var body: some View {
        EmptyView()
    }
}
