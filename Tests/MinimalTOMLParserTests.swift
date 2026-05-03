import Foundation

@main
struct MinimalTOMLParserTestRunner {
    static func main() {
        let s1 = """
        title = "gitleaks config"

        [[rules]]
        id = "aws-key"
        description = "AWS Access Key"
        regex = '''AKIA[0-9A-Z]{16}'''
        keywords = ["AKIA"]
        """
        let r1 = MinimalTOMLParser.parseRules(s1)
        expect(r1.count == 1, "one rule parsed (header table ignored)")
        expect(r1[0]["id"]?.asString == "aws-key", "id parsed")
        expect(r1[0]["regex"]?.asString == "AKIA[0-9A-Z]{16}", "triple-single-quote regex parsed")
        expect(r1[0]["keywords"]?.asArray == ["AKIA"], "keywords array parsed")

        let s2 = """
        [[rules]]
        id = "tricky"
        regex = '''(?i)\\b'foo'\\b'''
        """
        let r2 = MinimalTOMLParser.parseRules(s2)
        expect(r2.count == 1, "tricky regex rule parsed")
        expect(r2[0]["regex"]?.asString == #"(?i)\b'foo'\b"#, "literal preserved")

        let s3 = """
        # top comment
        [[rules]]
        id = "multi"
        regex = '''x'''
        keywords = [
          "a",  # inline comment ignored
          "b",
          "c",
        ]
        """
        let r3 = MinimalTOMLParser.parseRules(s3)
        expect(r3.count == 1, "comments ignored")
        expect(r3[0]["keywords"]?.asArray == ["a", "b", "c"], "multiline array")

        let s4 = """
        [[rules]]
        id = "first"
        regex = '''x'''

        [[rules]]
        id = "second-no-regex"
        keywords = ["x"]
        """
        let r4 = MinimalTOMLParser.parseRules(s4)
        expect(r4.count == 2, "second rule still parsed")
        expect(r4[1]["regex"] == nil, "missing regex stays missing")

        // Bare literals (numbers, booleans) preserved as raw strings
        let bare = MinimalTOMLParser.parseRules("""
        [[rules]]
        id = "x"
        regex = "y"
        entropy = 3.5
        secretGroup = 2
        """)
        expect(bare.count == 1, "single rule")
        if case let .bareLiteral(e)? = bare[0]["entropy"] {
            expect(e.trimmingCharacters(in: .whitespaces) == "3.5", "entropy bare literal preserved")
        } else { fatalError("entropy not bareLiteral") }
        if case let .bareLiteral(g)? = bare[0]["secretGroup"] {
            expect(g.trimmingCharacters(in: .whitespaces) == "2", "secretGroup bare literal preserved")
        } else { fatalError("secretGroup not bareLiteral") }

        print("MinimalTOMLParserTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

private extension TOMLValue {
    var asString: String? { if case .string(let s) = self { return s } else { return nil } }
    var asArray: [String]? { if case .array(let a) = self { return a } else { return nil } }
}
