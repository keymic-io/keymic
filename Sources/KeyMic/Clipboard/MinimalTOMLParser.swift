import Foundation

enum TOMLValue: Equatable {
    case string(String)
    case array([String])
    case bareLiteral(String)   // captures unquoted RHS for numbers / booleans
}

enum MinimalTOMLParser {
    /// Parse a gitleaks-style TOML document and return the rules table array.
    /// Top-level non-rules tables and unsupported syntax are silently skipped.
    static func parseRules(_ text: String) -> [[String: TOMLValue]] {
        var rules: [[String: TOMLValue]] = []
        var current: [String: TOMLValue]? = nil
        var inHeader = false

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            var line = lines[i]
            i += 1

            line = stripInlineComment(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed == "[[rules]]" {
                if let cur = current { rules.append(cur) }
                current = [:]
                inHeader = true
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if let cur = current { rules.append(cur); current = nil }
                inHeader = true
                continue
            }

            guard inHeader, current != nil else { continue }

            guard let eq = trimmed.range(of: "=") else { continue }
            let key = trimmed[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            let rhs = trimmed[eq.upperBound...].trimmingCharacters(in: .whitespaces)

            if rhs.hasPrefix("'''") {
                var body = String(rhs.dropFirst(3))
                if let end = body.range(of: "'''") {
                    body = String(body[..<end.lowerBound])
                    current?[key] = .string(body)
                } else {
                    var collected = body
                    while i < lines.count {
                        let next = lines[i]; i += 1
                        if let end = next.range(of: "'''") {
                            collected += "\n" + String(next[..<end.lowerBound])
                            current?[key] = .string(collected)
                            break
                        } else {
                            collected += "\n" + next
                        }
                    }
                }
                continue
            }

            if rhs.hasPrefix("\"") {
                if let s = parseDoubleQuoted(String(rhs)) {
                    current?[key] = .string(s)
                }
                continue
            }

            if rhs.hasPrefix("'") {
                let body = rhs.dropFirst()
                if let end = body.firstIndex(of: "'") {
                    current?[key] = .string(String(body[..<end]))
                }
                continue
            }

            if rhs.hasPrefix("[") {
                var collected = String(rhs)
                while !arrayClosed(collected), i < lines.count {
                    collected += "\n" + stripInlineComment(lines[i]); i += 1
                }
                current?[key] = .array(parseStringArray(collected))
                continue
            }

            // Bare literal (numbers, booleans). Store raw text — caller decides how to interpret.
            current?[key] = .bareLiteral(String(rhs))
        }

        if let cur = current { rules.append(cur) }
        return rules
    }

    private static func stripInlineComment(_ line: String) -> String {
        var inDouble = false
        var inSingle = false
        var inTriple = false
        var i = line.startIndex
        var found: String.Index? = nil
        while i < line.endIndex {
            let c = line[i]
            if !inDouble && !inSingle && !inTriple {
                if c == "#" { found = i; break }
                if line[i...].hasPrefix("'''") {
                    inTriple = true; i = line.index(i, offsetBy: 3); continue
                }
                if c == "\"" { inDouble = true }
                else if c == "'" { inSingle = true }
            } else if inTriple {
                if line[i...].hasPrefix("'''") {
                    inTriple = false; i = line.index(i, offsetBy: 3); continue
                }
            } else if inDouble {
                if c == "\\", line.index(after: i) < line.endIndex {
                    i = line.index(after: i)
                } else if c == "\"" {
                    inDouble = false
                }
            } else if inSingle {
                if c == "'" { inSingle = false }
            }
            i = line.index(after: i)
        }
        if let f = found { return String(line[..<f]) }
        return line
    }

    private static func parseDoubleQuoted(_ rhs: String) -> String? {
        guard rhs.hasPrefix("\"") else { return nil }
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
                default: out.append(n)
                }
                i = rhs.index(after: next)
                continue
            }
            if c == "\"" { return out }
            out.append(c)
            i = rhs.index(after: i)
        }
        return nil
    }

    private static func arrayClosed(_ s: String) -> Bool {
        var depth = 0
        var inDouble = false
        var inSingle = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if !inDouble && !inSingle {
                if c == "[" { depth += 1 }
                else if c == "]" { depth -= 1; if depth == 0 { return true } }
                else if c == "\"" { inDouble = true }
                else if c == "'" { inSingle = true }
            } else if inDouble {
                if c == "\\", let next = s.index(i, offsetBy: 1, limitedBy: s.endIndex), next < s.endIndex {
                    i = next
                } else if c == "\"" { inDouble = false }
            } else if inSingle {
                if c == "'" { inSingle = false }
            }
            i = s.index(after: i)
        }
        return false
    }

    private static func parseStringArray(_ s: String) -> [String] {
        guard let lb = s.firstIndex(of: "["), let rb = s.lastIndex(of: "]"), lb < rb else { return [] }
        let body = s[s.index(after: lb)..<rb]
        var items: [String] = []
        var cur = ""
        var inDouble = false
        var inSingle = false
        var inTriple = false
        var i = body.startIndex
        while i < body.endIndex {
            let c = body[i]
            if !inDouble && !inSingle && !inTriple {
                if body[i...].hasPrefix("'''") {
                    inTriple = true; cur.append("'''"); i = body.index(i, offsetBy: 3); continue
                }
                if c == "\"" { inDouble = true; cur.append(c) }
                else if c == "'" { inSingle = true; cur.append(c) }
                else if c == "," { items.append(cur); cur = "" }
                else { cur.append(c) }
            } else if inTriple {
                cur.append(c)
                if body[i...].hasPrefix("'''") {
                    inTriple = false; cur.append("'''"); i = body.index(i, offsetBy: 3); continue
                }
            } else if inDouble {
                cur.append(c)
                if c == "\\", let next = body.index(i, offsetBy: 1, limitedBy: body.endIndex), next < body.endIndex {
                    cur.append(body[next]); i = next
                } else if c == "\"" { inDouble = false }
            } else if inSingle {
                cur.append(c)
                if c == "'" { inSingle = false }
            }
            i = body.index(after: i)
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(cur)
        }
        return items.compactMap(unwrapStringLiteral(_:))
    }

    private static func unwrapStringLiteral(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("\""), let unq = parseDoubleQuoted(s) { return unq }
        if s.hasPrefix("'") {
            let body = s.dropFirst()
            if let end = body.lastIndex(of: "'") { return String(body[..<end]) }
        }
        return nil
    }
}
