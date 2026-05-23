import Foundation

@main
struct AllowedToolsParserTests {
    static func main() {
        testNilInputReturnsNil()
        testEmptyStringReturnsNil()
        testWhitespaceOnlyReturnsNil()
        testSingleToolName()
        testMultipleToolNames()
        testParenthesizedPatternCollapsesToName()
        testMixedPatternsAndNames()
        testExtraWhitespace()
        testTabsAndNewlinesAsSeparators()
        testEmptyParens()
        testParensOnlyDropped()
        testYAMLNullLiteralReturnsNil()
        print("AllowedToolsParserTests passed")
    }

    static func testNilInputReturnsNil() {
        precondition(AllowedToolsParser.parse(nil) == nil)
    }

    static func testEmptyStringReturnsNil() {
        precondition(AllowedToolsParser.parse("") == nil)
    }

    static func testWhitespaceOnlyReturnsNil() {
        precondition(AllowedToolsParser.parse("   \t  \n  ") == nil)
    }

    static func testSingleToolName() {
        precondition(AllowedToolsParser.parse("Bash") == Set(["Bash"]))
    }

    static func testMultipleToolNames() {
        precondition(AllowedToolsParser.parse("Bash Read Write") == Set(["Bash", "Read", "Write"]))
    }

    static func testParenthesizedPatternCollapsesToName() {
        precondition(AllowedToolsParser.parse("Bash(git:*)") == Set(["Bash"]))
    }

    static func testMixedPatternsAndNames() {
        precondition(AllowedToolsParser.parse("Bash(git:*) Read Write(*.swift)") == Set(["Bash", "Read", "Write"]))
    }

    static func testExtraWhitespace() {
        precondition(AllowedToolsParser.parse("  Bash    Read  ") == Set(["Bash", "Read"]))
    }

    static func testTabsAndNewlinesAsSeparators() {
        precondition(AllowedToolsParser.parse("Bash\nRead\tWrite") == Set(["Bash", "Read", "Write"]))
    }

    static func testEmptyParens() {
        precondition(AllowedToolsParser.parse("Bash()") == Set(["Bash"]))
    }

    static func testParensOnlyDropped() {
        // "()" produces an empty token after stripping → dropped → empty set → nil.
        precondition(AllowedToolsParser.parse("()") == nil)
    }

    static func testYAMLNullLiteralReturnsNil() {
        // YAML's literal nulls — when a frontmatter parser keeps the raw text,
        // these arrive as the string "null"/"~", which used to surface as an
        // allow-set of {"null"} and silently strip every registered tool.
        precondition(AllowedToolsParser.parse("null") == nil)
        precondition(AllowedToolsParser.parse("Null") == nil)
        precondition(AllowedToolsParser.parse("NULL") == nil)
        precondition(AllowedToolsParser.parse("  null  ") == nil)
        precondition(AllowedToolsParser.parse("~") == nil)
        // Defensive: a real tool named "null" used inside a larger list is
        // still preserved verbatim (a sole "null" token is the YAML literal).
        precondition(AllowedToolsParser.parse("null Read") == Set(["null", "Read"]))
    }
}
