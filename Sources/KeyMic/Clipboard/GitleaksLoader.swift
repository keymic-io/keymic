import Foundation
import OSLog

struct SecretRule {
    let id: String
    let regex: NSRegularExpression
    let keywords: [String]
    let description: String
    let entropy: Double?
    let secretGroup: Int?

    private static let logger = Logger(subsystem: "io.keymic.app", category: "Gitleaks")

    init?(raw: [String: TOMLValue]) {
        guard case let .string(id)? = raw["id"], !id.isEmpty,
              case let .string(pattern)? = raw["regex"], !pattern.isEmpty
        else { return nil }
        guard let r = Self.compile(pattern: pattern, ruleID: id) else { return nil }
        self.id = id
        self.regex = r
        if case let .array(words)? = raw["keywords"] {
            self.keywords = words
        } else {
            self.keywords = []
        }
        if case let .string(desc)? = raw["description"] {
            self.description = desc
        } else {
            self.description = id
        }
        if case let .bareLiteral(rawValue)? = raw["entropy"], let value = Double(rawValue.trimmingCharacters(in: .whitespaces)) {
            self.entropy = value
        } else {
            self.entropy = nil
        }
        if case let .bareLiteral(rawValue)? = raw["secretGroup"], let value = Int(rawValue.trimmingCharacters(in: .whitespaces)) {
            self.secretGroup = value
        } else {
            self.secretGroup = nil
        }
    }

    /// Compiles a gitleaks pattern (written for Go's RE2) with NSRegularExpression
    /// (ICU), transcribing the dialect differences the bundled ruleset contains:
    /// - `(?P<name>…)` named groups (RE2/Python style) → ICU's `(?<name>…)`, with the
    ///   name sanitized to ICU's alphanumeric-only rule (jwt-base64 uses `key_ops`);
    /// - a bare `}}`, which RE2 tolerates but ICU rejects, is retried with the
    ///   literal braces escaped (kubernetes-secret-yaml needs this).
    /// Failures are logged per rule id instead of being silently dropped.
    private static func compile(pattern: String, ruleID: String) -> NSRegularExpression? {
        let normalized = transcribeNamedGroups(pattern)
        do {
            return try NSRegularExpression(pattern: normalized, options: [])
        } catch {
            let braceEscaped = normalized.replacingOccurrences(of: "}}", with: "\\}\\}")
            if braceEscaped != normalized,
               let retried = try? NSRegularExpression(pattern: braceEscaped, options: []) {
                return retried
            }
            logger.error(
                "rule \(ruleID, privacy: .public) regex failed to compile: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// `(?P<name>` → `(?<name>`, sanitizing the name to ICU's alphanumeric-only,
    /// letter-first requirement (RE2 also allows `_`) and de-duplicating sanitized
    /// collisions. Group *numbering* is unchanged, so `secretGroup` indices stay valid.
    private static func transcribeNamedGroups(_ pattern: String) -> String {
        guard pattern.contains("(?P<") else { return pattern }
        var out = ""
        var usedNames: Set<String> = []
        var rest = Substring(pattern)
        while let marker = rest.range(of: "(?P<") {
            out += rest[..<marker.lowerBound]
            let afterMarker = rest[marker.upperBound...]
            guard let close = afterMarker.firstIndex(of: ">") else {
                // Malformed tail — keep verbatim and let the compiler report it.
                out += rest[marker.lowerBound...]
                return out
            }
            var name = String(afterMarker[..<close]).filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            if name.isEmpty || !(name.first?.isLetter ?? false) { name = "g" + name }
            var unique = name
            var suffix = 2
            while usedNames.contains(unique) { unique = name + String(suffix); suffix += 1 }
            usedNames.insert(unique)
            out += "(?<" + unique + ">"
            rest = afterMarker[afterMarker.index(after: close)...]
        }
        out += rest
        return out
    }
}

enum GitleaksLoader {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "Gitleaks")

    static func load() -> [SecretRule] {
        guard let url = Bundle.main.url(forResource: "gitleaks", withExtension: "toml") else {
            logger.error("gitleaks.toml missing from bundle")
            return []
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let raw = MinimalTOMLParser.parseRules(text)
        let rules = raw.compactMap(SecretRule.init(raw:))
        if rules.count != raw.count {
            logger.error("\(raw.count - rules.count) gitleaks entries dropped (no id/regex or compile failure — see per-rule errors above)")
        }
        logger.info("loaded \(rules.count) gitleaks rules of \(raw.count) raw entries")
        return rules
    }
}
