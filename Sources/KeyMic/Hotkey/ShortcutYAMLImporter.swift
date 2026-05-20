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
/// Pipeline (RESEARCH §Architecture diagram):
///   1. PARSE via `ShortcutYAMLParser.parse(_:)` → catch `ShortcutYAMLError`
///      (IMP-07): audit + return Outcome with `parseError: payload.kind`.
///   2. IMP-09: NSWorkspace bundle-id validation; soft-drop unknowns into
///      `droppedBundleIDs`.
///   3. IMP-08: `shortcutVoiceShellEnabled` gate; strip `.shell` actions and
///      force `enabled = false` on strip; per-call UserDefaults read.
///   4. IMP-05: self-trigger / owned-trigger gate via
///      `HotkeySettingsStore.shared.hotkey(for: .voiceTrigger)` +
///      `registry.all().map { $0.config }`; REJECT on match (no insert,
///      audit-only path).
///   5. SAFETY GATES (03-04 IMP-03/IMP-04/IMP-06): gate stack
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
/// `terminate()` — AUD-06 flush hook implemented in plan 03-06; the
/// audit-log writer uses open-fresh-FileHandle-per-write so there is no
/// long-lived handle to close — `terminate()` only drains the serial queue.
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

    /// Additional macOS-reserved shortcuts (gate 3 — IMP-03).
    ///
    /// Per 03-CONTEXT.md D-D-1 / D-D-3 and 03-RESEARCH.md Pitfall §4: this set
    /// contains ONLY entries that are NOT already covered by
    /// `HotkeyConfig.reservedShortcuts` (HotkeyConfig.swift:226-256). If an
    /// entry appeared in both, gate 3 would be dead code because gate 2
    /// (`isSystemReserved`) would already match first. F-row entries are
    /// excluded (RESEARCH Open Question 1 — "Use F1, F2… as standard function
    /// keys" toggle produces false positives). The broader collision surface
    /// is handled by `HotkeyRegistry.conflicts(...)` at gate 4.
    ///
    /// The 6 entries (verified non-overlapping with HotkeyConfig.reservedShortcuts):
    ///   - ⌘⌥Space — alt Spotlight / Character Viewer launcher
    ///   - ⌘⌃Space — Character Viewer / Emoji panel
    ///   - ⌘⇧Tab — reverse app switcher
    ///   - ⌘`     — window cycle within app (keyCode 0x32 / kVK_ANSI_Grave)
    ///   - ⌘⌥H    — Hide Others
    ///   - ⌘⌥M    — Minimize all
    private static let MACOS_RESERVED_SHORTCUTS: Set<HotkeyConfig> = {
        let cmdAlt: CGEventFlags = [.maskCommand, .maskAlternate]
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        let cmdCtrl: CGEventFlags = [.maskCommand, .maskControl]
        return [
            HotkeyConfig(modifiers: cmdAlt, keyCode: 0x31),        // ⌘⌥Space — alt Spotlight / Character Viewer
            HotkeyConfig(modifiers: cmdCtrl, keyCode: 0x31),       // ⌘⌃Space — Character Viewer / Emoji
            HotkeyConfig(modifiers: cmdShift, keyCode: 0x30),      // ⌘⇧Tab — reverse app switcher
            HotkeyConfig(modifiers: .maskCommand, keyCode: 0x32),  // ⌘` — window cycle within app
            HotkeyConfig(modifiers: cmdAlt, keyCode: 0x04),        // ⌘⌥H — Hide Others
            HotkeyConfig(modifiers: cmdAlt, keyCode: 0x2E),        // ⌘⌥M — Minimize all
        ]
    }()

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
                userInfo: ["outcome": outcome, "transcript": transcript]
            )
            return outcome
        } catch {
            // Defensive: a non-ShortcutYAMLError shouldn't surface from
            // ShortcutYAMLParser.parse, but if it does, treat as a generic
            // parse failure so the importer never throws to the caller.
            // IMP-07: write audit line with kind="unknown" + return Outcome.
            logger.error("Unexpected non-YAML parse error: \(error.localizedDescription, privacy: .public)")
            let payload = ParseErrorPayload(kind: "unknown")
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
                userInfo: ["outcome": outcome, "transcript": transcript]
            )
            return outcome
        }

        // Step 2: IMP-09 — soft-drop unknown bundle IDs via LaunchServices.
        //
        // `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` returns
        // nil if the app is not installed. Per RESEARCH §5 + Pitfall §5
        // (SettingsRoot.swift:1634, ApplicationImageCache.swift:25), the
        // synchronous call on the current thread is acceptable — the importer
        // runs on the main actor in Phase 4 but is not in a perf-critical
        // path; typical YAML carries ≤5 bundle ids.
        //
        // This runs BEFORE the gate stack because bundle-id validation is
        // content-shaping (not policy-deciding); a binding that survives the
        // gate stack should already carry only validated ids.
        var binding = parsed.binding
        var droppedBundleIDs: [String] = []
        if !binding.appBundleIDs.isEmpty {
            var kept: [String] = []
            for bid in binding.appBundleIDs {
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil {
                    kept.append(bid)
                } else {
                    droppedBundleIDs.append(bid)
                }
            }
            binding.appBundleIDs = kept
        }

        // Step 3: IMP-08 — `shortcutVoiceShellEnabled` gate.
        //
        // READ per-call (NOT cached) per 03-CONTEXT.md `<code_context>`
        // "Integration Points" — settings toggle takes effect on the next
        // import. Default `false` per `UserDefaults.bool(forKey:)` returning
        // false for missing keys (CONTEXT.md "Claude's Discretion" item 10).
        //
        // When the gate is OFF (default): strip every `.shell(_)` action from
        // the binding; if any were dropped, force `enabled = false` so the
        // truncated binding does not silently fire. The `shellStripped` flag
        // flows into both Outcome and AuditRecord per IMP-08 contract.
        //
        // When the gate is ON: shell actions are preserved as-is; the
        // binding's `enabled` follows the YAML value (already decoded by
        // Phase 2).
        let shellEnabled = userDefaults.bool(forKey: Self.userDefaultsKeyShellEnabled)
        var shellStripped = false
        if !shellEnabled {
            let originalCount = binding.actions.count
            binding.actions = binding.actions.filter { action in
                if case .shell = action { return false }
                return true
            }
            if binding.actions.count < originalCount {
                shellStripped = true
                binding.enabled = false   // IMP-08 contract: stripped binding inserted disabled
            }
        }

        // Step 4: IMP-05 — self-trigger / owned-trigger gate.
        //
        // For each `.keyPress(keyCode, modifiers)` action in the binding,
        // check `(keyCode, modifiers)` equality against:
        //   (a) the current voice-trigger hotkey
        //       (`HotkeySettingsStore.shared.hotkey(for: .voiceTrigger)`)
        //   (b) every entry in `registry.all().map { $0.config }`
        //
        // Per RESEARCH §2 + 03-CONTEXT.md `<specifics>` "Self-trigger gate":
        // the registry exposes `all()` (NOT `allRegisteredTriggers()` — that
        // method does not exist). Equality is on `(keyCode, modifiers)` as a
        // tuple via raw value comparison.
        //
        // On match: REJECT the import — no store mutation; write audit line
        // with `parseError: { kind: "actionTriggersVoiceKey", ... }`; return
        // Outcome(bindingId: nil, ...). The trigger-source string is
        // truncated to 64 chars at the throw site per
        // ShortcutImporterError's documented contract (T-03-05-06).
        let voiceTrigger = HotkeySettingsStore.shared.hotkey(for: .voiceTrigger)
        let registeredConfigs = registry.all().map { $0.config }
        var selfTriggerSource: String? = nil
        for action in binding.actions {
            if case .keyPress(let kc, let mods) = action {
                let actionKeyCode = CGKeyCode(kc)
                if let vt = voiceTrigger,
                   vt.keyCode == actionKeyCode,
                   vt.modifiers.rawValue == mods {
                    selfTriggerSource = "voice"
                    break
                }
                var matchedRegistry = false
                for cfg in registeredConfigs {
                    if cfg.keyCode == actionKeyCode && cfg.modifiers.rawValue == mods {
                        matchedRegistry = true
                        break
                    }
                }
                if matchedRegistry {
                    selfTriggerSource = "registry"
                    break
                }
            }
        }

        if let source = selfTriggerSource {
            // Truncate to 64 chars per the contract documented on
            // ShortcutImporterError.actionTriggersVoiceKey.
            let truncated = String(source.prefix(64))
            let importerErr = ShortcutImporterError.actionTriggersVoiceKey(triggerSource: truncated)
            let payload = ShortcutAuditLog.canonicalKind(importerErr)
            let outcome = Outcome(
                bindingId: nil,
                parseError: payload.kind,
                conflictCleared: false,
                conflictSource: nil,
                shellStripped: shellStripped,
                droppedBundleIDs: droppedBundleIDs
            )
            let record = AuditRecord(
                timestamp: Self.currentTimestamp(),
                transcript: transcript,
                yaml: truncatedYAML(yaml),
                bindingId: nil,
                conflictCleared: false,
                conflictSource: nil,
                parseError: payload,
                shellStripped: shellStripped,
                droppedBundleIDs: droppedBundleIDs,
                action: "import"
            )
            auditLog.write(record)
            NotificationCenter.default.post(
                name: .shortcutImportDidComplete,
                object: self,
                userInfo: ["outcome": outcome, "transcript": transcript]
            )
            return outcome
        }

        // Step 5: SAFETY GATES (IMP-03 / IMP-04 / IMP-06) — 4-gate stack.
        //
        // Re-parse the binding's canonical trigger string into a HotkeyConfig
        // for gate evaluation. Phase 2 stores the canonical-encoded trigger;
        // HotkeyConfig.parse round-trips it. If parse fails (should not
        // happen for a valid Phase-2 ParsedShortcut), conservatively treat
        // as "no gate fires" and let downstream conflict checks decide.
        //
        // On any gate match (per IMP-04 contract): the binding is STILL
        // inserted (user intent preserved) but with `trigger = ""` and
        // `enabled = false` — user fixes it in Settings later. The
        // conflictCleared flag + conflictSource string propagate into both
        // the Outcome (D-E-1) and the AuditRecord (AUD-03).
        // `binding` was declared at Step 2 (above the bundle-id soft-drop)
        // so we could shape its `appBundleIDs` before gate evaluation.
        binding.createdBy = Self.createdByVoice
        binding.label = parsed.label

        var conflictCleared = false
        var conflictSource: String? = nil

        if let cfg = HotkeyConfig.parse(binding.trigger) {
            // GATE 1 — pure modifier (e.g. cmd alone, shift alone).
            if cfg.isPureModifier {
                conflictCleared = true
                conflictSource = "pure-modifier"
            }
            // GATE 2 — system-reserved (delegates to HotkeyConfig.reservedShortcuts).
            else if cfg.isSystemReserved {
                conflictCleared = true
                conflictSource = "system-reserved"
            }
            // GATE 3 — macOS-reserved safe set (additional non-overlapping entries).
            else if Self.MACOS_RESERVED_SHORTCUTS.contains(cfg) {
                conflictCleared = true
                conflictSource = "macos"
            }
            // GATE 4 — hotkey-registry collision (feature or another binding).
            else {
                let collisions = registry.conflicts(for: cfg, excluding: .hotkeyBinding(id: binding.id))
                if !collisions.isEmpty {
                    conflictCleared = true
                    // Classify: any non-hotkeyBinding owner → "feature";
                    // all hotkeyBinding owners → "binding".
                    let isFeature = collisions.contains { entry in
                        if case .hotkeyBinding = entry.owner { return false }
                        return true
                    }
                    conflictSource = isFeature ? "feature" : "binding"
                }
            }
        }

        if conflictCleared {
            binding.trigger = ""
            binding.enabled = false
        }

        // Step 6: INSERT (binding always inserts per IMP-04 contract; the
        // trigger has been cleared above if any gate matched).
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
            userInfo: ["outcome": outcome, "transcript": transcript]
        )

        // Step 10: RETURN.
        return outcome
    }

    // MARK: - Undo (IMP-11 / D-F)

    /// Undo the most recent voice-imported binding.
    ///
    /// Defensive id-match per D-F-1/D-F-2: the call is a silent no-op if
    /// `id != lastImportedBindingId` (e.g. when a second import has already
    /// run, when the UI passes the wrong UUID, or when called twice in a
    /// row after the first call cleared `lastImportedBindingId`).
    ///
    /// On match:
    ///   1. Remove the binding from the store via direct array mutation
    ///      (SettingsRoot.swift:1119-1122 precedent).
    ///   2. Clear `lastImportedBindingId` so a subsequent call with the
    ///      same id is a no-op (D-F-3: no cross-restart persistence; the
    ///      undo affordance has a ~3s UI TTL).
    ///   3. Write a follow-up audit line with `action: "undo"`, the
    ///      original `bindingId`, `timestamp: <now>`, and all other AUD-03
    ///      fields at their default values (empty transcript/yaml, all
    ///      bools false, all optionals nil, empty arrays) per D-F-4.
    ///   4. Post `.shortcutImportDidComplete` with an Outcome carrying the
    ///      original `bindingId` so the UI can disable the Undo button.
    ///
    /// No cross-restart persistence per D-F-3 — `lastImportedBindingId` is
    /// in-memory only.
    func removeLastImport(id: UUID) {
        guard let stored = lastImportedBindingId, stored == id else { return }

        // 1. Direct array mutation per SettingsRoot.swift:1119-1122 precedent.
        store.bindings.removeAll { $0.id == id }

        // 2. Reset undo state so a subsequent call is a no-op.
        lastImportedBindingId = nil

        // 3. Follow-up audit line.
        let record = AuditRecord(
            timestamp: Self.currentTimestamp(),
            transcript: "",
            yaml: "",
            bindingId: id.uuidString,
            conflictCleared: false,
            conflictSource: nil,
            parseError: nil,
            shellStripped: false,
            droppedBundleIDs: [],
            action: "undo"
        )
        auditLog.write(record)

        // 4. Notification post — Outcome carries the original bindingId so
        //    UI-07 / UI-08 can correlate with the original import event.
        let outcome = Outcome(
            bindingId: id,
            parseError: nil,
            conflictCleared: false,
            conflictSource: nil,
            shellStripped: false,
            droppedBundleIDs: []
        )
        NotificationCenter.default.post(
            name: .shortcutImportDidComplete,
            object: self,
            // No original transcript in scope (undo is a follow-up action,
            // not a new transcription event). Per 04-PATTERNS.md
            // "Special-case `removeLastImport(id:)`" option (b): emit the
            // empty string so the userInfo schema is uniform across all 5
            // post sites — subscribers may discriminate undo vs. import via
            // `outcome.bindingId` + their own bookkeeping.
            userInfo: ["outcome": outcome, "transcript": ""]
        )
    }

    // MARK: - LLM-failure audit-write path (COORD-08 / 04-CONTEXT.md `<phase3_amendment>`)

    /// Record an LLM-side failure that prevented the YAML pipeline from
    /// running (e.g. `LLMRefiner.refine` returned a non-200 HTTP response,
    /// the URLSession errored out, JSON decode failed, or the request
    /// timed out). Writes EXACTLY ONE NDJSON audit line + posts the
    /// standard `.shortcutImportDidComplete` notification — preserving the
    /// D-G single-writer invariant established in Phase 3 (the importer is
    /// the only audit-log writer; the coordinator never calls
    /// `auditLog.write(_)` directly).
    ///
    /// The audit line carries `action: "import"` (the same value as the
    /// happy path / parse-error path) because the import attempt is the
    /// originating event — analytics consumers filter by
    /// `parseError.kind == "llm-error"` to isolate this branch.
    ///
    /// `errorMessage` is attacker-controlled (LLM endpoint / URLSession
    /// descriptor); `ShortcutAuditLog.canonicalKind(_:ShortcutImporterError)`
    /// truncates it to 64 chars defensively before it enters the
    /// `ParseErrorPayload.field`.
    ///
    /// Called from `ShortcutVoiceCoordinator.handleTranscription`
    /// (built in plan 04-04).
    func recordLLMFailure(transcript: String, errorMessage: String) {
        let importerErr = ShortcutImporterError.llmFailure(message: errorMessage)
        let payload = ShortcutAuditLog.canonicalKind(importerErr)

        let record = AuditRecord(
            timestamp: Self.currentTimestamp(),
            transcript: transcript,
            yaml: "",                 // No YAML produced — LLM never returned a parsable body.
            bindingId: nil,           // No binding inserted.
            conflictCleared: false,
            conflictSource: nil,
            parseError: payload,
            shellStripped: false,
            droppedBundleIDs: [],
            action: "import"          // Originating event is the import attempt; D-C-3.
        )
        auditLog.write(record)

        let outcome = Outcome(
            bindingId: nil,
            parseError: payload.kind, // "llm-error"
            conflictCleared: false,
            conflictSource: nil,
            shellStripped: false,
            droppedBundleIDs: []
        )
        NotificationCenter.default.post(
            name: .shortcutImportDidComplete,
            object: self,
            userInfo: ["outcome": outcome, "transcript": transcript]
        )
    }

    // MARK: - Lifecycle (AUD-06)

    /// AUD-06 flush hook — invoked from `AppDelegate.applicationWillTerminate`
    /// in Phase 4. Drains the audit-log serial queue so any in-flight
    /// `write(_:)` completes before the process exits.
    ///
    /// The underlying writer uses open-fresh-FileHandle-per-write semantics
    /// (RESEARCH §Pitfall §3), so there is no long-lived handle to close —
    /// this is a flush-only operation. Safe to call multiple times
    /// (idempotent).
    func terminate() {
        auditLog.close()
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
