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
}
