import Foundation

@main
struct ContextSourceTestRunner {
    static func main() {
        testAllCases()
        testCodableRoundTrip()
        testCodableArrayEncoding()
        testDisplayNameNonEmpty()
        print("ContextSourceTests passed")
    }

    static func testAllCases() {
        let expected: [ContextSource] = [.selection, .clipboardTop, .clipboardHistory, .windowOCR]
        let got = ContextSource.allCases
        if got != expected {
            FileHandle.standardError.write(Data("FAIL: ContextSource.allCases order changed\n  got: \(got)\n  expected: \(expected)\n".utf8))
            exit(1)
        }
    }

    static func testCodableRoundTrip() {
        for src in ContextSource.allCases {
            let data = try! JSONEncoder().encode(src)
            let decoded = try! JSONDecoder().decode(ContextSource.self, from: data)
            if decoded != src {
                FileHandle.standardError.write(Data("FAIL: Codable round-trip for \(src) gave \(decoded)\n".utf8))
                exit(1)
            }
        }
    }

    static func testCodableArrayEncoding() {
        // Persona's contextSources is Set<ContextSource>; encoded form is JSON array of rawValues
        // since Set<RawRepresentable> uses unkeyed container.
        let set: Set<ContextSource> = [.selection, .clipboardTop]
        let data = try! JSONEncoder().encode(set)
        let decoded = try! JSONDecoder().decode(Set<ContextSource>.self, from: data)
        if decoded != set {
            FileHandle.standardError.write(Data("FAIL: Set<ContextSource> round-trip mismatch: \(decoded) vs \(set)\n".utf8))
            exit(1)
        }
    }

    static func testDisplayNameNonEmpty() {
        for src in ContextSource.allCases {
            if src.displayName.isEmpty {
                FileHandle.standardError.write(Data("FAIL: \(src) has empty displayName\n".utf8))
                exit(1)
            }
        }
    }
}
