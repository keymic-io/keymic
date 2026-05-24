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
        await testClipboardStrategyWritesAndMarksIgnored()
        await testReplaceSelectionWriteSucceeds()
        await testReplaceSelectionWriteFailsFallback()
        await testReplaceSelectionNoSelectionFallback()
        await testOpenURLHappyPath()
        await testOpenURLRejectsJavascript()
        await testRunShellWithDefaultConfirmReturnsUserCancelled()
        await testWriteToITermFailsCleanlyWhenNotInstalled()
        print("✅ OutputRouterTests passed")
    }

    @MainActor
    static func testRunShellWithDefaultConfirmReturnsUserCancelled() async {
        // Default `confirmShellRun` is `{ _ in false }` — a safety stub that always cancels.
        // Production wires `ShellConfirmationSheet.present`.
        let router = OutputRouter(
            inject: { _ in expect(false, "must not paste when default confirm denies") },
            readSelection: { nil },
            writeSelection: { _ in false },
            onMarkIgnored: { _ in })
        let output = PersonaOutput(text: "ls",
                                   strategy: .runShell(commandTemplate: "ls"),
                                   originatingApp: nil, context: nil)
        let result = await router.route(output)
        expect(result == .userCancelled, "expected .userCancelled (default confirm denies), got: \(result)")
    }

    @MainActor
    static func testWriteToITermFailsCleanlyWhenNotInstalled() async {
        // Cannot easily stub ITermAvailability without making it injectable. On a dev
        // machine WITH iTerm installed, the call routes into ITermBridge which may
        // trigger an Automation prompt — so we skip the assertion when iTerm is present.
        // T13 will add stubbable coverage with `runShellExecutor`-style seams.
        guard !ITermAvailability.isInstalled() else { return }

        let router = OutputRouter(
            inject: { _ in expect(false, "must not paste for iTerm strategy") },
            readSelection: { nil },
            writeSelection: { _ in false },
            onMarkIgnored: { _ in })
        let output = PersonaOutput(text: "x",
                                   strategy: .writeToITermPane(paneIndex: 0),
                                   originatingApp: nil, context: nil)
        let result = await router.route(output)
        if case .failed(let msg) = result {
            expect(msg.contains("not installed"), "expected not-installed message, got: \(msg)")
        } else { expect(false, "expected .failed, got: \(result)") }
    }

    @MainActor
    static func testOpenURLHappyPath() async {
        var openedURLs: [URL] = []
        let router = OutputRouter(
            inject: { _ in },
            readSelection: { nil },
            writeSelection: { _ in false },
            onMarkIgnored: { _ in })
        router.openURLHandler = { url in openedURLs.append(url); return true }
        let output = PersonaOutput(
            text: "hello world",
            strategy: .openURL(template: "https://example.com?q={query}"),
            originatingApp: nil,
            context: nil)
        let result = await router.route(output)
        expect(result == .injected, "got: \(result)")
        expect(openedURLs.map(\.absoluteString) == ["https://example.com?q=hello%20world"],
               "expected URL opened, got: \(openedURLs)")
    }

    @MainActor
    static func testOpenURLRejectsJavascript() async {
        var openedURLs: [URL] = []
        let router = OutputRouter(
            inject: { _ in },
            readSelection: { nil },
            writeSelection: { _ in false },
            onMarkIgnored: { _ in })
        router.openURLHandler = { url in openedURLs.append(url); return true }
        let output = PersonaOutput(
            text: "x",
            strategy: .openURL(template: "javascript:alert(1)"),
            originatingApp: nil,
            context: nil)
        let result = await router.route(output)
        if case .failed = result {
            // OK
        } else {
            expect(false, "expected .failed for javascript: URL, got \(result)")
        }
        expect(openedURLs.isEmpty, "must not open rejected URL")
    }

    @MainActor
    static func testReplaceSelectionWriteSucceeds() async {
        var written: [String] = []
        let router = OutputRouter(
            inject: { _ in expect(false, "must not paste in happy path") },
            readSelection: { "old" },
            writeSelection: { txt in written.append(txt); return true },
            onMarkIgnored: { _ in })
        let output = PersonaOutput(text: "new", strategy: .replaceSelection,
                                   originatingApp: nil, context: nil)
        let result = await router.route(output)
        expect(written == ["new"], "expected writeSelection call, got: \(written)")
        expect(result == .injected, "got: \(result)")
    }

    @MainActor
    static func testReplaceSelectionWriteFailsFallback() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("OutputRouterTest.replaceWriteFail"))
        var injected: [String] = []
        let router = OutputRouter(
            inject: { injected.append($0) },
            readSelection: { "ro" },
            writeSelection: { _ in false },
            pasteboard: pb,
            onMarkIgnored: { _ in })
        let output = PersonaOutput(text: "txt", strategy: .replaceSelection,
                                   originatingApp: nil, context: nil)
        let result = await router.route(output)
        expect(injected.isEmpty, "fallback must not paste, got injects: \(injected)")
        expect(pb.string(forType: .string) == "txt", "fallback must write clipboard")
        expect(result == .fellBackToClipboard(reason: .selectionNotEditable),
               "got: \(result)")
    }

    @MainActor
    static func testReplaceSelectionNoSelectionFallback() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("OutputRouterTest.noSel"))
        var writeAttempts = 0
        let router = OutputRouter(
            inject: { _ in },
            readSelection: { nil },
            writeSelection: { _ in writeAttempts += 1; return false },
            pasteboard: pb,
            onMarkIgnored: { _ in })
        let output = PersonaOutput(text: "txt", strategy: .replaceSelection,
                                   originatingApp: nil, context: nil)
        let result = await router.route(output)
        expect(writeAttempts == 0, "must not attempt write when selection nil, got \(writeAttempts)")
        expect(pb.string(forType: .string) == "txt", "fallback must write clipboard")
        expect(result == .fellBackToClipboard(reason: .noFocusedElement),
               "got: \(result)")
    }

    @MainActor
    static func testClipboardStrategyWritesAndMarksIgnored() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("OutputRouterTest.clipboard"))
        var injected: [String] = []
        var ignored: [String] = []
        let router = OutputRouter(
            inject: { injected.append($0) },
            readSelection: { nil },
            writeSelection: { _ in false },
            pasteboard: pb,
            onMarkIgnored: { ignored.append($0) })
        let output = PersonaOutput(text: "routed", strategy: .clipboard,
                                   originatingApp: nil, context: nil)
        let result = await router.route(output)
        expect(result == .injected, "got: \(result)")
        expect(injected.isEmpty, "clipboard strategy must not paste")
        expect(pb.string(forType: .string) == "routed", "clipboard not written")
        expect(ignored == ["routed"], "expected onMarkIgnored to receive 'routed', got: \(ignored)")
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
        let ctx = PersonaContext(selection: "café", clipboardTop: nil, clipboardHistory: nil, windowOCR: nil)
        let out = URLTemplate.substitute(
            template: "https://t.com?s={selection}",
            text: "ignored",
            context: ctx)
        expect(out == "https://t.com?s=caf%C3%A9", "got: \(out ?? "nil")")
    }

    static func testURLTemplateClipboard() {
        let ctx = PersonaContext(selection: nil, clipboardTop: "todo", clipboardHistory: nil, windowOCR: nil)
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
