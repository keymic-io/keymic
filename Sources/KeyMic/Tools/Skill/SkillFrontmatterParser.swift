import Foundation

public struct ParsedFrontmatter: Equatable, Sendable {
    public let fields: [String: String]
    public let body: String

    public init(fields: [String: String], body: String) {
        self.fields = fields
        self.body = body
    }
}

public struct SkillFrontmatterParser: Sendable {
    public init() {}

    public func hasFrontmatter(_ content: String) -> Bool {
        let normalized = normalizeLineEndings(stripUTF8BOM(content))
        let firstLine = normalized.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return firstLine.trimmingCharacters(in: .whitespaces) == "---"
    }

    public func parse(_ content: String) -> ParsedFrontmatter? {
        let normalized = normalizeLineEndings(stripUTF8BOM(content))
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespaces) == "---"
        else {
            return nil
        }

        guard let closingIndex = lines.dropFirst().firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return nil
        }

        var fields: [String: String] = [:]
        for line in lines[1..<closingIndex] {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else {
                continue
            }

            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }

            let rawKey = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let key = stripMatchingQuotes(rawKey).lowercased()
            guard !key.isEmpty else {
                continue
            }

            let valueStart = line.index(after: colonIndex)
            let rawValue = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            fields[key] = stripMatchingQuotes(rawValue)
        }

        let bodyStart = lines.index(after: closingIndex)
        let body = lines[bodyStart...]
            .joined(separator: "\n")

        return ParsedFrontmatter(fields: fields, body: body)
    }

    public func stripMatchingQuotes(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else {
            return value
        }

        return String(value.dropFirst().dropLast())
    }

    private func stripUTF8BOM(_ content: String) -> String {
        if content.hasPrefix("\u{FEFF}") {
            return String(content.dropFirst())
        }
        return content
    }

    private func normalizeLineEndings(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
