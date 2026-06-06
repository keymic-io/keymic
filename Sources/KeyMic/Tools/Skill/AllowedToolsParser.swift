import Foundation

/// Parses a Skill's `allowed_tools` string into a tool-name allow-set.
///
/// v1 enforcement is **name-level only**: a token like `"Bash(git:*)"` collapses
/// to `"Bash"`. The parenthesized argument pattern is preserved verbatim in the
/// skill metadata (informational), but parameter-level enforcement is deferred
/// to a future plan (see spec §16).
///
/// Returns `nil` (meaning "no restriction") for:
///   - `nil` input
///   - empty / whitespace-only input
///   - YAML null literals (`null`/`Null`/`NULL`/`~`) — when the frontmatter
///     parser keeps the raw token text instead of converting to a Swift
///     `nil`, these would otherwise produce an allow-set of `{"null"}` that
///     strips every legitimately-named tool from the agent run
///   - input where every token strips to empty (e.g. `"()"`)
public enum AllowedToolsParser {
    public static func parse(_ input: String?) -> Set<String>? {
        guard let input else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" || trimmed.lowercased() == "null" { return nil }

        let separators = CharacterSet.whitespacesAndNewlines
        let tokens = trimmed.unicodeScalars
            .split(whereSeparator: { separators.contains($0) })
            .map(String.init)

        var names: Set<String> = []
        for token in tokens {
            let name = stripParenthesizedTail(token)
            guard !name.isEmpty else { continue }
            names.insert(name)
        }
        return names.isEmpty ? nil : names
    }

    /// Drops a trailing `(...)` suffix. `"Bash(git:*)"` → `"Bash"`; `"()"` → `""`.
    private static func stripParenthesizedTail(_ token: String) -> String {
        guard let openIdx = token.firstIndex(of: "(") else { return token }
        return String(token[..<openIdx])
    }
}
