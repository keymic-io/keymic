import Foundation

// Pure-logic test runner for the Selected Text Editor module.
// Mirrors the project convention: standalone @main runner, prints "… passed"
// on success, exit(1) on failure. Imports only Foundation so the compile graph
// stays narrow (matches test-pasteboard-snapshot / test-selection-copy-wait).

@main
struct SelectedTextEditorTestRunner {
    static func main() {
        testPromptTemplatesNonEmpty()
        testBuildInstructionFreeForm()
        testBuildInstructionFreeFormEmptyIsEmpty()
        testBuildInstructionActionOnly()
        testBuildInstructionActionWithTyped()
        testBuildInstructionTrimsWhitespace()
        testComposeUserMessageFormat()
        testSystemPromptHasGuidance()
        print("SelectedTextEditorTests passed")
    }

    // MARK: - EditorAction

    static func testPromptTemplatesNonEmpty() {
        // .freeForm is intentionally empty; all other cases must have non-empty templates.
        let nonEmpty: [EditorAction] = [.expand, .shrink, .translate, .polish]
        for action in nonEmpty {
            assertTrue(!action.promptTemplate.isEmpty,
                       "Expected non-empty promptTemplate for \(action.rawValue)")
        }
        assertEqual(EditorAction.freeForm.promptTemplate, "",
                    "freeForm should have empty promptTemplate")
        assertEqual(EditorAction.allCases.count, 5,
                    "EditorAction should have 5 cases")
    }

    // MARK: - buildInstruction

    static func testBuildInstructionFreeForm() {
        let result = EditorPrompt.buildInstruction(action: .freeForm, typed: "make it shorter")
        assertEqual(result, "make it shorter", "freeForm with typed should pass typed verbatim")
    }

    static func testBuildInstructionFreeFormEmptyIsEmpty() {
        let result = EditorPrompt.buildInstruction(action: .freeForm, typed: "   ")
        assertEqual(result, "", "freeForm with whitespace-only typed should be empty")
    }

    static func testBuildInstructionActionOnly() {
        let result = EditorPrompt.buildInstruction(action: .polish, typed: "")
        assertEqual(result, EditorAction.polish.promptTemplate,
                    "polish with empty typed should return template only")
    }

    static func testBuildInstructionActionWithTyped() {
        let result = EditorPrompt.buildInstruction(action: .polish, typed: "make it sound formal")
        let expected = EditorAction.polish.promptTemplate + "\n\n" + "make it sound formal"
        assertEqual(result, expected,
                    "polish with typed should be template + \\n\\n + typed")
    }

    static func testBuildInstructionTrimsWhitespace() {
        let result = EditorPrompt.buildInstruction(action: .shrink, typed: "  hello  ")
        let expected = EditorAction.shrink.promptTemplate + "\n\n" + "hello"
        assertEqual(result, expected, "buildInstruction should trim typed input")
    }

    // MARK: - composeUserMessage

    static func testComposeUserMessageFormat() {
        let msg = EditorPrompt.composeUserMessage(selection: "S body", instruction: "I body")
        assertEqual(msg, "[Selected text]\nS body\n\n[Instruction]\nI body",
                    "composeUserMessage must produce two labelled blocks separated by blank line")
    }

    // MARK: - systemPrompt

    static func testSystemPromptHasGuidance() {
        let p = EditorPrompt.systemPrompt
        assertTrue(p.contains("editor"), "system prompt should mention 'editor'")
        assertTrue(p.contains("ONLY"), "system prompt should emphasise return-only constraint")
    }

    // MARK: - assertions

    static func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String,
                                          file: StaticString = #file, line: UInt = #line) {
        if a != b {
            FileHandle.standardError.write(Data("FAIL: \(message)\n  got: \(a)\n  expected: \(b)\n  at \(file):\(line)\n".utf8))
            exit(1)
        }
    }

    static func assertTrue(_ cond: Bool, _ message: String,
                           file: StaticString = #file, line: UInt = #line) {
        if !cond {
            FileHandle.standardError.write(Data("FAIL: \(message)\n  at \(file):\(line)\n".utf8))
            exit(1)
        }
    }
}
