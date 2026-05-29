import Foundation

@main
struct ShellOutputTestRunner {
    static func main() async {
        testSubstituteQuery()
        testSubstituteEcho()
        testSubstituteUnknownPlaceholderLiteral()
        testSubstituteUnicode()
        testSubstituteSelectionAndClipboard()

        testLiteralTemplateAlwaysSubstantial()
        testAllPlaceholdersEmptyNotSubstantial()
        testOneNonEmptyResolutionSubstantial()

        testStripPassthrough()
        testStripCSIColor()
        testStripCSIMulti()
        testStripOSC()
        testStripBare()

        await runRunnerSmoke()

        print("ShellOutputTests passed")
    }

    static func runRunnerSmoke() async {
        do {
            let ok = try await ShellOutputRunner.run("echo hello", timeout: 5)
            expect(ok.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello",
                   "echo hello stdout mismatch, got: \(ok.stdout)")
            expect(ok.stderr.isEmpty, "echo hello should have no stderr, got: \(ok.stderr)")
            expect(ok.exitCode == 0, "echo hello exitCode mismatch, got: \(ok.exitCode)")
        } catch {
            fail("echo hello threw: \(error)")
        }

        do {
            let bad = try await ShellOutputRunner.run("false", timeout: 5)
            expect(bad.exitCode != 0, "`false` should have non-zero exit, got: \(bad.exitCode)")
        } catch {
            fail("false threw unexpectedly: \(error)")
        }

        do {
            _ = try await ShellOutputRunner.run("sleep 3", timeout: 0.5)
            fail("sleep 3 timeout=0.5 should have thrown .timeout")
        } catch ShellOutputRunnerError.timeout {
            // expected
        } catch {
            fail("sleep 3 threw wrong error: \(error)")
        }
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

    static func testStripPassthrough() {
        let got = ANSIStripper.strip("hello world")
        expect(got == "hello world", "plain text must passthrough, got: \(got)")
    }

    static func testStripCSIColor() {
        let input = "\u{001B}[31mRED\u{001B}[0m"
        let got = ANSIStripper.strip(input)
        expect(got == "RED", "CSI color stripping failed, got: \(got)")
    }

    static func testStripCSIMulti() {
        let input = "\u{001B}[1;32mBOLD GREEN\u{001B}[0m and \u{001B}[4munderlined\u{001B}[0m"
        let got = ANSIStripper.strip(input)
        expect(got == "BOLD GREEN and underlined", "multi-CSI strip failed, got: \(got)")
    }

    static func testStripOSC() {
        let input = "\u{001B}]0;my title\u{0007}body"
        let got = ANSIStripper.strip(input)
        expect(got == "body", "OSC strip failed, got: \(got)")
    }

    static func testStripBare() {
        let input = "\u{001B}xliteral"
        let got = ANSIStripper.strip(input)
        expect(got == "xliteral" || got == "literal",
               "bare ESC handling unexpected, got: \(got)")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { fail(msg) }
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }
}
