import AppKit
import Foundation

@main
struct OutputRouterTestRunner {
    static func main() async {
        testURLTemplateQuery()
        testURLTemplateSelection()
        testURLTemplateClipboard()
        testURLTemplateUnknownPlaceholderLiteral()
        testURLTemplateSchemeValidationRejectsJavascript()
        testURLTemplateSchemeValidationRejectsFile()
        testURLTemplateSchemeValidationAcceptsHTTPS()
        testURLTemplateSchemeValidationAcceptsMailto()
        await testReplaceFocusedTextCallsInject()
        print("✅ OutputRouterTests passed")
    }

    @MainActor
    static func testReplaceFocusedTextCallsInject() async {
        var injected: [String] = []
        let router = OutputRouter(
            inject: { injected.append($0) },
            readSelection: { nil },
            writeSelection: { _ in false },
            onMarkIgnored: { _ in })
        let output = PersonaOutput(
            text: "hello",
            strategy: .replaceFocusedText,
            originatingApp: nil,
            context: nil)
        let result = await router.route(output)
        expect(injected == ["hello"], "expected one inject call, got: \(injected)")
        expect(result == .injected, "expected .injected, got: \(result)")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }

    static func testURLTemplateQuery() {
        let out = URLTemplate.substitute(
            template: "https://example.com?q={query}",
            text: "hello world",
            context: nil)
        expect(out == "https://example.com?q=hello%20world",
               "expected percent-encoded query, got: \(out ?? "nil")")
    }

    static func testURLTemplateSelection() {
        let ctx = PersonaContext(selection: "café", clipboardTop: nil)
        let out = URLTemplate.substitute(
            template: "https://t.com?s={selection}",
            text: "ignored",
            context: ctx)
        expect(out == "https://t.com?s=caf%C3%A9", "got: \(out ?? "nil")")
    }

    static func testURLTemplateClipboard() {
        let ctx = PersonaContext(selection: nil, clipboardTop: "todo")
        let out = URLTemplate.substitute(
            template: "https://t.com?c={clipboard}",
            text: "ignored",
            context: ctx)
        expect(out == "https://t.com?c=todo", "got: \(out ?? "nil")")
    }

    static func testURLTemplateUnknownPlaceholderLiteral() {
        let out = URLTemplate.substitute(
            template: "https://t.com?x={mystery}",
            text: "t",
            context: nil)
        expect(out == "https://t.com?x={mystery}",
               "unknown placeholders must be left literal, got: \(out ?? "nil")")
    }

    static func testURLTemplateSchemeValidationRejectsJavascript() {
        let result = URLTemplate.validateScheme("javascript:alert(1)")
        expect(!result, "javascript: must be rejected")
    }

    static func testURLTemplateSchemeValidationRejectsFile() {
        let result = URLTemplate.validateScheme("file:///etc/passwd")
        expect(!result, "file:// must be rejected")
    }

    static func testURLTemplateSchemeValidationAcceptsHTTPS() {
        expect(URLTemplate.validateScheme("https://example.com"), "https must be accepted")
    }

    static func testURLTemplateSchemeValidationAcceptsMailto() {
        expect(URLTemplate.validateScheme("mailto:a@b.com"), "mailto must be accepted")
    }
}
