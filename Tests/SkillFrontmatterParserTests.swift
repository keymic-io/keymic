import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        print("FAIL: \(message). Expected \(expected), got \(actual)")
        Foundation.exit(1)
    }
}

func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        Foundation.exit(1)
    }
}

func assertFalse(_ condition: Bool, _ message: String) {
    if condition {
        print("FAIL: \(message)")
        Foundation.exit(1)
    }
}

func assertNil<T>(_ value: T?, _ message: String) {
    if value != nil {
        print("FAIL: \(message). Expected nil")
        Foundation.exit(1)
    }
}

func assertNotNil<T>(_ value: T?, _ message: String) -> T {
    guard let value else {
        print("FAIL: \(message). Expected non-nil")
        Foundation.exit(1)
    }
    return value
}

@main
struct SkillFrontmatterParserTests {
    static func main() {
        let parser = SkillFrontmatterParser()

        assertTrue(parser.hasFrontmatter("---\nname: demo\n---"), "detects frontmatter with LF")
        assertTrue(parser.hasFrontmatter("  ---  \rname: demo\r---"), "detects frontmatter with CR")
        assertFalse(parser.hasFrontmatter("name: demo\n---"), "rejects missing opening marker")
        assertTrue(parser.hasFrontmatter("\u{FEFF}---\nname: demo\n---"), "detects frontmatter after UTF-8 BOM")

        let minimal = assertNotNil(
            parser.parse("---\nname: demo\ndescription: Test skill\n---\nUse this skill."),
            "parses minimal frontmatter"
        )
        assertEqual(minimal.fields["name"], "demo", "parses name field")
        assertEqual(minimal.fields["description"], "Test skill", "parses description field")
        assertEqual(minimal.body, "Use this skill.", "parses body after closing marker")

        let quoted = assertNotNil(
            parser.parse("---\n'name': \"quoted-skill\"\n\"description\": 'Quoted description'\n---\nBody"),
            "parses quoted keys and values"
        )
        assertEqual(quoted.fields["name"], "quoted-skill", "strips quotes from values")
        assertEqual(quoted.fields["description"], "Quoted description", "strips single quotes from values")

        let commentsAndBlanks = assertNotNil(
            parser.parse("---\n# comment\n\nname: comments\ninvalid line\nallowed-tools: Bash, Read\n---\nBody"),
            "parses comments and blanks"
        )
        assertEqual(commentsAndBlanks.fields.count, 2, "ignores comments, blank lines, and malformed lines")
        assertEqual(commentsAndBlanks.fields["allowed-tools"], "Bash, Read", "keeps values containing punctuation")

        assertNil(parser.parse("---\nname: missing-close\nBody"), "returns nil for missing closing marker")

        let emptyBody = assertNotNil(parser.parse("---\nname: empty-body\n---"), "parses empty body")
        assertEqual(emptyBody.body, "", "empty body is empty string")

        let repeated = assertNotNil(
            parser.parse("---\nname: first\nname: second\n---\nBody"),
            "parses repeated keys"
        )
        assertEqual(repeated.fields["name"], "second", "last repeated key wins")

        let lowercased = assertNotNil(
            parser.parse("---\nName: Demo\nDESCRIPTION: Upper key\n---\nBody"),
            "parses uppercased keys"
        )
        assertEqual(lowercased.fields["name"], "Demo", "lowercases name key")
        assertEqual(lowercased.fields["description"], "Upper key", "lowercases description key")

        assertTrue(SkillMetadata.isValidName("valid-skill-123"), "accepts lowercase letters hyphen digits")
        assertFalse(SkillMetadata.isValidName("Invalid"), "rejects uppercase")
        assertFalse(SkillMetadata.isValidName("invalid_name"), "rejects underscore")
        assertFalse(SkillMetadata.isValidName("invalid/name"), "rejects slash")
        assertFalse(SkillMetadata.isValidName(""), "rejects empty name")
        assertFalse(SkillMetadata.isValidName(String(repeating: "a", count: 65)), "rejects names longer than 64 characters")

        print("SkillFrontmatterParserTests passed")
    }
}
