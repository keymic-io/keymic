import Foundation

/// Pure helper for the `.runShell` injection strategy. Mirrors `URLTemplate.substitute`
/// shape but performs NO URL encoding — shell quoting is the persona author's job,
/// and the confirmation sheet is the safety net.
///
/// Supported placeholders: `{query}`, `{selection}`, `{clipboard}` (aliases of
/// `{clipboardTop}`). Unknown placeholders are left LITERAL so they show up
/// verbatim in the confirmation sheet and signal misconfiguration to the user.
enum ShellTemplate {
    static func substitute(template: String, text: String, context: PersonaContext?) -> String? {
        var out = template
        out = out.replacingOccurrences(of: "{query}", with: text)
        out = out.replacingOccurrences(of: "{selection}", with: context?.selection ?? "")
        out = out.replacingOccurrences(of: "{clipboardTop}", with: context?.clipboardTop ?? "")
        out = out.replacingOccurrences(of: "{clipboard}", with: context?.clipboardTop ?? "")
        return out
    }

    /// Returns `true` if at least one placeholder resolved to non-empty content,
    /// OR if the template had no placeholders at all (literal command).
    ///
    /// Returning `false` short-circuits `OutputRouter` BEFORE the confirmation sheet
    /// to prevent surprises like `rm -rf {selection}` becoming `rm -rf ` when nothing
    /// is selected.
    static func hasResolvedSubstantialContent(original: String, resolved: String) -> Bool {
        var stripped = original
        for placeholder in ["{query}", "{selection}", "{clipboardTop}", "{clipboard}"] {
            stripped = stripped.replacingOccurrences(of: placeholder, with: "")
        }
        if stripped == original { return true }
        return resolved != stripped
    }
}
