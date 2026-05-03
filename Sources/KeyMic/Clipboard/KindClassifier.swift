import Foundation

struct KindClassifier {
    static let shared = KindClassifier(secretRules: GitleaksLoader.load())

    private let secretRules: [SecretRule]
    private let urlRegex: NSRegularExpression
    private let colorRegex: NSRegularExpression

    init(secretRules: [SecretRule]) {
        self.secretRules = secretRules
        self.urlRegex = try! NSRegularExpression(
            pattern: #"^(https?|ftp|file)://\S+$"#,
            options: []
        )
        self.colorRegex = try! NSRegularExpression(
            pattern: #"^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"#,
            options: []
        )
    }

    func classify(_ text: String) -> ClipboardKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }
        if matchesJSON(trimmed)     { return .codeJSON }
        if matchesSecret(trimmed)   { return .secret }
        if matchesURL(trimmed)      { return .url }
        if matchesFilePath(trimmed) { return .filePath }
        if matchesColor(trimmed)    { return .color }
        if matchesHTML(trimmed)     { return .codeHTML }
        if matchesXML(trimmed)      { return .codeXML }
        return .plain
    }

    private func matchesSecret(_ text: String) -> Bool {
        for rule in secretRules {
            if !rule.keywords.isEmpty {
                let hit = rule.keywords.contains { kw in
                    text.range(of: kw, options: .caseInsensitive) != nil
                }
                if !hit { continue }
            }
            let range = NSRange(text.startIndex..., in: text)
            if rule.regex.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    private func matchesURL(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        let range = NSRange(text.startIndex..., in: text)
        guard urlRegex.firstMatch(in: text, range: range) != nil else { return false }
        guard let comps = URLComponents(string: text), let host = comps.host, !host.isEmpty else { return false }
        return true
    }

    private func matchesFilePath(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        guard text.count > 1 else { return false }
        guard !text.contains(" ") else { return false }
        return text.hasPrefix("/")
            || text.hasPrefix("~/")
            || text.hasPrefix("./")
            || text.hasPrefix("../")
            || text.hasPrefix("file://")
    }

    private func matchesColor(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return colorRegex.firstMatch(in: text, range: range) != nil
    }

    private func matchesJSON(_ text: String) -> Bool {
        guard text.hasPrefix("{") || text.hasPrefix("[") else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return false }
        return obj is [Any] || obj is [String: Any]
    }

    private func matchesXML(_ text: String) -> Bool {
        if text.lowercased().hasPrefix("<?xml") { return true }
        guard text.hasPrefix("<"), let data = text.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        return parser.parse()
    }

    private func matchesHTML(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<!doctype html>")
            || lower.contains("<html")
            || lower.contains("<body")
            || lower.contains("<head")
    }
}
