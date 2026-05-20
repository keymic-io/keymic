import Foundation
import os

// MARK: - ParseErrorPayload

/// JSON sub-object payload for the `parseError` field in audit-log records.
///
/// Locked by .planning/phases/03-importer-audit-log-safety-gates/03-CONTEXT.md
/// D-C-1: shape is `{ "kind": String, "field": String?, "line": Int?, "token": String? }`,
/// or `null` when no parse error occurred. `kind` is always present (canonical
/// lowercase enum-case name); the other three are omitted-or-null per case.
///
/// Field-order is locked by CodingKeys declaration order for stable JSON output
/// per RESEARCH §Pitfall §6.
///
/// Consumers should treat `null` and missing-field as equivalent — the
/// synthesized `encode(to:)` emits `null` for nil optionals; this is acceptable
/// per RESEARCH §Pitfall §7 and is documented as the audit-log contract.
struct ParseErrorPayload: Codable, Equatable {
    let kind: String
    let field: String?
    let line: Int?
    let token: String?

    init(kind: String, field: String? = nil, line: Int? = nil, token: String? = nil) {
        self.kind = kind
        self.field = field
        self.line = line
        self.token = token
    }

    private enum CodingKeys: String, CodingKey {
        case kind, field, line, token
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.field = try c.decodeIfPresent(String.self, forKey: .field)
        self.line = try c.decodeIfPresent(Int.self, forKey: .line)
        self.token = try c.decodeIfPresent(String.self, forKey: .token)
    }

    /// Explicit `encode(to:)` for the same field-order reason as `AuditRecord`:
    /// synthesized JSONEncoder output is NOT order-stable across Foundation
    /// implementations. We emit `kind` (always present) + the three optional
    /// fields via `encodeIfPresent` so `null`s are omitted (cleaner sub-object).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(field, forKey: .field)
        try c.encodeIfPresent(line, forKey: .line)
        try c.encodeIfPresent(token, forKey: .token)
    }
}

// MARK: - AuditRecord

/// Wire-format struct for one line of `shortcut-voice-audit.log` (NDJSON).
///
/// 10 fields in CodingKeys declaration order per AUD-03 (post-03-01 doc-fix)
/// + .planning/phases/03-importer-audit-log-safety-gates/03-CONTEXT.md
/// `<specifics>` "Audit log line shape" (lines 226-241).
///
/// Field order is load-bearing for `jq`-friendly diffs and the EVAL-01 v2
/// pipeline; do NOT add a custom `encode(to:)` — rely on the synthesized
/// encoder + CodingKeys ordering per RESEARCH §Pitfall §6.
///
/// Truncation of `yaml` to 2048 UTF-16 code units (with `…(truncated)` suffix)
/// is the CALLER's responsibility (the writer trusts the importer); the unit
/// choice is documented at the truncation call site per RESEARCH §Pitfall §5.
struct AuditRecord: Codable, Equatable {
    /// ISO-8601 with fractional seconds + Z (e.g. `"2026-05-19T12:34:56.789Z"`).
    let timestamp: String
    /// Raw user speech, never null (empty string is valid).
    let transcript: String
    /// Raw LLM output, truncated to 2048 UTF-16 code units by the caller.
    let yaml: String
    /// UUID string for the inserted binding, or `nil` on parse error / reject.
    let bindingId: String?
    /// `true` when the importer cleared a colliding trigger before insert.
    let conflictCleared: Bool
    /// `"feature" | "binding" | "pure-modifier" | "system-reserved" | "macos" | nil`.
    let conflictSource: String?
    /// JSON sub-object for parser/importer errors, or `nil` on success.
    let parseError: ParseErrorPayload?
    /// `true` when `.shell` actions were stripped under `shortcutVoiceShellEnabled=false`.
    let shellStripped: Bool
    /// Bundle IDs rejected by `NSWorkspace` (soft-drop per IMP-09); possibly empty.
    let droppedBundleIDs: [String]
    /// `"import"` for normal lines; `"undo"` for follow-up lines from `removeLastImport`.
    let action: String

    private enum CodingKeys: String, CodingKey {
        case timestamp, transcript, yaml, bindingId, conflictCleared,
             conflictSource, parseError, shellStripped, droppedBundleIDs, action
    }

    init(
        timestamp: String,
        transcript: String,
        yaml: String,
        bindingId: String?,
        conflictCleared: Bool,
        conflictSource: String?,
        parseError: ParseErrorPayload?,
        shellStripped: Bool,
        droppedBundleIDs: [String],
        action: String
    ) {
        self.timestamp = timestamp
        self.transcript = transcript
        self.yaml = yaml
        self.bindingId = bindingId
        self.conflictCleared = conflictCleared
        self.conflictSource = conflictSource
        self.parseError = parseError
        self.shellStripped = shellStripped
        self.droppedBundleIDs = droppedBundleIDs
        self.action = action
    }

    /// Explicit `encode(to:)` locks JSON key emission to CodingKeys declaration
    /// order per RESEARCH §Pitfall §6. The synthesized encoder does NOT
    /// guarantee declaration order across Swift versions / Foundation
    /// implementations (observed: keys emit in declaration-reverse-ish /
    /// hash order with JSONEncoder.outputFormatting = [], breaking the
    /// `jq`-friendly diff contract and the EVAL-01 v2 pipeline). Emitting
    /// each key explicitly in declaration order is the only reliable lock.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(yaml, forKey: .yaml)
        // `encode(_:forKey:)` on an Optional emits `null` for nil — matches
        // the audit-log contract (null-or-omitted are equivalent per D-C-1).
        try c.encode(bindingId, forKey: .bindingId)
        try c.encode(conflictCleared, forKey: .conflictCleared)
        try c.encode(conflictSource, forKey: .conflictSource)
        try c.encode(parseError, forKey: .parseError)
        try c.encode(shellStripped, forKey: .shellStripped)
        try c.encode(droppedBundleIDs, forKey: .droppedBundleIDs)
        try c.encode(action, forKey: .action)
    }
}

// MARK: - ShortcutAuditLog

/// NDJSON writer for the shortcut-voice audit log.
///
/// Default URL: `~/Library/Application Support/KeyMic/shortcut-voice-audit.log`
/// (per AUD-01). Mirrors `Sources/KeyMic/Tools/Shell/ShellLogger.swift` as the
/// structural template — same serial queue, same open-fresh-per-write pattern,
/// same 5MB rotation rule (`.log` → `.log.1`, single backup only) — with these
/// deltas from ShellLogger:
///   1. Default URL uses `applicationSupportDirectory` (NOT `~/Library/Logs`).
///   2. `format()` emits JSON via `JSONEncoder` + trailing `\n` (NDJSON).
///   3. `append()` calls `try handle.synchronize()` per AUD-04 fsync contract.
///   4. Pubic API surface: `write(_:)` + `flushForTesting()` + `close()`
///      (no `log(_:)` — that name is taken by `ShellLogger`).
///
/// Concurrency: all writes go through the internal serial queue; per-write
/// file-handle open ensures rotation safety (RESEARCH §Pitfall §3 — caching
/// a long-lived handle would silently dangle after `rotateIfNeeded` renames
/// the path).
///
/// Errors during write are logged via `osLogger.error(...)` and DROPPED;
/// they never throw out of the queue closure because audit-log failure MUST
/// NOT break the importer's primary path (T-03-03-06 mitigation).
final class ShortcutAuditLog {
    static let shared = ShortcutAuditLog()

    /// Public path to the audit log. Used by Phase 5's "Reveal Audit Log" button
    /// (UI-06 → `NSWorkspace.shared.activateFileViewerSelecting([url])`).
    ///
    /// Derived identically to the convenience-init `logURL == nil` branch at
    /// lines 195-202 of this file:
    ///   `~/Library/Application Support/KeyMic/shortcut-voice-audit.log`
    ///
    /// Single source of truth: the convenience init now assigns
    /// `self.logURL = Self.defaultURL` so the path is computed in one place.
    public static let defaultURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("KeyMic", isDirectory: true)
            .appendingPathComponent("shortcut-voice-audit.log")
    }()

    private let queue = DispatchQueue(label: "io.keymic.app.audit-log")
    private let logURL: URL
    private let maxBytes: Int
    private let osLogger = Logger(subsystem: "io.keymic.app", category: "ShortcutAuditLog")
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // AUD-02: NDJSON one-line-per-record; no pretty-print, no extra whitespace.
        e.outputFormatting = []
        return e
    }()

    /// Default URL: `~/Library/Application Support/KeyMic/shortcut-voice-audit.log`
    /// per ClipboardStore.swift:50-58 precedent (uses `applicationSupportDirectory`,
    /// not the home-directory shortcut that ShellLogger uses for `~/Library/Logs`).
    init(logURL: URL? = nil, maxBytes: Int = 5 * 1024 * 1024) {
        // Consolidated to `Self.defaultURL` — single source of truth for the
        // default path. Swift `static let` is lazy + dispatch_once-thread-safe,
        // so referencing it from `init` carries no concurrency risk.
        self.logURL = logURL ?? Self.defaultURL
        self.maxBytes = maxBytes
    }

    /// Asynchronously write one NDJSON record to the audit log. Failures are
    /// logged via `osLogger.error(...)` and dropped — never surface to the
    /// caller (T-03-03-06).
    func write(_ record: AuditRecord) {
        queue.async { [self] in
            do {
                try rotateIfNeeded()
                let line = format(record)
                try append(line)
            } catch {
                osLogger.error("Audit write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Block until the serial queue drains so tests can deterministically read
    /// written content. Mirror ShellLogger:45-47.
    func flushForTesting() {
        queue.sync { }
    }

    /// AUD-06: API-surface compatibility with Phase 4's `applicationWillTerminate`
    /// hook. Because `append` opens fresh per write, there is no long-lived
    /// handle to close — this is a flush-only operation.
    func close() {
        queue.sync { }
    }

    /// WR-04 (05-REVIEW.md): create the parent directory + empty audit log
    /// file if absent, serialised against `append(_:)` via the internal
    /// serial queue. Used by Phase 5's "Reveal Audit Log" button so the
    /// `NSWorkspace.activateFileViewerSelecting([url])` call always has a
    /// real file to select (it falls back to opening the parent dir if
    /// the target doesn't exist).
    ///
    /// Without queue serialisation, the prior inline implementation in
    /// `ShortcutVoiceConfigSection.revealAuditLog` had a TOCTOU race:
    ///   - T=0ms: main thread `fileExists(...)` returns false
    ///   - T=1ms: audit queue `append(_)` createFile + writes NDJSON line
    ///   - T=2ms: main thread `createFile(...)` REPLACES the just-written
    ///            file with empty content — data loss in an audit-relevant
    ///            artifact.
    ///
    /// `queue.sync` runs the check + create on the same serial queue that
    /// `append(_:)` uses, so the two paths interleave atomically: either
    /// `ensureFileExists` runs entirely before a pending `append`, or
    /// entirely after. In either ordering the audit line is preserved.
    ///
    /// `queue.sync` is safe to call from the main thread here because this
    /// queue does NOT call back into the main thread synchronously — no
    /// deadlock risk. Errors during directory creation are silently
    /// swallowed (`try?`) — degraded behaviour is acceptable (reveal opens
    /// parent dir with no selection) if the user's Application Support
    /// directory is unusual.
    func ensureFileExists() {
        queue.sync {
            let fm = FileManager.default
            let dir = self.logURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: self.logURL.path) {
                fm.createFile(atPath: self.logURL.path, contents: nil)
            }
        }
    }

    // MARK: - Private helpers

    private func rotateIfNeeded() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logURL.path) else { return }
        let attrs = try fm.attributesOfItem(atPath: logURL.path)
        guard let size = attrs[.size] as? Int, size > maxBytes else { return }
        let backupURL = logURL.appendingPathExtension("1")
        if fm.fileExists(atPath: backupURL.path) {
            try fm.removeItem(at: backupURL)
        }
        try fm.moveItem(at: logURL, to: backupURL)
    }

    private func format(_ record: AuditRecord) -> String {
        // Hand-build the JSON object to lock key order to CodingKeys
        // declaration order per RESEARCH §Pitfall §6. Swift's JSONEncoder +
        // KeyedEncodingContainer does NOT guarantee declaration-order output
        // (observed: hash order varies per record); explicit encode(to:)
        // with ordered calls does NOT change this because the container
        // serializes the final dictionary in implementation-defined order.
        //
        // Each field's VALUE is encoded via JSONEncoder (handles escapes,
        // unicode, nested objects, optionals → null); the OUTER object is
        // assembled by string concatenation in declaration order.
        var parts: [String] = []
        parts.append("\"timestamp\":\(encodeValue(record.timestamp))")
        parts.append("\"transcript\":\(encodeValue(record.transcript))")
        parts.append("\"yaml\":\(encodeValue(record.yaml))")
        parts.append("\"bindingId\":\(encodeValue(record.bindingId))")
        parts.append("\"conflictCleared\":\(record.conflictCleared ? "true" : "false")")
        parts.append("\"conflictSource\":\(encodeValue(record.conflictSource))")
        parts.append("\"parseError\":\(encodeValue(record.parseError))")
        parts.append("\"shellStripped\":\(record.shellStripped ? "true" : "false")")
        parts.append("\"droppedBundleIDs\":\(encodeValue(record.droppedBundleIDs))")
        parts.append("\"action\":\(encodeValue(record.action))")
        return "{" + parts.joined(separator: ",") + "}\n"
    }

    /// Encode an arbitrary Encodable value (including Optional → null) as a
    /// JSON fragment using the cached `encoder`. Used by `format()` to
    /// assemble the outer object in declaration order while delegating
    /// value escaping to JSONEncoder.
    private func encodeValue<T: Encodable>(_ value: T) -> String {
        // Wrap in a single-element array to coerce JSONEncoder into emitting
        // a top-level fragment (JSONEncoder requires a container at top
        // level); then strip the `[` and `]`. This handles String, Bool,
        // Int, Optional, nested Encodable, and arrays uniformly.
        let arr = [value]
        guard let data = try? encoder.encode(arr),
              let s = String(data: data, encoding: .utf8),
              s.hasPrefix("["), s.hasSuffix("]") else {
            return "null"
        }
        return String(s.dropFirst().dropLast())
    }

    private func append(_ line: String) throws {
        let fm = FileManager.default
        let dir = logURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        // Open-fresh-per-write per RESEARCH §Pitfall §3 — DO NOT cache the
        // handle. A long-lived handle would dangle after `rotateIfNeeded`
        // renames the file out from under us.
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
        // AUD-04: fsync-equivalent durability before the function returns.
        // APFS journaling completes the contract on top of this call.
        try handle.synchronize()
    }

    // MARK: - Canonical kind dispatcher (D-C-3)

    /// Convert a parser-side `ShortcutYAMLError` into a `ParseErrorPayload`
    /// per CONTEXT.md `<specifics>` "Error → kind mapping table".
    ///
    /// Exhaustive switch with NO `default:` arm — adding a new case to
    /// `ShortcutYAMLError` becomes a compile-time test-update gate per
    /// Phase 2 P-05 precedent.
    ///
    /// Attacker-controlled token strings (keys, indent, offendingToken) are
    /// truncated to 64 chars defensively, mirroring Phase 2's truncation
    /// contract (T-02-02-01).
    static func canonicalKind(_ error: ShortcutYAMLError) -> ParseErrorPayload {
        switch error {
        case .empty:
            return ParseErrorPayload(kind: "empty")
        case .missingShortcut:
            return ParseErrorPayload(kind: "missingShortcut")
        case .malformedAction(let line):
            return ParseErrorPayload(kind: "malformedAction", line: line)
        case .unknownActionKey(let line, let key):
            return ParseErrorPayload(
                kind: "unknownActionKey",
                line: line,
                token: String(key.prefix(64))
            )
        case .invalidValue(let field, let line, let offendingToken):
            return ParseErrorPayload(
                kind: "invalidValue",
                field: field,
                line: line,
                token: offendingToken.map { String($0.prefix(64)) }
            )
        case .invalidIndent(let line, let offendingIndent):
            return ParseErrorPayload(
                kind: "invalidIndent",
                line: line,
                token: offendingIndent.map { String($0.prefix(64)) }
            )
        case .unclosedThinkBlock(let tag, let line):
            return ParseErrorPayload(kind: "unclosedThinkBlock", field: tag, line: line)
        case .unclosedString(let line):
            return ParseErrorPayload(kind: "unclosedString", line: line)
        case .duplicateField(let field, let firstLine, _):
            return ParseErrorPayload(kind: "duplicateField", field: field, line: firstLine)
        }
    }

    /// Convert an importer-side `ShortcutImporterError` into a
    /// `ParseErrorPayload`. Field payloads are truncated to 64 chars
    /// defensively at the conversion site (the enum stores raw strings
    /// already truncated at the throw site per ShortcutImporterError docs).
    ///
    /// Exhaustive switch with NO `default:` arm — adding a new case to
    /// `ShortcutImporterError` becomes a compile-time test-update gate per
    /// Phase 2 P-05 / Phase 3 P-05 precedent (mirrors the YAMLError-variant
    /// `canonicalKind(_:ShortcutYAMLError)` switch above).
    static func canonicalKind(_ error: ShortcutImporterError) -> ParseErrorPayload {
        switch error {
        case .actionTriggersVoiceKey(let triggerSource):
            return ParseErrorPayload(
                kind: "actionTriggersVoiceKey",
                field: String(triggerSource.prefix(64))
            )
        case .ownedTriggerCollision(let owner):
            return ParseErrorPayload(
                kind: "ownedTriggerCollision",
                field: String(owner.prefix(64))
            )
        case .llmFailure(let message):
            // Phase 4 amendment per 04-CONTEXT.md `<phase3_amendment>`:
            // `llm-error` is the canonical `kind:` string consumed by the
            // status-line / overlay-toast subscribers. `message` is
            // attacker-controlled (LLM / URLSession descriptor) — defensive
            // 64-char truncation mirrors `actionTriggersVoiceKey` above.
            return ParseErrorPayload(
                kind: "llm-error",
                field: String(message.prefix(64))
            )
        }
    }
}
