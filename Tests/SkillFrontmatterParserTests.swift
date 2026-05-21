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

        let bom = assertNotNil(
            parser.parse("\u{FEFF}---\nname: bom\n---\nBody"),
            "parse tolerates UTF-8 BOM"
        )
        assertEqual(bom.fields["name"], "bom", "parses fields after UTF-8 BOM")
        assertEqual(bom.body, "Body", "parses body after UTF-8 BOM")

        let crlf = assertNotNil(
            parser.parse("---\r\nname: crlf\r\ndescription: CRLF skill\r\n---\r\nBody\r\nNext"),
            "parse tolerates CRLF line endings"
        )
        assertEqual(crlf.fields["name"], "crlf", "parses CRLF fields")
        assertEqual(crlf.body, "Body\nNext", "normalizes CRLF body line endings")

        assertNil(parser.parse("name: absent\n---\nBody"), "returns nil when opening marker is absent")

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

        let emptyKey = assertNotNil(
            parser.parse("---\n: ignored\nname: empty-key\n---\nBody"),
            "parses frontmatter with empty key"
        )
        assertEqual(emptyKey.fields.count, 1, "ignores empty keys")
        assertEqual(emptyKey.fields["name"], "empty-key", "keeps non-empty keys when empty key is present")

        assertNil(parser.parse("---\nname: missing-close\nBody"), "returns nil for missing closing marker")

        let emptyBody = assertNotNil(parser.parse("---\nname: empty-body\n---"), "parses empty body")
        assertEqual(emptyBody.body, "", "empty body is empty string")

        let preservedBody = assertNotNil(
            parser.parse("---\nname: preserve\n---\n    let value = 1\n  trailing spaces  \n"),
            "parses body with leading indentation and trailing whitespace"
        )
        assertEqual(
            preservedBody.body,
            "    let value = 1\n  trailing spaces  \n",
            "preserves body leading indentation, trailing spaces, and trailing newline"
        )

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
