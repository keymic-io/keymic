import Foundation

@main
struct InvocationTestRunner {
    static func main() {
        // TextFragment codable round-trip preserves all fields.
        let frag = TextFragment(
            source: .clipboardItem,
            text: "hello",
            meta: ["index": "0"]
        )
        let data = try! JSONEncoder().encode(frag)
        let decoded = try! JSONDecoder().decode(TextFragment.self, from: data)
        expect(decoded == frag, "TextFragment round-trip preserves all fields")

        // TextSource raw values are stable strings (kept in sync with the spec).
        expect(TextSource.voice.rawValue == "voice",        "voice rawValue")
        expect(TextSource.selectedText.rawValue == "selectedText", "selectedText rawValue")
        expect(TextSource.clipboardItem.rawValue == "clipboardItem", "clipboardItem rawValue")
        expect(TextSource.userTyped.rawValue == "userTyped", "userTyped rawValue")
        expect(TextSource.phoneInput.rawValue == "phoneInput", "phoneInput rawValue")
        expect(TextSource.ocrWindow.rawValue == "ocrWindow", "ocrWindow rawValue")

        // BypassReason cases compile.
        let reasons: [BypassReason] = [.llmNotConfigured, .emptyInput, .shellConfirmDenied]
        expect(reasons.count == 3, "BypassReason has 3 cases")

        print("InvocationTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
