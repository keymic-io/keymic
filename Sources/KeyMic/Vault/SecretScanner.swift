import Foundation

struct SecretMatch {
    let rule: SecretRule
    let secret: String
}

final class SecretScanner {
    static let shared = SecretScanner()

    private let queue = DispatchQueue(label: "io.keymic.app.secrets", qos: .utility)
    private let rules: [SecretRule]

    init(rules: [SecretRule] = GitleaksLoader.load()) {
        self.rules = rules
    }

    /// Async scan. Calls `completion` on the main queue.
    func scan(_ text: String, completion: @escaping (SecretMatch?) -> Void) {
        guard text.utf8.count <= VaultConfig.maxScanLength else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        queue.async {
            let match = self.firstMatch(in: text)
            DispatchQueue.main.async { completion(match) }
        }
    }

    /// Synchronous scan — for tests only.
    func firstMatch(in text: String) -> SecretMatch? {
        let lower = text.lowercased()
        for rule in rules {
            if !rule.keywords.isEmpty,
               !rule.keywords.contains(where: { lower.contains($0.lowercased()) }) {
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            for match in rule.regex.matches(in: text, range: range) {
                let extracted: String
                if let group = rule.secretGroup, group >= 0, group < match.numberOfRanges,
                   let r = Range(match.range(at: group), in: text) {
                    extracted = String(text[r])
                } else if let r = Range(match.range, in: text) {
                    extracted = String(text[r])
                } else {
                    continue
                }
                if let entropy = rule.entropy, Self.shannonEntropy(extracted) < entropy {
                    continue
                }
                return SecretMatch(rule: rule, secret: extracted)
            }
        }
        return nil
    }

    private static func shannonEntropy(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let total = Double(text.count)
        let counts = Dictionary(grouping: text, by: { $0 }).mapValues { Double($0.count) }
        return counts.values.reduce(0) { sum, count in
            let p = count / total
            return sum - p * log2(p)
        }
    }
}
