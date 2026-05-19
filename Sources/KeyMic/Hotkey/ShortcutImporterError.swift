import Foundation

// MARK: - ShortcutImporterError

/// Importer-layer error domain for the Phase 3 shortcut-voice import pipeline.
///
/// Distinct from Phase 2's `ShortcutYAMLError` (which is parser-side and pure-value:
/// it only depends on the raw input string). Cases here require **importer state**
/// — the current voice-trigger hotkey and the `HotkeyRegistry` of owned bindings —
/// to detect, so they cannot live on the parser enum.
///
/// Audit-log `kind:` string mapping is the canonical source documented in
/// `.planning/phases/03-importer-audit-log-safety-gates/03-CONTEXT.md`
/// `<specifics>` "Error → kind mapping table":
///   - `actionTriggersVoiceKey` → `"actionTriggersVoiceKey"`
///   - `ownedTriggerCollision`  → `"ownedTriggerCollision"`
/// The enum-to-JSON conversion happens at the audit-log writer (per D-C-3),
/// NOT on this enum.
///
/// Security: `triggerSource` and `owner` are attacker-controlled string payloads
/// (the raw trigger / owner name flows from the LLM-generated YAML through the
/// importer). The importer MUST truncate these to 64 chars **at the throw site**
/// — consumer-side truncation, NOT enum-side — mirroring Phase 2's 64-char
/// `offendingToken` truncation contract (T-03-02-02).
enum ShortcutImporterError: Error, Equatable {
    /// A `.keyPress` action's `(keyCode, modifiers)` matched the current voice-trigger
    /// hotkey OR any `HotkeyRegistry.Owner`-registered config. The importer rejects
    /// the binding without inserting; the failure is audit-logged but no exception
    /// surfaces to the user beyond the status-line outcome.
    ///
    /// `triggerSource` is `"voice"` for a voice-trigger match, or the owner's
    /// case name for a registry match. Truncated to 64 chars at the throw site.
    case actionTriggersVoiceKey(triggerSource: String)

    /// Reserved for future expansion. The current IMP-05 gate uses
    /// `actionTriggersVoiceKey` for both voice-trigger and owned-trigger
    /// collisions; this case is declared for forward compat so consumers can
    /// match a stable exhaustive switch when the gate is split.
    ///
    /// `owner` is the `HotkeyRegistry.Owner` case name. Truncated to 64 chars
    /// at the throw site.
    case ownedTriggerCollision(owner: String)
}
