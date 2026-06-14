import Foundation

/// Pure helper for the `.runShell` injection strategy. Mirrors `URLTemplate.substitute`
/// shape but shell-escapes placeholder values instead of URL-encoding them.
///
/// Supported placeholders: `{query}`, `{selection}`, `{clipboard}` (aliases of
/// `{clipboardTop}`). Unknown placeholders are left LITERAL so they show up
/// verbatim in the confirmation sheet and signal misconfiguration to the user.
enum ShellTemplate {
    static func substitute(template: String, text: String, context: PersonaContext?) -> String? {
        // SECURITY: single-pass scan. Sequential `replacingOccurrences` passes would
        // re-scan already-substituted values — if a value literally contains another
        // placeholder (e.g. text == "{clipboard}"), a later pass would expand it
        // INSIDE the already-shell-quoted segment, breaking quote pairing and letting
        // attacker-controlled clipboard content escape the single quotes.
        // `{clipboardTop}` is listed before `{clipboard}` so the longer token wins.
        let replacements: [(placeholder: String, value: String)] = [
            ("{query}", text),
            ("{selection}", context?.selection ?? ""),
            ("{clipboardTop}", context?.clipboardTop ?? ""),
            ("{clipboard}", context?.clipboardTop ?? ""),
        ]
        var out = ""
        out.reserveCapacity(template.count)
        var idx = template.startIndex
        scan: while idx < template.endIndex {
            if template[idx] == "{" {
                for (placeholder, value) in replacements
                where template[idx...].hasPrefix(placeholder) {
                    out += shellEscape(value)
                    idx = template.index(idx, offsetBy: placeholder.count)
                    continue scan
                }
            }
            out.append(template[idx])
            idx = template.index(after: idx)
        }
        return out
    }

    /// Wraps a string in single quotes, escaping embedded single quotes via the standard
    /// `'\''` idiom. Produces a safe shell word for `/bin/zsh -c`.
    static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Returns `true` if at least one placeholder resolved to non-empty content,
    /// OR if the template had no placeholders at all (literal command).
    ///
    /// Returning `false` short-circuits `OutputRouter` BEFORE the confirmation sheet
    /// to prevent surprises like `rm -rf {selection}` becoming `rm -rf ''` when nothing
    /// is selected. Empty-input placeholders produce `''` (safe but meaningless).
    static func hasResolvedSubstantialContent(original: String, resolved: String) -> Bool {
        var stripped = original
        for placeholder in ["{query}", "{selection}", "{clipboardTop}", "{clipboard}"] {
            stripped = stripped.replacingOccurrences(of: placeholder, with: "")
        }
        if stripped == original { return true }
        // After shell escaping, empty inputs become `''`. Check if any placeholder
        // resolved to something beyond the empty-quote token.
        let bare = resolved
            .replacingOccurrences(of: "''", with: "")
        return bare != stripped
    }
}
