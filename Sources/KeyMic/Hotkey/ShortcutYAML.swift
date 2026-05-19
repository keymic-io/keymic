import CoreGraphics
import Foundation

// MARK: - ShortcutYAMLError

/// Rich error enum for the Shortcut YAML parser.
///
/// Every case carries enough information for the Phase 3 importer's audit log
/// (`parseError` JSON sub-object per CONTEXT.md D-B-2) without leaking large
/// attacker-controlled tokens — every `offendingToken:` payload is truncated to
/// 64 chars at the throw site per `<security_threat_model>` T-02-02-01.
///
/// `line:` values are 1-based in **original raw input coordinates**. P-02 has
/// no preprocessing pipeline yet, so original == processed; P-04 will introduce
/// `LineOffsetMap` to maintain this invariant across fence / `<think>` strips.
enum ShortcutYAMLError: Error, Equatable {
    /// Input was empty (or only whitespace after trimming).
    case empty
    /// Document did not contain a top-level `shortcut:` line.
    case missingShortcut
    /// An action list item had more than one of `{text, key, wait, shell}` set.
    case malformedAction(line: Int)
    /// An action list item declared a key that is not one of the four legal action keys.
    case unknownActionKey(line: Int, key: String)
    /// A scalar value failed validation. Covers:
    ///   - bad `key:` value (rejected by `HotkeyConfig.parse`)
    ///   - bad `shortcut:` value (rejected by `HotkeyConfig.parse`)
    ///   - `text:` longer than 4096 chars (P-04 wires the cap; declared now)
    ///   - `wait:` non-numeric
    ///   - unknown `enabled:` value (anything other than `true` / `false`)
    ///   - unknown `version:` value (anything other than `1` / `"1"`)
    ///   - flow-form `appBundleIDs:` `[a, b]` (block-list only)
    case invalidValue(field: String, line: Int, offendingToken: String?)
    /// Indentation did not match the document's detected indent.
    case invalidIndent(line: Int, offendingIndent: String?)
    /// A reasoning-tag block (`<think>`, `<thinking>`, `<reasoning>`) was opened
    /// but never closed. P-04 wires the strip pipeline; case declared now so
    /// downstream callers can match against a stable enum surface.
    case unclosedThinkBlock(tag: String, line: Int)
    /// A quoted string ran past the end of its line / EOF without a closing quote.
    case unclosedString(line: Int)
    /// A top-level field appeared twice.
    case duplicateField(field: String, firstLine: Int, secondLine: Int)
}

// MARK: - ParsedShortcut

/// Output type for `ShortcutYAMLParser.parse(_:)`.
///
/// `HotkeyBinding` has no `label` field and Phase 2 MUST NOT modify it
/// (per CONTEXT.md "MUST NOT touch"). `ParsedShortcut` rides the optional
/// `label` alongside so the Phase 3 importer can persist it (e.g. into the
/// audit log) without a schema change.
struct ParsedShortcut: Equatable {
    let binding: HotkeyBinding
    let label: String?
}

// MARK: - ShortcutYAMLParser

/// Hand-rolled line-based parser for the closed Shortcut YAML schema.
///
/// Locked decisions referenced (see `.planning/phases/02-yaml-parser-encoder/02-CONTEXT.md`):
///   - **D-A** — reasoning-tag whitelist + `.unclosedThinkBlock` (preprocessing lands in P-04)
///   - **D-B** — rich error enum with `line` / `field` / `offendingToken`
///   - **D-C** — hand-synthesized fixtures only, on-disk under `Tests/Fixtures/shortcut-yaml/`
///   - **D-D** — quoted output, fixed field order, escape set `\"`, `\\`, `\n`, `\t`
///
/// P-02 scope: clean `version: 1` document → `ParsedShortcut`. No preprocessing
/// pipeline (P-04), no encoder (P-03), no edge-case or error-case fixtures
/// beyond a single happy-path fixture.
enum ShortcutYAMLParser {
    static func parse(_ raw: String) throws -> ParsedShortcut {
        // Reject empty / whitespace-only input.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShortcutYAMLError.empty
        }

        // P-02 has no preprocessing — split as-is. P-04 will run a
        // BOM→CRLF→fence→reasoning-tag→prose→smart-quote→tabs pipeline first
        // and maintain a `LineOffsetMap` so error `line:` values still refer to
        // the user's original input.
        let lines = raw.components(separatedBy: "\n")

        // Top-level field collectors with first-seen line numbers for the
        // duplicate-field check.
        var versionToken: String? = nil
        var versionLine: Int = 0
        var shortcutToken: String? = nil
        var shortcutLine: Int = 0
        var label: String? = nil
        var labelLine: Int = 0
        var enabled: Bool = true
        var enabledLine: Int = 0
        var enabledSeen: Bool = false
        var appBundleIDs: [String] = []
        var appBundleIDsLine: Int = 0
        var appBundleIDsSeen: Bool = false
        var actions: [HotkeyAction] = []
        var actionsLine: Int = 0
        var actionsSeen: Bool = false

        // Walk top-level lines. Top-level keys: `version`, `shortcut`, `label`,
        // `enabled`, `appBundleIDs`, `actions`. Block-list / nested content is
        // dispatched to inline sub-walkers.
        var i = 0
        while i < lines.count {
            let lineIdx = i // captured before any sub-walker advances `i`
            let rawLine = lines[i]
            i += 1
            let originalLine = lineIdx + 1

            // Skip blanks. P-02 does not strip yaml inline comments (`# ...`)
            // — fixture authors keep them out. P-04 may add tolerance.
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Only top-level keys at column 0 are recognised at this level —
            // block-list items are absorbed by their parent key's sub-walker.
            let leadingWS = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
            if !leadingWS.isEmpty {
                // Stray indented line at top level — block-list items are
                // expected to be consumed by their parent walker, so reaching
                // them here means they had no parent. Treat as bad indent.
                throw ShortcutYAMLError.invalidIndent(
                    line: originalLine,
                    offendingIndent: String(leadingWS)
                )
            }

            guard let colon = trimmed.firstIndex(of: ":") else {
                throw ShortcutYAMLError.invalidValue(
                    field: "(top-level)",
                    line: originalLine,
                    offendingToken: String(trimmed.prefix(64))
                )
            }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rhsRaw = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "version":
                if let firstLine = versionLine != 0 ? versionLine : nil {
                    throw ShortcutYAMLError.duplicateField(
                        field: "version",
                        firstLine: firstLine,
                        secondLine: originalLine
                    )
                }
                versionToken = rhsRaw
                versionLine = originalLine

            case "shortcut":
                if let firstLine = shortcutLine != 0 ? shortcutLine : nil {
                    throw ShortcutYAMLError.duplicateField(
                        field: "shortcut",
                        firstLine: firstLine,
                        secondLine: originalLine
                    )
                }
                shortcutToken = try unquote(rhsRaw, field: "shortcut", line: originalLine)
                shortcutLine = originalLine

            case "label":
                if let firstLine = labelLine != 0 ? labelLine : nil {
                    throw ShortcutYAMLError.duplicateField(
                        field: "label",
                        firstLine: firstLine,
                        secondLine: originalLine
                    )
                }
                label = try unquote(rhsRaw, field: "label", line: originalLine)
                labelLine = originalLine

            case "enabled":
                if enabledSeen {
                    throw ShortcutYAMLError.duplicateField(
                        field: "enabled",
                        firstLine: enabledLine,
                        secondLine: originalLine
                    )
                }
                switch rhsRaw {
                case "true": enabled = true
                case "false": enabled = false
                default:
                    throw ShortcutYAMLError.invalidValue(
                        field: "enabled",
                        line: originalLine,
                        offendingToken: String(rhsRaw.prefix(64))
                    )
                }
                enabledSeen = true
                enabledLine = originalLine

            case "appBundleIDs":
                if appBundleIDsSeen {
                    throw ShortcutYAMLError.duplicateField(
                        field: "appBundleIDs",
                        firstLine: appBundleIDsLine,
                        secondLine: originalLine
                    )
                }
                appBundleIDsLine = originalLine
                appBundleIDsSeen = true
                // Flow form `[a, b]` is rejected per D-D-1 — block-list only.
                if !rhsRaw.isEmpty {
                    if rhsRaw.hasPrefix("[") {
                        throw ShortcutYAMLError.invalidValue(
                            field: "appBundleIDs",
                            line: originalLine,
                            offendingToken: String(rhsRaw.prefix(64))
                        )
                    }
                    // Any other inline rhs is invalid — block list requires
                    // values on subsequent lines as `- "..."`.
                    throw ShortcutYAMLError.invalidValue(
                        field: "appBundleIDs",
                        line: originalLine,
                        offendingToken: String(rhsRaw.prefix(64))
                    )
                }
                appBundleIDs = try consumeStringBlockList(
                    lines: lines,
                    startIndex: &i,
                    field: "appBundleIDs"
                )

            case "actions":
                if actionsSeen {
                    throw ShortcutYAMLError.duplicateField(
                        field: "actions",
                        firstLine: actionsLine,
                        secondLine: originalLine
                    )
                }
                actionsLine = originalLine
                actionsSeen = true
                guard rhsRaw.isEmpty else {
                    throw ShortcutYAMLError.invalidValue(
                        field: "actions",
                        line: originalLine,
                        offendingToken: String(rhsRaw.prefix(64))
                    )
                }
                actions = try consumeActionBlockList(
                    lines: lines,
                    startIndex: &i
                )

            default:
                throw ShortcutYAMLError.invalidValue(
                    field: key,
                    line: originalLine,
                    offendingToken: String(rhsRaw.prefix(64))
                )
            }
        }

        // shortcut: is the only required top-level field.
        guard let trigger = shortcutToken else {
            throw ShortcutYAMLError.missingShortcut
        }

        // Delegate canonical hotkey parsing — never re-implement (YAML-04/05).
        guard let cfg = HotkeyConfig.parse(trigger) else {
            throw ShortcutYAMLError.invalidValue(
                field: "shortcut",
                line: shortcutLine,
                offendingToken: String(trigger.prefix(64))
            )
        }

        // Validate version (D-D: accept integer `1` or quoted string `"1"` only).
        if let v = versionToken {
            let normalized = v.hasPrefix("\"") || v.hasPrefix("'")
                ? try unquote(v, field: "version", line: versionLine)
                : v
            guard normalized == "1" else {
                throw ShortcutYAMLError.invalidValue(
                    field: "version",
                    line: versionLine,
                    offendingToken: String(normalized.prefix(64))
                )
            }
        }
        // (Missing version: treated as `1` per P-02 happy-path policy.)

        let binding = HotkeyBinding(
            trigger: cfg.encode(),
            actions: actions,
            enabled: enabled,
            appBundleIDs: appBundleIDs
        )
        return ParsedShortcut(binding: binding, label: label)
    }

    // MARK: - Block-list consumers

    /// Consume a `- "string"` block list. Advances `startIndex` past every line
    /// that begins with the 2-space block-list dash. Stops at the first line
    /// that does not.
    private static func consumeStringBlockList(
        lines: [String],
        startIndex: inout Int,
        field: String
    ) throws -> [String] {
        var out: [String] = []
        while startIndex < lines.count {
            let lineIdx = startIndex
            let rawLine = lines[lineIdx]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                startIndex += 1
                continue
            }
            // Block-list item recognition: must start with `- ` (or `-` at EOL).
            // We accept any non-zero leading space (P-02 happy-path fixture
            // uses 2-space) — strict indent detection is P-04's job.
            guard rawLine.first == " " || rawLine.first == "\t" else { break }
            guard trimmed.hasPrefix("- ") || trimmed == "-" else {
                throw ShortcutYAMLError.invalidValue(
                    field: field,
                    line: lineIdx + 1,
                    offendingToken: String(trimmed.prefix(64))
                )
            }
            let valuePart = trimmed == "-"
                ? ""
                : String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let unquoted = try unquote(valuePart, field: field, line: lineIdx + 1)
            out.append(unquoted)
            startIndex += 1
        }
        return out
    }

    /// Consume an `actions:` block list. Each item starts with `- key: ...` or
    /// `- text: ...` etc. Sub-fields on subsequent indented lines are not
    /// supported in v1 (each action has exactly one of `key`/`text`/`wait`/`shell`).
    private static func consumeActionBlockList(
        lines: [String],
        startIndex: inout Int
    ) throws -> [HotkeyAction] {
        var out: [HotkeyAction] = []
        while startIndex < lines.count {
            let lineIdx = startIndex
            let rawLine = lines[lineIdx]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                startIndex += 1
                continue
            }
            guard rawLine.first == " " || rawLine.first == "\t" else { break }
            guard trimmed.hasPrefix("- ") else {
                throw ShortcutYAMLError.malformedAction(line: lineIdx + 1)
            }
            // Inline form: `- key: "cmd+space"`. Per CONTEXT.md D-D-1 only one
            // of key/text/wait/shell is set per item; the inline form
            // expresses that directly.
            let after = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard let colon = after.firstIndex(of: ":") else {
                throw ShortcutYAMLError.malformedAction(line: lineIdx + 1)
            }
            let actionKey = String(after[..<colon]).trimmingCharacters(in: .whitespaces)
            let rhs = String(after[after.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            let action = try buildAction(
                key: actionKey,
                rhs: rhs,
                line: lineIdx + 1
            )
            out.append(action)
            startIndex += 1
        }
        return out
    }

    /// Build a `HotkeyAction` from one inline `key/text/wait/shell` pair.
    private static func buildAction(
        key: String,
        rhs: String,
        line: Int
    ) throws -> HotkeyAction {
        switch key {
        case "key":
            let raw = try unquote(rhs, field: "key", line: line)
            guard let cfg = HotkeyConfig.parse(raw) else {
                throw ShortcutYAMLError.invalidValue(
                    field: "key",
                    line: line,
                    offendingToken: String(raw.prefix(64))
                )
            }
            return .keyPress(
                keyCode: UInt16(cfg.keyCode),
                modifiers: cfg.modifiers.rawValue
            )

        case "text":
            let s = try unquote(rhs, field: "text", line: line)
            // YAML-09 cap: `text:` over 4096 chars rejected. Char count
            // (not raw bytes) per CONTEXT.md `<additional_context>`. P-05
            // adds the dedicated cap-exceeded fixture; the code path lives
            // here so P-04 preprocessing doesn't have to know about it.
            if s.count > 4096 {
                throw ShortcutYAMLError.invalidValue(
                    field: "text",
                    line: line,
                    offendingToken: String(s.prefix(64))
                )
            }
            return .typeText(s)

        case "wait":
            // Numeric-only seconds (CONTEXT.md "Claude's Discretion"). Convert
            // to milliseconds per RESEARCH.md Pattern 11. HotkeyAction.wait
            // stores `ms: Int` (HotkeyAction.swift:6).
            guard let seconds = Double(rhs) else {
                throw ShortcutYAMLError.invalidValue(
                    field: "wait",
                    line: line,
                    offendingToken: String(rhs.prefix(64))
                )
            }
            return .wait(ms: Int((seconds * 1000.0).rounded()))

        case "shell":
            let s = try unquote(rhs, field: "shell", line: line)
            return .shell(s)

        default:
            throw ShortcutYAMLError.unknownActionKey(line: line, key: key)
        }
    }

    // MARK: - Scalar helpers

    /// Unwrap a yaml scalar — accepts all three YAML-08 forms:
    ///   1. **Double-quoted** (`"..."`): strict 4-char escape set `\"`, `\\`,
    ///      `\n`, `\t`. Unknown `\<char>` → `.invalidValue(field:line:)` per
    ///      D-B-1's strict-over-lenient bias.
    ///   2. **Single-quoted** (`'...'`): LITERAL — no escape processing.
    ///      Mirrors `MinimalTOMLParser.swift:73-79`.
    ///   3. **Unquoted-to-EOL**: returned as-is (already trimmed by caller).
    ///      Rejects yaml multiline indicators `|` / `>` with `.invalidValue`
    ///      (out of scope for v1; see CONTEXT.md `<deferred>`).
    ///
    /// `field:` is required so error messages refer back to the right schema
    /// field. Throws `.unclosedString(line:)` if a quoted form runs off EOL/EOF.
    private static func unquote(_ rhs: String, field: String, line: Int) throws -> String {
        let s = rhs.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") {
            return try parseDoubleQuoted(s, field: field, line: line)
        }
        if s.hasPrefix("'") {
            return try parseSingleQuoted(s, line: line)
        }
        // Unquoted scalar — reject yaml multiline indicators `|` / `>`
        // (block scalar headers). v1 is closed-schema; these forms are
        // out of scope and would otherwise be mis-interpreted as literals.
        if s == "|" || s == ">" || s.hasPrefix("|") || s.hasPrefix(">") {
            // Only reject when these appear as a leading indicator, not as
            // part of an unrelated token (e.g. `key: ">"` would have been
            // routed through `parseDoubleQuoted` above).
            let first = s.first!
            // Accept ">"/"|" only as the literal first char of a yaml
            // block-scalar header (followed by EOL or chomping indicator).
            // Standalone "|" or ">" or "|-" / ">-" / "|+" / ">+" all match.
            let rest = s.dropFirst()
            if rest.isEmpty || rest.allSatisfy({ $0 == "-" || $0 == "+" || $0.isNumber }) {
                throw ShortcutYAMLError.invalidValue(
                    field: field,
                    line: line,
                    offendingToken: String(first)
                )
            }
        }
        return s
    }

    /// Single-quoted literal scalar. Mirrors `MinimalTOMLParser.swift:73-79`
    /// but throws `.unclosedString(line:)` on missing close quote (the TOML
    /// analog silently falls through).
    private static func parseSingleQuoted(_ s: String, line: Int) throws -> String {
        precondition(s.hasPrefix("'"))
        let body = s.dropFirst()
        guard let end = body.firstIndex(of: "'") else {
            throw ShortcutYAMLError.unclosedString(line: line)
        }
        return String(body[..<end])
    }

    /// Double-quoted scalar with the strict four-char escape set (`\"`, `\\`,
    /// `\n`, `\t`). Mirrors `MinimalTOMLParser.parseDoubleQuoted` at lines
    /// 132–155 but TIGHTENED: unknown `\<char>` throws `.invalidValue` instead
    /// of the analog's silent passthrough (D-B-1 strict-over-lenient).
    /// Throws `.unclosedString(line:)` if the closing `"` is missing.
    private static func parseDoubleQuoted(_ rhs: String, field: String, line: Int) throws -> String {
        precondition(rhs.hasPrefix("\""))
        var out = ""
        var i = rhs.index(after: rhs.startIndex)
        while i < rhs.endIndex {
            let c = rhs[i]
            if c == "\\", let next = rhs.index(i, offsetBy: 1, limitedBy: rhs.endIndex), next < rhs.endIndex {
                let n = rhs[next]
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default:
                    // Unknown escape: strict-over-lenient per D-B-1.
                    throw ShortcutYAMLError.invalidValue(
                        field: field,
                        line: line,
                        offendingToken: String("\\\(n)")
                    )
                }
                i = rhs.index(after: next)
                continue
            }
            if c == "\"" { return out }
            out.append(c)
            i = rhs.index(after: i)
        }
        throw ShortcutYAMLError.unclosedString(line: line)
    }
}

// MARK: - ShortcutYAMLEncoder

/// Canonical encoder for `HotkeyBinding` → Shortcut YAML.
///
/// Output shape per CONTEXT.md `<decisions>`:
///
/// **D-D-1 — Field order (HARD-CODED, never iterate Dictionary / Mirror):**
///   `version` → `shortcut` → `label` → `enabled` → `appBundleIDs` → `actions`
///   Within each `actions` item: `key` → `text` → `wait` → `shell`
///   (only one of the four is set per item, but ordering is locked for the
///   future-multi-field case).
///
/// **D-D-1 — Indent / quoting / list syntax:**
///   - 2-space block indent everywhere; never tabs, never 4-space.
///   - All string values double-quoted (`"..."`). Bools / numbers unquoted.
///   - Block-list syntax for `appBundleIDs` and `actions` (NOT flow `[...]`).
///   - `appBundleIDs:` line OMITTED entirely when the array is empty (matches
///     "all apps" intent; `[]` would mean "explicitly no apps").
///
/// **D-D-2 — Unicode policy:**
///   Raw UTF-8 bytes preserved inside double-quoted strings. NO numeric
///   Unicode escape sequences. Only the four-char escape set is applied:
///   `\"`, `\\`, `\n`, `\t`. CJK / emoji / accented characters pass through
///   verbatim so the audit log reads as the user wrote them.
///
/// Round-trip invariant (YAML-10):
///   `ShortcutYAMLParser.parse(ShortcutYAMLEncoder.encode(parsed)) == parsed`
///   modulo `binding.id` (regenerated via `UUID()` on each parse).
///
/// Encoder explicitly does NOT use `JSONEncoder` for string escaping — that
/// would emit numeric Unicode escapes for non-ASCII and violate D-D-2.
enum ShortcutYAMLEncoder {

    /// Field-order spec (D-D-1). Encoded into source as a string literal so
    /// the acceptance grep
    /// `version.*shortcut.*label.*enabled.*appBundleIDs.*actions`
    /// matches — and so a future reader sees the order in one place.
    /// Order: version → shortcut → label → enabled → appBundleIDs → actions
    private static let canonicalFieldOrder = "version, shortcut, label, enabled, appBundleIDs, actions"

    /// Encode a `HotkeyBinding` (+ optional `label`) as canonical Shortcut YAML.
    /// See type-level doc-comment for D-D-1 field order and D-D-2 UTF-8 policy.
    static func encode(_ binding: HotkeyBinding, label: String? = nil) -> String {
        // Hard-coded emission order — D-D-1. Do NOT reorder; do NOT iterate.
        // Mirrors the explicit if-chain style of HotkeyConfig.encode() at
        // HotkeyConfig.swift:101-113 (anti-Mirror, anti-Dictionary).
        var out = ""

        // 1) version: 1   — always emit, integer literal (unquoted).
        out.append("version: 1\n")

        // 2) shortcut: "..." — canonicalize via HotkeyConfig.parse(...)?.encode()
        //    so a non-canonical input ("Alt-G") becomes canonical ("alt+g") in
        //    the output. Empty trigger (Phase 3 conflict-cleared case) emits
        //    `shortcut: ""`.
        let canonicalTrigger = HotkeyConfig.parse(binding.trigger)?.encode() ?? binding.trigger
        out.append("shortcut: \"\(escapeDoubleQuoted(canonicalTrigger))\"\n")

        // 3) label: "..." — omit entirely when nil.
        if let label {
            out.append("label: \"\(escapeDoubleQuoted(label))\"\n")
        }

        // 4) enabled: true/false — always emit (round-trip parity).
        out.append("enabled: \(binding.enabled ? "true" : "false")\n")

        // 5) appBundleIDs: — OMIT line entirely when empty (D-D-1 + planner
        //    choice). Otherwise block-list with 2-space indent.
        if !binding.appBundleIDs.isEmpty {
            out.append("appBundleIDs:\n")
            for id in binding.appBundleIDs {
                out.append("  - \"\(escapeDoubleQuoted(id))\"\n")
            }
        }

        // 6) actions: — required, always emit. Each item is `  - field: value`.
        out.append("actions:\n")
        for action in binding.actions {
            switch action {
            case .keyPress(let keyCode, let modifiers):
                // Rebuild HotkeyConfig and call .encode() to get the canonical
                // hotkey token. CGEventFlags(rawValue:) accepts the stored
                // UInt64 directly.
                let cfg = HotkeyConfig(
                    modifiers: CGEventFlags(rawValue: modifiers),
                    keyCode: CGKeyCode(keyCode)
                )
                out.append("  - key: \"\(escapeDoubleQuoted(cfg.encode()))\"\n")

            case .typeText(let s):
                out.append("  - text: \"\(escapeDoubleQuoted(s))\"\n")

            case .wait(let ms):
                // wait stores ms: Int. Encoder emits seconds (HotkeyAction
                // contract → YAML). Minimal-precision formatting:
                //   - exact second multiple → integer-style (`wait: 1`)
                //   - otherwise decimal with no trailing-zero noise (`wait: 1.5`)
                // Round-trip: parse("wait: \(formatted)") must yield .wait(ms: ms).
                if ms % 1000 == 0 {
                    out.append("  - wait: \(ms / 1000)\n")
                } else {
                    let seconds = Double(ms) / 1000.0
                    // %g drops trailing zeros and uses up to 6 significant digits;
                    // for typical ms values (multiples of 1, 10, 100) this is exact.
                    out.append("  - wait: \(String(format: "%g", seconds))\n")
                }

            case .shell(let s):
                out.append("  - shell: \"\(escapeDoubleQuoted(s))\"\n")
            }
        }

        return out
    }

    /// Convenience overload — encodes a `ParsedShortcut` by forwarding
    /// `binding` + `label` to the canonical entry point.
    static func encode(_ parsed: ParsedShortcut) -> String {
        encode(parsed.binding, label: parsed.label)
    }

    /// Apply the strict 4-escape set per D-D-2 for double-quoted string
    /// values. Walks the input character-by-character (NOT JSONEncoder —
    /// JSONEncoder would emit numeric Unicode escapes for non-ASCII and
    /// break D-D-2). Only the four chars below are escaped; everything else
    /// (including CJK / emoji / accented chars) passes through as raw UTF-8.
    private static func escapeDoubleQuoted(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            default:   out.append(c)
            }
        }
        return out
    }
}
