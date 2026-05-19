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

// MARK: - LineOffsetMap

/// Maps post-preprocessing line indices back to original raw-input line numbers.
///
/// Locked by CONTEXT.md D-B-1: every `ShortcutYAMLError.line:` value must point
/// at the user's ORIGINAL line (1-based) — not the cleaned line index produced
/// after fence-strip, reasoning-tag-strip, and leading-prose-strip have removed
/// preceding lines. `LineOffsetMap` is built by `preprocess(_:)` in lockstep
/// with the cleaned output: every kept processed line records its original
/// 1-based line number via `append(originalLine:)`; throw sites convert their
/// processed-line indices to original-line indices via
/// `originalLine(forProcessed:)`.
///
/// Storage: a flat `[Int]` of original-line numbers indexed by processed line
/// (0-based). The lookup API is 1-based per the convention of every
/// `ShortcutYAMLError.line:` value in the project. Bounds-check is permissive
/// — out-of-range queries fall back to the last known mapping rather than
/// crashing — because malformed inputs reach error throw sites with line
/// indices that may run past the end of the cleaned content.
private struct LineOffsetMap {
    private var map: [Int] = []

    /// Record an additional kept processed line whose origin in the raw
    /// input was `originalLine` (1-based).
    mutating func append(originalLine: Int) {
        map.append(originalLine)
    }

    /// Resolve a 1-based processed line index back to its 1-based original
    /// line number. If `processed` is out of range, returns the last known
    /// original-line value (or `processed` itself when the map is empty —
    /// the only path that reaches here is preprocessing of an empty
    /// document, which the caller has already gated to `.empty`).
    func originalLine(forProcessed processed: Int) -> Int {
        guard !map.isEmpty else { return processed }
        let idx = processed - 1 // 1-based → 0-based
        if idx < 0 { return map[0] }
        if idx >= map.count { return map[map.count - 1] }
        return map[idx]
    }
}

// MARK: - ShortcutYAMLParser

/// Hand-rolled line-based parser for the closed Shortcut YAML schema.
///
/// Locked decisions referenced (see `.planning/phases/02-yaml-parser-encoder/02-CONTEXT.md`):
///   - **D-A** — reasoning-tag whitelist + `.unclosedThinkBlock` (preprocessing landed in P-04)
///   - **D-B** — rich error enum with `line` / `field` / `offendingToken` in ORIGINAL coords
///   - **D-C** — hand-synthesized fixtures only, on-disk under `Tests/Fixtures/shortcut-yaml/`
///   - **D-D** — quoted output, fixed field order, escape set `\"`, `\\`, `\n`, `\t`
///
/// P-04 scope: preprocessing pipeline (BOM → CRLF → fence → reasoning-tags →
/// leading-prose → smart-quotes → tabs) with `LineOffsetMap`-backed original
/// line numbers, plus indent detection (2- OR 4-space).
enum ShortcutYAMLParser {

    /// Reasoning-tag whitelist (D-A-1). Canonical lowercase form. Opening
    /// AND closing tag are matched case-insensitively; the canonical name
    /// (lowercase) is what surfaces in `.unclosedThinkBlock(tag:)`.
    private static let reasoningTags: Set<String> = ["think", "thinking", "reasoning"]

    static func parse(_ raw: String) throws -> ParsedShortcut {
        // Reject empty / whitespace-only input BEFORE preprocessing.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShortcutYAMLError.empty
        }

        // Run the preprocessing pipeline FIRST (D-B-1). The map carries
        // processed-line → original-line so every error throw site downstream
        // can report user-actionable raw-input line numbers.
        let (cleaned, map) = try preprocess(raw)

        // After preprocessing, the document may be empty (e.g. it was nothing
        // but a `<think>...</think>` block, or only fences + whitespace).
        // Per CONTEXT.md / D-A-1 + YAML-11, this is `.empty`, not
        // `.missingShortcut`.
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShortcutYAMLError.empty
        }

        let lines = cleaned.components(separatedBy: "\n")

        // Detect document indent (2 OR 4 space) on the first indented action
        // item under `actions:`. The detected unit is enforced when walking
        // block-list children below.
        let indentUnit = try detectIndentUnit(lines: lines, map: map)

        // Top-level field collectors with first-seen line numbers for the
        // duplicate-field check. All `*Line` values are ORIGINAL coords.
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
            // 1-based processed line → original line via the offset map.
            let originalLine = map.originalLine(forProcessed: lineIdx + 1)

            // Skip blanks. Preprocessing does not strip yaml inline comments
            // (`# ...`) — fixture authors keep them out.
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
                    field: "appBundleIDs",
                    map: map,
                    indentUnit: indentUnit
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
                    startIndex: &i,
                    map: map,
                    indentUnit: indentUnit
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
    /// that begins with the detected `indentUnit` block-list dash. Stops at
    /// the first line that does not.
    ///
    /// All error throw sites use `map.originalLine(forProcessed:)` so the
    /// reported line number refers to the user's raw input — not the
    /// post-preprocessing line index.
    private static func consumeStringBlockList(
        lines: [String],
        startIndex: inout Int,
        field: String,
        map: LineOffsetMap,
        indentUnit: Int
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
            // Indent must equal exactly `indentUnit` spaces (mixed indent —
            // 2-then-4 or 4-then-2 within one document — is rejected here).
            guard rawLine.first == " " else { break }
            let leadingSpaces = rawLine.prefix(while: { $0 == " " }).count
            if leadingSpaces != indentUnit {
                throw ShortcutYAMLError.invalidIndent(
                    line: map.originalLine(forProcessed: lineIdx + 1),
                    offendingIndent: String(repeating: " ", count: leadingSpaces)
                )
            }
            guard trimmed.hasPrefix("- ") || trimmed == "-" else {
                throw ShortcutYAMLError.invalidValue(
                    field: field,
                    line: map.originalLine(forProcessed: lineIdx + 1),
                    offendingToken: String(trimmed.prefix(64))
                )
            }
            let valuePart = trimmed == "-"
                ? ""
                : String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let unquoted = try unquote(
                valuePart,
                field: field,
                line: map.originalLine(forProcessed: lineIdx + 1)
            )
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
        startIndex: inout Int,
        map: LineOffsetMap,
        indentUnit: Int
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
            guard rawLine.first == " " else { break }
            let leadingSpaces = rawLine.prefix(while: { $0 == " " }).count
            if leadingSpaces != indentUnit {
                throw ShortcutYAMLError.invalidIndent(
                    line: map.originalLine(forProcessed: lineIdx + 1),
                    offendingIndent: String(repeating: " ", count: leadingSpaces)
                )
            }
            guard trimmed.hasPrefix("- ") else {
                throw ShortcutYAMLError.malformedAction(
                    line: map.originalLine(forProcessed: lineIdx + 1)
                )
            }
            // Inline form: `- key: "cmd+space"`. Per CONTEXT.md D-D-1 only one
            // of key/text/wait/shell is set per item; the inline form
            // expresses that directly.
            let after = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard let colon = after.firstIndex(of: ":") else {
                throw ShortcutYAMLError.malformedAction(
                    line: map.originalLine(forProcessed: lineIdx + 1)
                )
            }
            let actionKey = String(after[..<colon]).trimmingCharacters(in: .whitespaces)
            let rhs = String(after[after.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            let action = try buildAction(
                key: actionKey,
                rhs: rhs,
                line: map.originalLine(forProcessed: lineIdx + 1)
            )
            out.append(action)
            startIndex += 1
        }
        return out
    }

    // MARK: - Indent detection

    /// Detect the document's block indent (2 OR 4 space). Scans for the first
    /// `actions:` line and inspects the first non-empty line after it. The
    /// algorithm prefers the `actions:` block because `appBundleIDs:` is
    /// optional. Falls back to inspecting the first indented line in the
    /// document if no `actions:` line is present (defensive — every valid
    /// document has `actions:` but a malformed input may reach here).
    ///
    /// All thrown `.invalidIndent` errors resolve their line number through
    /// `map.originalLine(forProcessed:)` per D-B-1.
    private static func detectIndentUnit(
        lines: [String],
        map: LineOffsetMap
    ) throws -> Int {
        // Find the first `actions:` line at column 0 (the parent block).
        var actionsIdx: Int? = nil
        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // Match `actions:` exactly (with optional trailing whitespace
            // already trimmed) — never `actions: foo`, that's an inline
            // value path which the main walker handles as `.invalidValue`.
            if trimmed == "actions:" {
                // Must be column-0 (no leading whitespace) to be the parent
                // block, not a nested map.
                if raw.first != " " && raw.first != "\t" {
                    actionsIdx = idx
                    break
                }
            }
        }
        // No `actions:` parent — default to 2 (the canonical encoder output
        // shape). The downstream walker will surface the real error
        // (`.missingShortcut`, `.malformedAction`, etc.).
        guard let actionsLineIdx = actionsIdx else { return 2 }

        // Inspect the first non-empty line AFTER `actions:` for indent.
        var probe = actionsLineIdx + 1
        while probe < lines.count {
            let raw = lines[probe]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                probe += 1
                continue
            }
            let leading = raw.prefix(while: { $0 == " " })
            // Tabs have already been normalized to spaces by preprocessing
            // stage 7; any remaining tab here is a defect.
            if raw.first == "\t" {
                throw ShortcutYAMLError.invalidIndent(
                    line: map.originalLine(forProcessed: probe + 1),
                    offendingIndent: String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
                )
            }
            let count = leading.count
            if count == 2 { return 2 }
            if count == 4 { return 4 }
            // Anything else (1, 3, 5+, or zero) is `.invalidIndent`.
            throw ShortcutYAMLError.invalidIndent(
                line: map.originalLine(forProcessed: probe + 1),
                offendingIndent: String(leading)
            )
        }
        // Empty actions list — pick 2 as a no-op default (no child lines to
        // validate against).
        return 2
    }

    // MARK: - Preprocessing pipeline (D-A-1, D-A-2, D-B-1)

    /// Run the YAML-06 preprocessing pipeline. Returns the cleaned document
    /// plus a `LineOffsetMap` that resolves every cleaned-line index back to
    /// its 1-based original-input line number.
    ///
    /// Stages, in locked order:
    ///   1. BOM strip (single U+FEFF at start)
    ///   2. CRLF → LF normalization
    ///   3. Markdown fence strip (```yaml / ```yml / ``` — case-insensitive)
    ///   4. Reasoning-tag whitelist strip (`<think>`, `<thinking>`, `<reasoning>`)
    ///   5. Leading-prose strip (drop everything before first `version:`/`shortcut:`)
    ///   6. Smart-quote normalize (U+2018/9 → `'`; U+201C/D → `"`)
    ///   7. Tabs → 4 spaces
    ///
    /// `.unclosedThinkBlock(tag:line:)` (D-A-2) is the ONLY error this
    /// pipeline throws; everything else falls through to the parser proper.
    /// An unclosed `<think>` is NEVER silently closed at EOF.
    private static func preprocess(_ raw: String) throws -> (cleaned: String, map: LineOffsetMap) {
        // Stage 1: BOM strip (U+FEFF). Single character at start only.
        var s = raw
        if s.hasPrefix("\u{FEFF}") {
            s.removeFirst()
        }

        // Stage 2: CRLF → LF. \r\n becomes \n (lone \r is preserved as-is —
        // ancient pre-OS-X classic-Mac line endings are out of scope for v1).
        s = s.replacingOccurrences(of: "\r\n", with: "\n")

        // Split into lines tagged with their ORIGINAL 1-based line number.
        // Subsequent stages drop entries but never reorder — so the
        // (line, originalLine) pairing remains the source of truth for the
        // LineOffsetMap built at the very end.
        var tagged: [(String, Int)] = []
        tagged.reserveCapacity(64)
        var origLine = 1
        for line in s.components(separatedBy: "\n") {
            tagged.append((line, origLine))
            origLine += 1
        }

        // Stage 3: Markdown fence strip. Look for a fence opener line (case-
        // insensitive `\`\`\`yaml`, `\`\`\`yml`, or bare `\`\`\``). Strip the
        // opener, the matching closer, and everything after the closer.
        tagged = stripMarkdownFence(tagged)

        // Stage 4: Reasoning-tag whitelist strip. CASE-INSENSITIVE open AND
        // close. Unmatched open throws `.unclosedThinkBlock`. Reasoning-tag
        // names: `think`, `thinking`, `reasoning` (D-A-1).
        tagged = try stripReasoningTags(tagged)

        // Stage 5: Leading-prose strip. Drop everything before the first line
        // whose trimmed content begins with `version:` or `shortcut:`.
        tagged = stripLeadingProse(tagged)

        // Stage 6: Smart-quote normalize (document-wide, not just inside
        // strings). Four codepoints → ASCII.
        tagged = tagged.map { (line, ol) in
            var out = line
            out = out.replacingOccurrences(of: "\u{2018}", with: "'")
            out = out.replacingOccurrences(of: "\u{2019}", with: "'")
            out = out.replacingOccurrences(of: "\u{201C}", with: "\"")
            out = out.replacingOccurrences(of: "\u{201D}", with: "\"")
            return (out, ol)
        }

        // Stage 7: Tabs → 4 spaces. Indent-detection (in
        // `detectIndentUnit`) then picks between 2- and 4-space indent based
        // on the resulting character content.
        tagged = tagged.map { (line, ol) in
            (line.replacingOccurrences(of: "\t", with: "    "), ol)
        }

        // Build the LineOffsetMap from the final tagged-line list.
        var map = LineOffsetMap()
        var cleanedLines: [String] = []
        cleanedLines.reserveCapacity(tagged.count)
        for (line, ol) in tagged {
            cleanedLines.append(line)
            map.append(originalLine: ol)
        }
        let cleaned = cleanedLines.joined(separator: "\n")
        return (cleaned, map)
    }

    /// Strip a markdown code fence if present. Scans the WHOLE input for the
    /// first fence-opener line whose trimmed content matches `\`\`\`yaml`,
    /// `\`\`\`yml`, or bare `\`\`\`` (case-insensitive, leading/trailing
    /// whitespace tolerated on the info-string). Strips the opener line, the
    /// matching closer line, AND any lines after the closer.
    ///
    /// Scanning beyond the first non-empty line is intentional: edge-06
    /// (`<think>...</think>` BEFORE the ```yaml fence) requires fence-strip
    /// to cooperate with the still-unprocessed reasoning-tag block — without
    /// this, the cross-stage interaction would force a stage-order reversal.
    ///
    /// If no closer is found before EOF, returns the input unchanged
    /// (per plan's Task 1 stage-3 rationale — prose-strip downstream still
    /// handles the residual).
    private static func stripMarkdownFence(
        _ tagged: [(String, Int)]
    ) -> [(String, Int)] {
        // Scan all lines for an opener fence. First match wins.
        var openIdx: Int? = nil
        for (idx, (line, _)) in tagged.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if isFenceLine(t) {
                openIdx = idx
                break
            }
        }
        guard let open = openIdx else { return tagged }

        // Find the matching closing fence (a line whose trimmed content is
        // exactly ``` — info-strings are NOT permitted on the closer).
        var closeIdx: Int? = nil
        var probe = open + 1
        while probe < tagged.count {
            let t = tagged[probe].0.trimmingCharacters(in: .whitespaces)
            if t == "```" {
                closeIdx = probe
                break
            }
            probe += 1
        }
        // No closer found — fall through (the plan instructs us to NOT
        // strip anything in this case; prose-strip handles it).
        guard let close = closeIdx else { return tagged }

        // Keep only the lines strictly between open and close.
        var out: [(String, Int)] = []
        out.reserveCapacity(close - open - 1)
        for idx in (open + 1)..<close {
            out.append(tagged[idx])
        }
        return out
    }

    /// `true` if `trimmed` is a markdown fence opener — `\`\`\`yaml`,
    /// `\`\`\`yml`, or bare `\`\`\`` (case-insensitive on the info-string).
    private static func isFenceLine(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("```") else { return false }
        let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
        return info.isEmpty || info == "yaml" || info == "yml"
    }

    /// Strip reasoning-tag blocks. Scans the joined text for
    /// `<think>...</think>`, `<thinking>...</thinking>`, and
    /// `<reasoning>...</reasoning>` (case-insensitive) and removes the entire
    /// block including both tags. Unclosed opener → `.unclosedThinkBlock`.
    ///
    /// Implementation: walk the joined text character-by-character; whenever
    /// we find `<tag>` for a whitelisted tag, find the next `</tag>` (case-
    /// insensitive); remove the inclusive span. Lines wholly consumed by the
    /// removed span are dropped; partial-line removal (the rare case where
    /// a tag opens mid-line) collapses to the residual of that line tagged
    /// at the opener-line's original-line number.
    private static func stripReasoningTags(
        _ tagged: [(String, Int)]
    ) throws -> [(String, Int)] {
        // Rebuild into one big buffer keyed by per-character original-line.
        var chars: [Character] = []
        var origAt: [Int] = []
        for (idx, (line, ol)) in tagged.enumerated() {
            for c in line {
                chars.append(c)
                origAt.append(ol)
            }
            if idx < tagged.count - 1 {
                chars.append("\n")
                origAt.append(ol)
            }
        }

        // Build a lowercase mirror for case-insensitive matching. We never
        // look at the lowercase buffer for content output — only for scan
        // decisions.
        let lower = String(chars).lowercased()
        // Convert to a Character array of the same length so index ranges line up.
        let lowerChars = Array(lower)

        var resultChars: [Character] = []
        var resultOrig: [Int] = []
        resultChars.reserveCapacity(chars.count)
        resultOrig.reserveCapacity(chars.count)

        var i = 0
        while i < chars.count {
            // Detect an opening reasoning tag at position `i`.
            if chars[i] == "<", let tag = matchOpeningTag(lowerChars, at: i) {
                // Find the matching closing tag for the SAME canonical name.
                // Case-insensitive match.
                let closer = "</\(tag)>"
                let closerChars = Array(closer)
                if let closeStart = findSubsequence(in: lowerChars, needle: closerChars, from: i + tag.count + 2) {
                    // Remove [i, closeStart + closer.count) entirely.
                    i = closeStart + closerChars.count
                    continue
                } else {
                    // D-A-2: unclosed reasoning tag → throw. Use the
                    // ORIGINAL line of the opener.
                    throw ShortcutYAMLError.unclosedThinkBlock(
                        tag: tag,
                        line: origAt[i]
                    )
                }
            }
            resultChars.append(chars[i])
            resultOrig.append(origAt[i])
            i += 1
        }

        // Re-split into tagged lines. Each line takes the origAt of its first
        // character (after which subsequent same-line chars share that
        // original-line via consistency — preprocessing never reorders chars
        // within a line). Empty residual lines keep the original-line of the
        // newline character that delimited them.
        var out: [(String, Int)] = []
        var cur = ""
        var curOrig: Int? = nil
        for (idx, c) in resultChars.enumerated() {
            if c == "\n" {
                out.append((cur, curOrig ?? resultOrig[idx]))
                cur = ""
                curOrig = nil
            } else {
                if curOrig == nil { curOrig = resultOrig[idx] }
                cur.append(c)
            }
        }
        // Trailing line (may be empty if the buffer ended on \n).
        if curOrig != nil || !cur.isEmpty {
            out.append((cur, curOrig ?? (resultOrig.last ?? 1)))
        }
        return out
    }

    /// If positions `at..<at+(tagName.count+2)` in `lower` form `<name>`
    /// where `name` ∈ `reasoningTags`, return the canonical lowercase tag
    /// name. Returns nil otherwise.
    private static func matchOpeningTag(_ lower: [Character], at: Int) -> String? {
        guard at < lower.count, lower[at] == "<" else { return nil }
        // Find the `>` ending this open tag — but bound the search to avoid
        // O(n^2) worst case across the document. We only care about tags
        // up to `len("<reasoning>") = 11` characters.
        let maxLen = 12 // covers `<reasoning>` plus a 1-char slack
        let end = min(at + maxLen, lower.count)
        for j in (at + 1)..<end {
            if lower[j] == ">" {
                let name = String(lower[(at + 1)..<j])
                if reasoningTags.contains(name) { return name }
                return nil
            }
            // Reject `<` that contains attributes or whitespace — reasoning
            // tags in the whitelist are written without attributes.
            if lower[j] == " " || lower[j] == "\t" || lower[j] == "\n" || lower[j] == "<" {
                return nil
            }
        }
        return nil
    }

    /// Linear search for `needle` in `haystack` starting at `from`. Returns
    /// the start index of the match, or nil. O(n·m); m ≤ 13 here.
    private static func findSubsequence(in haystack: [Character], needle: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, from <= haystack.count - needle.count else {
            // Bounds: if `from >= haystack.count - needle.count + 1`, no match possible.
            return nil
        }
        for start in from...(haystack.count - needle.count) {
            var match = true
            for k in 0..<needle.count {
                if haystack[start + k] != needle[k] {
                    match = false
                    break
                }
            }
            if match { return start }
        }
        return nil
    }

    /// Drop every line before the first line whose trimmed-leading content
    /// begins with `version:` or `shortcut:`. If no such line exists, return
    /// the input unchanged — the parser proper will surface
    /// `.missingShortcut` (or `.empty` if preprocessing has already removed
    /// everything).
    private static func stripLeadingProse(
        _ tagged: [(String, Int)]
    ) -> [(String, Int)] {
        var firstYAMLIdx: Int? = nil
        for (idx, (line, _)) in tagged.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("version:") || t.hasPrefix("shortcut:") {
                firstYAMLIdx = idx
                break
            }
        }
        guard let first = firstYAMLIdx else { return tagged }
        return Array(tagged[first...])
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
