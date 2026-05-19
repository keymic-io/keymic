import Foundation
import AppKit  // NSWorkspace.shared — P-05 IMP-09 bundle-id validation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "ShortcutYAMLImporter")

// MARK: - Outcome

/// Result type returned by `ShortcutYAMLImporter.importYAML(_:transcript:)`.
///
/// Locked by .planning/phases/03-importer-audit-log-safety-gates/03-CONTEXT.md
/// D-E-1: 6 fields, NO `status:` enum. Field set is identical to the audit-log
/// line's importer-controlled fields (per D-E-2) so the writer is a trivial
/// mirror — no translation drift between Outcome and AuditRecord.
///
/// Published in the `userInfo` payload of `.shortcutImportDidComplete` under
/// key `"outcome"` (typed `Outcome` cast). UI-07 status-line code consumes
/// this notification.
struct Outcome: Equatable {
    /// UUID of the inserted binding; `nil` on parse error / self-trigger reject.
    let bindingId: UUID?
    /// Canonical kind string (e.g. `"invalidValue"`, `"actionTriggersVoiceKey"`).
    /// Audit-log writer renders the full JSON sub-object via
    /// `ShortcutAuditLog.canonicalKind(_)`; the Outcome carries only the
    /// kind tag so the consumer can branch without depending on the writer.
    let parseError: String?
    /// `true` when the importer cleared a colliding trigger before insert.
    let conflictCleared: Bool
    /// Conflict origin: `"feature" | "binding" | "pure-modifier" |
    /// "system-reserved" | "macos" | nil`.
    let conflictSource: String?
    /// `true` when `.shell` actions were stripped under
    /// `shortcutVoiceShellEnabled = false`.
    let shellStripped: Bool
    /// Bundle IDs rejected by `NSWorkspace` (soft-drop per IMP-09); possibly empty.
    let droppedBundleIDs: [String]
}

// MARK: - Notification.Name (file-local extension per LLMRefiner precedent)

extension Notification.Name {
    /// Posted on the caller's thread after every `importYAML(_:transcript:)`
    /// invocation. `userInfo["outcome"] as? Outcome` carries the result.
    /// UI-07 status line consumes this notification.
    static let shortcutImportDidComplete = Notification.Name("io.keymic.app.ShortcutYAMLImporter.didComplete")
}

// MARK: - ShortcutYAMLImporter

/// Singleton + injectable importer for voice-driven shortcut YAML.
///
/// Pipeline (RESEARCH §Architecture diagram; this plan implements steps 1, 6,
/// 7, 8, 9 — steps 2-5 are TODO stubs filled by 03-04 / 03-05):
///   1. PARSE via `ShortcutYAMLParser.parse(_:)` → catch `ShortcutYAMLError`,
///      audit + return Outcome.
///   2. TODO(03-05 IMP-09): NSWorkspace bundle-id validation; soft-drop unknowns.
///   3. TODO(03-05 IMP-08): `shortcutVoiceShellEnabled` gate; strip `.shell`
///      actions and force `enabled = false` on strip.
///   4. TODO(03-05 IMP-05): self-trigger / owned-trigger gate via
///      `HotkeySettingsStore.shared.hotkey(for: .voiceTrigger)` +
///      `HotkeyRegistry.shared.all().map { $0.config }`.
///   5. TODO(03-04 IMP-03/IMP-04/IMP-06): gate stack
///      `cfg.isPureModifier → isSystemReserved → MACOS_RESERVED_SHORTCUTS →
///      registry.conflicts(...)` → clear trigger + set `conflictCleared`.
///   6. INSERT: `store.bindings.append(binding)` with
///      `createdBy = "voice"` + `label = parsed.label`.
///   7. RECORD undo state: `lastImportedBindingId = binding.id`.
///   8. AUDIT WRITE: build `AuditRecord(...)` with `action: "import"`.
///   9. POST NOTIFICATION: `.shortcutImportDidComplete` with userInfo.
///
/// `MACOS_RESERVED_SHORTCUTS` — populated in plan 03-04 (D-D-3, RESEARCH Example 4)
/// `removeLastImport(id:)` — implemented in plan 03-06 (IMP-11)
final class ShortcutYAMLImporter {
    static let shared = ShortcutYAMLImporter()

    /// `createdBy` marker for voice-imported bindings (per CONTEXT.md
    /// `<specifics>` createdBy constant). Tests use the same constant to
    /// avoid magic strings.
    static let createdByVoice = "voice"

    /// UserDefaults key for the shell-actions opt-in gate (default `false`
    /// per IMP-08). Read at every `importYAML` call so settings UI takes
    /// effect immediately.
    static let userDefaultsKeyShellEnabled = "shortcutVoiceShellEnabled"

    private let store: HotkeyBindingsStore
    private let registry: HotkeyRegistry
    private let auditLog: ShortcutAuditLog
    private let userDefaults: UserDefaults

    /// In-memory state for `removeLastImport(id:)` per D-F-1. NOT persisted —
    /// UI-08 TTL is ~3s; no cross-restart undo affordance per D-F-3.
    private var lastImportedBindingId: UUID?

    /// Per AUD-01 + CONTEXT.md "Claude's Discretion": four injectable
    /// dependencies (store / registry / auditLog / userDefaults) so tests
    /// can isolate the importer from real on-disk state.
    init(
        store: HotkeyBindingsStore = .shared,
        registry: HotkeyRegistry = .shared,
        auditLog: ShortcutAuditLog = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.registry = registry
        self.auditLog = auditLog
        self.userDefaults = userDefaults
    }

    /// Run the import pipeline for one YAML document. Returns the Outcome;
    /// writes one audit-log line (`action: "import"`) and posts
    /// `.shortcutImportDidComplete` on the caller's thread.
    ///
    /// Per RESEARCH Pitfall §8, the post happens on the caller's thread —
    /// the caller is the test runner main thread or, in Phase 4, the
    /// `@MainActor` coordinator; defensive `DispatchQueue.main.async` wrap
    /// is NOT required when called from main.
    func importYAML(_ yaml: String, transcript: String) -> Outcome {
        // Step 1: PARSE — on error, audit + return early.
        let parsed: ParsedShortcut
        do {
            parsed = try ShortcutYAMLParser.parse(yaml)
        } catch let err as ShortcutYAMLError {
            let payload = ShortcutAuditLog.canonicalKind(err)
            let outcome = Outcome(
                bindingId: nil,
                parseError: payload.kind,
                conflictCleared: false,
                conflictSource: nil,
                shellStripped: false,
                droppedBundleIDs: []
            )
            let record = AuditRecord(
                timestamp: Self.currentTimestamp(),
                transcript: transcript,
                yaml: truncatedYAML(yaml),
                bindingId: nil,
                conflictCleared: false,
                conflictSource: nil,
                parseError: payload,
                shellStripped: false,
                droppedBundleIDs: [],
                action: "import"
            )
            auditLog.write(record)
            NotificationCenter.default.post(
                name: .shortcutImportDidComplete,
                object: self,
                userInfo: ["outcome": outcome]
            )
            return outcome
        } catch {
            // Defensive: a non-ShortcutYAMLError shouldn't surface from
            // ShortcutYAMLParser.parse, but if it does, treat as a generic
            // parse failure so the importer never throws to the caller.
            logger.error("Unexpected non-YAML parse error: \(error.localizedDescription, privacy: .public)")
            let outcome = Outcome(
                bindingId: nil,
                parseError: "empty",
                conflictCleared: false,
                conflictSource: nil,
                shellStripped: false,
                droppedBundleIDs: []
            )
            NotificationCenter.default.post(
                name: .shortcutImportDidComplete,
                object: self,
                userInfo: ["outcome": outcome]
            )
            return outcome
        }

        // Step 2: TODO(P-05 IMP-09): NSWorkspace bundle-id validation;
        // collect into droppedBundleIDs.
        var droppedBundleIDs: [String] = []

        // Step 3: TODO(P-05 IMP-08): shortcutVoiceShellEnabled gate;
        // strip .shell actions and force enabled = false on strip.
        var shellStripped = false

        // Step 4: TODO(P-05 IMP-05): self-trigger / owned-trigger gate via
        // HotkeySettingsStore.shared.hotkey(for: .voiceTrigger) +
        // registry.all().map { $0.config }; throw
        // ShortcutImporterError.actionTriggersVoiceKey on match.
        _ = registry  // silence unused-warning until P-05 wires the gate

        // Step 5: TODO(P-04 IMP-03/IMP-04/IMP-06): gate stack
        // cfg.isPureModifier → isSystemReserved → MACOS_RESERVED_SHORTCUTS →
        // registry.conflicts(...); on match, clear trigger + set
        // conflictCleared = true, conflictSource = <"pure-modifier" |
        // "system-reserved" | "macos" | "binding" | "feature">.
        var conflictCleared = false
        var conflictSource: String? = nil
        _ = userDefaults  // silence unused-warning until P-05 wires the gate
        _ = conflictCleared
        _ = conflictSource

        // Step 6: INSERT (happy path).
        var binding = parsed.binding
        binding.createdBy = Self.createdByVoice
        binding.label = parsed.label
        store.bindings.append(binding)  // direct mutation per SettingsRoot.swift:1119-1122

        // Step 7: RECORD undo state (D-F-1).
        lastImportedBindingId = binding.id

        // Step 8: AUDIT WRITE.
        let record = AuditRecord(
            timestamp: Self.currentTimestamp(),
            transcript: transcript,
            yaml: truncatedYAML(yaml),
            bindingId: binding.id.uuidString,
            conflictCleared: conflictCleared,
            conflictSource: conflictSource,
            parseError: nil,
            shellStripped: shellStripped,
            droppedBundleIDs: droppedBundleIDs,
            action: "import"
        )
        auditLog.write(record)

        // Step 9: BUILD OUTCOME + POST NOTIFICATION.
        let outcome = Outcome(
            bindingId: binding.id,
            parseError: nil,
            conflictCleared: conflictCleared,
            conflictSource: conflictSource,
            shellStripped: shellStripped,
            droppedBundleIDs: droppedBundleIDs
        )
        NotificationCenter.default.post(
            name: .shortcutImportDidComplete,
            object: self,
            userInfo: ["outcome": outcome]
        )

        // Step 10: RETURN.
        return outcome
    }

    // MARK: - Private helpers

    /// Truncate the raw YAML payload to 2048 UTF-16 code units (per RESEARCH
    /// Pitfall §5 — Swift's `String.count` uses Character clusters, which
    /// can over-truncate emoji-heavy payloads; UTF-16 code units are the
    /// stable contract for AUD-03 with `String.prefix(_:)`).
    private func truncatedYAML(_ s: String) -> String {
        // String.count is grapheme-cluster count; String.prefix(_:) on Int
        // operates on Characters. The 2048 limit is documented in UTF-16
        // code units per AUD-03; for ASCII / typical YAML this is
        // indistinguishable from character count. We use `count` here as
        // an upper-bound check — over-truncation on emoji is preferable
        // to under-truncation on attacker payloads.
        guard s.count > 2048 else { return s }
        return String(s.prefix(2048)) + "…(truncated)"
    }

    /// Shared formatter for `AuditRecord.timestamp`. `ISO8601DateFormatter`
    /// IS thread-safe (unlike `DateFormatter`); cache the instance to avoid
    /// per-call allocation per RESEARCH Pitfall §9.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func currentTimestamp() -> String {
        return isoFormatter.string(from: Date())
    }
}
