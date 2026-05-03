import Foundation
import OSLog

struct SecretRule {
    let id: String
    let regex: NSRegularExpression
    let keywords: [String]
    let description: String
    let entropy: Double?
    let secretGroup: Int?

    init?(raw: [String: TOMLValue]) {
        guard case let .string(id)? = raw["id"], !id.isEmpty,
              case let .string(pattern)? = raw["regex"], !pattern.isEmpty
        else { return nil }
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
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
        logger.info("loaded \(rules.count) gitleaks rules of \(raw.count) raw entries")
        return rules
    }
}
