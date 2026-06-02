import Foundation

/// Pure helper for the `.runShell` injection strategy. Mirrors `URLTemplate.substitute`
/// shape but shell-escapes placeholder values instead of URL-encoding them.
///
/// Supported placeholders: `{query}`, `{selection}`, `{clipboard}` (aliases of
/// `{clipboardTop}`). Unknown placeholders are left LITERAL so they show up
/// verbatim in the confirmation sheet and signal misconfiguration to the user.
enum ShellTemplate {
    static func substitute(template: String, text: String, context: PersonaContext?) -> String? {
        var out = template
        out = out.replacingOccurrences(of: "{query}", with: shellEscape(text))
        out = out.replacingOccurrences(of: "{selection}", with: shellEscape(context?.selection ?? ""))
        out = out.replacingOccurrences(of: "{clipboardTop}", with: shellEscape(context?.clipboardTop ?? ""))
        out = out.replacingOccurrences(of: "{clipboard}", with: shellEscape(context?.clipboardTop ?? ""))
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
