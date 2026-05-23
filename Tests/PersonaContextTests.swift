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
        testBuildPromptSources_empty()
        testBuildPromptSources_selectionOnly()
        testBuildPromptSources_selectionAndClipboardTop()
        testBuildPromptSources_clipboardHistoryOnly()
        testBuildPromptSources_sectionOrder()
        testBuildPromptSources_selectionEqualsClipboardTopDropsClip()
        testBuildPromptSources_emptyProvidersOmitSections()
        print("✅ PersonaContextTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }

    static func testEmpty() {
        let ctx = PersonaContext(selection: nil, clipboardTop: nil, clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "hello", contextMode: .selectionAndClipboard)
        expect(prompt == "[User said]\nhello", "empty ctx should emit only transcript section, got: \(prompt)")
    }

    static func testSelectionOnly() {
        let ctx = PersonaContext(selection: "the quick brown fox", clipboardTop: nil, clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "fix it", contextMode: .selectionAndClipboard)
        expect(prompt.contains("[Selected text]\nthe quick brown fox"), "selection section missing: \(prompt)")
        expect(prompt.contains("[User said]\nfix it"), "transcript section missing")
    }

    static func testClipboardOnly() {
        let ctx = PersonaContext(selection: nil, clipboardTop: "TODO list", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "translate", contextMode: .selectionAndClipboard)
        expect(prompt.contains("[Recent clipboard]\nTODO list"), "clipboard section missing")
    }

    static func testBoth() {
        let ctx = PersonaContext(selection: "S", clipboardTop: "C", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", contextMode: .selectionAndClipboard)
        expect(prompt.contains("[Selected text]\nS"), "missing selection")
        expect(prompt.contains("[Recent clipboard]\nC"), "missing clipboard")
        expect(prompt.contains("[User said]\nT"), "missing transcript")
    }

    static func testTranscriptMatchesSelection() {
        let ctx = PersonaContext(selection: "same", clipboardTop: nil, clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "same", contextMode: .selectionAndClipboard)
        expect(!prompt.contains("[User said]"), "transcript should be elided when equal to selection")
    }

    static func testCapTo7500UTF16() {
        let big = String(repeating: "x", count: 10_000)
        let ctx = PersonaContext(selection: big, clipboardTop: nil, clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "t", contextMode: .selectionAndClipboard)
        expect(prompt.utf16.count <= 7500, "expected ≤7500 UTF-16 units, got \(prompt.utf16.count)")
    }

    static func testNoneContextMode() {
        let ctx = PersonaContext(selection: "S", clipboardTop: "C", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", contextMode: .none)
        expect(prompt == "T", "contextMode=.none should return transcript only, got: \(prompt)")
    }

    static func testBuildPromptSources_empty() {
        let ctx = PersonaContext(selection: "S", clipboardTop: "C", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [])
        expect(prompt == "T", "empty sources should return transcript only, got: \(prompt)")
    }

    static func testBuildPromptSources_selectionOnly() {
        let ctx = PersonaContext(selection: "S body", clipboardTop: "C", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.selection])
        let expected = "[Selected text]\nS body\n\n[User said]\nT"
        expect(prompt == expected, "selection-only mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_selectionAndClipboardTop() {
        let ctx = PersonaContext(selection: "S", clipboardTop: "C", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.selection, .clipboardTop])
        let expected = "[Selected text]\nS\n\n[Recent clipboard]\nC\n\n[User said]\nT"
        expect(prompt == expected, "selection+clipboardTop mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_clipboardHistoryOnly() {
        let ctx = PersonaContext(selection: nil, clipboardTop: nil, clipboardHistory: ["a", "b", "c"], windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.clipboardHistory])
        let expected = "[Clipboard history]\n1. a\n2. b\n3. c\n\n[User said]\nT"
        expect(prompt == expected, "history mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_sectionOrder() {
        // Canonical order: selection → clipboardTop → clipboardHistory → windowOCR → user
        let ctx = PersonaContext(selection: "S", clipboardTop: "C", clipboardHistory: ["h1"], windowOCR: "W")
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.windowOCR, .clipboardHistory, .clipboardTop, .selection])
        let expected = "[Selected text]\nS\n\n[Recent clipboard]\nC\n\n[Clipboard history]\n1. h1\n\n[Window text]\nW\n\n[User said]\nT"
        expect(prompt == expected, "section order mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_selectionEqualsClipboardTopDropsClip() {
        let ctx = PersonaContext(selection: "same", clipboardTop: "same", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.selection, .clipboardTop])
        let expected = "[Selected text]\nsame\n\n[User said]\nT"
        expect(prompt == expected, "duplicate dedup mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_emptyProvidersOmitSections() {
        let ctx = PersonaContext(selection: nil, clipboardTop: "  ", clipboardHistory: [], windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.selection, .clipboardTop, .clipboardHistory, .windowOCR])
        expect(prompt == "T", "empty providers should produce no sections, got: \(prompt)")
    }
}
