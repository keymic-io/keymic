import Foundation

@main
struct ShellOutputTestRunner {
    static func main() {
        testSubstituteQuery()
        testSubstituteEcho()
        testSubstituteUnknownPlaceholderLiteral()
        testSubstituteUnicode()
        testSubstituteSelectionAndClipboard()

        testLiteralTemplateAlwaysSubstantial()
        testAllPlaceholdersEmptyNotSubstantial()
        testOneNonEmptyResolutionSubstantial()

        print("ShellOutputTests passed")
    }

    static func testSubstituteQuery() {
        let got = ShellTemplate.substitute(template: "{query}", text: "foo", context: nil)
        expect(got == "foo", "{query} should substitute to text, got: \(got ?? "nil")")
    }

    static func testSubstituteEcho() {
        let got = ShellTemplate.substitute(template: "echo {query}", text: "hi there", context: nil)
        expect(got == "echo hi there", "echo passthrough mismatch, got: \(got ?? "nil")")
    }

    static func testSubstituteUnknownPlaceholderLiteral() {
        let got = ShellTemplate.substitute(template: "echo {unknown}", text: "anything", context: nil)
        expect(got == "echo {unknown}", "unknown placeholder must remain literal, got: \(got ?? "nil")")
    }

    static func testSubstituteUnicode() {
        let got = ShellTemplate.substitute(template: "echo {query}", text: "héllo 🌍", context: nil)
        expect(got == "echo héllo 🌍", "unicode passthrough failed, got: \(got ?? "nil")")
    }

    static func testSubstituteSelectionAndClipboard() {
        let ctx = PersonaContext(selection: "SEL", clipboardTop: "CLIP", clipboardHistory: nil, windowOCR: nil)
        let got = ShellTemplate.substitute(
            template: "cmd {selection} {clipboard}", text: "Q", context: ctx)
        expect(got == "cmd SEL CLIP",
               "selection+clipboard passthrough failed, got: \(got ?? "nil")")
    }

    static func testLiteralTemplateAlwaysSubstantial() {
        let ok = ShellTemplate.hasResolvedSubstantialContent(
            original: "ls -la", resolved: "ls -la")
        expect(ok, "literal templates (no placeholders) must be substantial")
    }

    static func testAllPlaceholdersEmptyNotSubstantial() {
        let ok = ShellTemplate.hasResolvedSubstantialContent(
            original: "rm -rf {selection}", resolved: "rm -rf ")
        expect(!ok, "empty-placeholder resolution must be refused")
    }

    static func testOneNonEmptyResolutionSubstantial() {
        let ok = ShellTemplate.hasResolvedSubstantialContent(
            original: "echo {query} {selection}", resolved: "echo hi ")
        expect(ok, "at least one non-empty placeholder is substantial")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { fail(msg) }
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }
}
