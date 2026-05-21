import Foundation

@main
struct PersonaContextTestRunner {
    static func main() {
        testEmpty()
        testSelectionOnly()
        testClipboardOnly()
        testBoth()
        testTranscriptMatchesSelection()
        testCapTo7500UTF16()
        testNoneContextMode()
        print("✅ PersonaContextTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }

    static func testEmpty() {
        let ctx = PersonaContext(selection: nil, clipboardTop: nil)
        let prompt = ctx.buildPrompt(transcript: "hello", contextMode: .selectionAndClipboard)
        expect(prompt == "[User said]\nhello", "empty ctx should emit only transcript section, got: \(prompt)")
    }

    static func testSelectionOnly() {
        let ctx = PersonaContext(selection: "the quick brown fox", clipboardTop: nil)
        let prompt = ctx.buildPrompt(transcript: "fix it", contextMode: .selectionAndClipboard)
        expect(prompt.contains("[Selected text]\nthe quick brown fox"), "selection section missing: \(prompt)")
        expect(prompt.contains("[User said]\nfix it"), "transcript section missing")
    }

    static func testClipboardOnly() {
        let ctx = PersonaContext(selection: nil, clipboardTop: "TODO list")
        let prompt = ctx.buildPrompt(transcript: "translate", contextMode: .selectionAndClipboard)
        expect(prompt.contains("[Recent clipboard]\nTODO list"), "clipboard section missing")
    }

    static func testBoth() {
        let ctx = PersonaContext(selection: "S", clipboardTop: "C")
        let prompt = ctx.buildPrompt(transcript: "T", contextMode: .selectionAndClipboard)
        expect(prompt.contains("[Selected text]\nS"), "missing selection")
        expect(prompt.contains("[Recent clipboard]\nC"), "missing clipboard")
        expect(prompt.contains("[User said]\nT"), "missing transcript")
    }

    static func testTranscriptMatchesSelection() {
        let ctx = PersonaContext(selection: "same", clipboardTop: nil)
        let prompt = ctx.buildPrompt(transcript: "same", contextMode: .selectionAndClipboard)
        expect(!prompt.contains("[User said]"), "transcript should be elided when equal to selection")
    }

    static func testCapTo7500UTF16() {
        let big = String(repeating: "x", count: 10_000)
        let ctx = PersonaContext(selection: big, clipboardTop: nil)
        let prompt = ctx.buildPrompt(transcript: "t", contextMode: .selectionAndClipboard)
        expect(prompt.utf16.count <= 7500, "expected ≤7500 UTF-16 units, got \(prompt.utf16.count)")
    }

    static func testNoneContextMode() {
        let ctx = PersonaContext(selection: "S", clipboardTop: "C")
        let prompt = ctx.buildPrompt(transcript: "T", contextMode: .none)
        expect(prompt == "T", "contextMode=.none should return transcript only, got: \(prompt)")
    }
}
