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
                shortcutToken = try unquote(rhsRaw, line: originalLine)
                shortcutLine = originalLine

            case "label":
                if let firstLine = labelLine != 0 ? labelLine : nil {
                    throw ShortcutYAMLError.duplicateField(
                        field: "label",
                        firstLine: firstLine,
                        secondLine: originalLine
                    )
                }
                label = try unquote(rhsRaw, line: originalLine)
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
                ? try unquote(v, line: versionLine)
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
            let unquoted = try unquote(valuePart, line: lineIdx + 1)
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
            let raw = try unquote(rhs, line: line)
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
            // TODO(P-04): YAML-09 cap — reject text longer than 4096 chars.
            let s = try unquote(rhs, line: line)
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
            let s = try unquote(rhs, line: line)
            return .shell(s)

        default:
            throw ShortcutYAMLError.unknownActionKey(line: line, key: key)
        }
    }

    // MARK: - Scalar helpers

    /// Unwrap a yaml scalar. Mirrors `MinimalTOMLParser.parseDoubleQuoted`
    /// (Sources/KeyMic/Clipboard/MinimalTOMLParser.swift:132-155) for the
    /// double-quoted form and the single-quoted literal form at lines 73-79.
    /// Escape set per CONTEXT.md D-D-2: `\"`, `\\`, `\n`, `\t`.
    private static func unquote(_ rhs: String, line: Int) throws -> String {
        let s = rhs.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") {
            guard let out = parseDoubleQuoted(s) else {
                throw ShortcutYAMLError.unclosedString(line: line)
            }
            return out
        }
        if s.hasPrefix("'") {
            let body = s.dropFirst()
            guard let end = body.firstIndex(of: "'") else {
                throw ShortcutYAMLError.unclosedString(line: line)
            }
            return String(body[..<end])
        }
        return s
    }

    /// Double-quoted scalar with the four-char escape set (`\"`, `\\`, `\n`, `\t`).
    /// Returns nil on missing close quote — caller maps to `.unclosedString`.
    /// Mirrors `MinimalTOMLParser.parseDoubleQuoted` at lines 132–155.
    private static func parseDoubleQuoted(_ rhs: String) -> String? {
        guard rhs.hasPrefix("\"") else { return nil }
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
                default: out.append(n)
                }
                i = rhs.index(after: next)
                continue
            }
            if c == "\"" { return out }
            out.append(c)
            i = rhs.index(after: i)
        }
        return nil
    }
}
