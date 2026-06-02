import Foundation

@main
struct ClipboardTransformPromptTestRunner {
    static func main() {
        testComposeEmpty()
        testComposeSingle()
        testComposeMultiple()
        testComposeOrdering()
        testValidateSize_underCap()
        testValidateSize_perItemOverCap()
        testValidateSize_combinedOverCap()
        testSystemPromptFallbackNonEmpty()
        print("ClipboardTransformPromptTests passed")
    }

    static func testComposeEmpty() {
        let got = ClipboardTransformPrompt.composeBatchUserMessage(items: [])
        if got != "" {
            fail("empty items should produce empty string, got: \(got)")
        }
    }

    static func testComposeSingle() {
        let got = ClipboardTransformPrompt.composeBatchUserMessage(items: ["one"])
        let want = "[Item 1]\none"
        if got != want { fail("single mismatch:\ngot: \(got)\nwant: \(want)") }
    }

    static func testComposeMultiple() {
        let got = ClipboardTransformPrompt.composeBatchUserMessage(items: ["a", "b"])
        let want = "[Item 1]\na\n\n[Item 2]\nb"
        if got != want { fail("multi mismatch:\ngot: \(got)\nwant: \(want)") }
    }

    static func testComposeOrdering() {
        let got = ClipboardTransformPrompt.composeBatchUserMessage(items: ["x", "y", "z"])
        let want = "[Item 1]\nx\n\n[Item 2]\ny\n\n[Item 3]\nz"
        if got != want { fail("order mismatch:\ngot: \(got)\nwant: \(want)") }
    }

    static func testValidateSize_underCap() {
        let result = ClipboardTransformPrompt.validateSize(items: ["short", "also short"])
        if result != nil { fail("under-cap should return nil, got: \(result!)") }
    }

    static func testValidateSize_perItemOverCap() {
        let big = String(repeating: "a", count: 60_000)
        let result = ClipboardTransformPrompt.validateSize(items: [big])
        if result == nil { fail("per-item over cap should return error, got nil") }
    }

    static func testValidateSize_combinedOverCap() {
        let item = String(repeating: "b", count: 49_000)
        let items = [item, item, item]
        let result = ClipboardTransformPrompt.validateSize(items: items)
        if result == nil { fail("combined over cap should return error, got nil") }
    }

    static func testSystemPromptFallbackNonEmpty() {
        if ClipboardTransformPrompt.systemPromptFallback.isEmpty {
            fail("systemPromptFallback should be non-empty")
        }
    }

    static func fail(_ msg: String) {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }
}
