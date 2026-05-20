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
///   - `llmFailure`             → `"llm-error"` (Phase 4 amendment per
///     04-CONTEXT.md `<phase3_amendment>` — coordinator audit-write path
///     for `LLMRefiner.refine` failures / network errors / non-200 HTTP).
/// The enum-to-JSON conversion happens at the audit-log writer (per D-C-3),
/// NOT on this enum.
///
/// Security: `triggerSource`, `owner`, and `message` are attacker-controlled
/// string payloads (the raw trigger / owner name / LLM error description
/// flows from untrusted input — LLM endpoint / URLSession error / YAML —
/// through the importer). The importer MUST truncate these to 64 chars
/// **at the throw site** — consumer-side truncation, NOT enum-side —
/// mirroring Phase 2's 64-char `offendingToken` truncation contract
/// (T-03-02-02). `canonicalKind(_:ShortcutImporterError)` defensively
/// re-truncates at the conversion site.
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

    /// LLM-side failure raised by `ShortcutVoiceCoordinator.handleTranscription`
    /// (Phase 4, plan 04-04) when `LLMRefiner.refine` errors out — non-200
    /// HTTP response, URLSession error, JSON-decode failure, or timeout.
    ///
    /// The importer's audit-write path is the SINGLE writer of audit lines
    /// (D-G single-writer invariant). The coordinator therefore calls
    /// `ShortcutYAMLImporter.recordLLMFailure(transcript:errorMessage:)`
    /// instead of writing an audit line directly — that helper constructs
    /// `ShortcutImporterError.llmFailure(message:)`, runs it through
    /// `ShortcutAuditLog.canonicalKind(_)` to obtain
    /// `ParseErrorPayload(kind: "llm-error", field: <truncated message>)`,
    /// and persists exactly one NDJSON line + posts the standard
    /// `.shortcutImportDidComplete` notification.
    ///
    /// `message` is a user-opaque error description (e.g. `"Connection
    /// refused"`, `"HTTP 503"`, `"timeout after 10s"`). Truncated to 64
    /// chars at the throw site; `canonicalKind` re-truncates defensively.
    case llmFailure(message: String)
}
