import Foundation

@main
struct ContextResolverTestRunner {
    static func main() {
        runResolveTable()
        runTriggerPrefillWins()
        runClipboardHistoryCount()
        print("ContextResolverTests passed")
    }

    static func runResolveTable() {
        let res = makeResolver(
            selectionText: "SEL",
            clipboardText: "CLIP",
            historyTexts: ["H0", "H1", "H2"],
            ocrText: nil
        )

        // .none — nothing added
        var out = sync { await res.resolve(persona: persona(.none), prefilled: []) }
        expect(out.isEmpty, "contextMode .none → no fragments")

        // .selection
        out = sync { await res.resolve(persona: persona(.selection), prefilled: []) }
        expect(out.map(\.source) == [.selectedText], ".selection → [selectedText]")
        expect(out[0].text == "SEL", ".selection → text 'SEL'")

        // .clipboard
        out = sync { await res.resolve(persona: persona(.clipboard), prefilled: []) }
        expect(out.map(\.source) == [.clipboardItem], ".clipboard → [clipboardItem]")
        expect(out[0].text == "CLIP", ".clipboard → text 'CLIP'")

        // .clipboardHistory (default contextCount = 1)
        out = sync { await res.resolve(persona: persona(.clipboardHistory, count: 2), prefilled: []) }
        expect(out.count == 2, ".clipboardHistory count=2 → 2 fragments")
        expect(out[0].text == "H0" && out[1].text == "H1",
            ".clipboardHistory returns newest first")

        // .selectionAndClipboard
        out = sync { await res.resolve(persona: persona(.selectionAndClipboard), prefilled: []) }
        expect(out.map(\.source) == [.selectedText, .clipboardItem],
            ".selectionAndClipboard → both, selection first")

        // .windowOCR (stub returns nil → no fragment added)
        out = sync { await res.resolve(persona: persona(.windowOCR), prefilled: []) }
        expect(out.isEmpty, ".windowOCR with stub → no fragments")
    }

    static func runTriggerPrefillWins() {
        let res = makeResolver(
            selectionText: "SEL-FROM-AX",
            clipboardText: "CLIP",
            historyTexts: [],
            ocrText: nil
        )
        let prefilled = [TextFragment(source: .selectedText, text: "TRIGGER-WINS", meta: [:])]
        let out = sync { await res.resolve(persona: persona(.selectionAndClipboard), prefilled: prefilled) }
        let sel = out.first { $0.source == .selectedText }
        expect(sel?.text == "TRIGGER-WINS",
            "trigger-prefilled .selectedText wins over resolver AX read")
        expect(out.contains { $0.source == .clipboardItem && $0.text == "CLIP" },
            ".clipboard still resolved when not prefilled")
    }

    static func runClipboardHistoryCount() {
        let res = makeResolver(
            selectionText: nil,
            clipboardText: nil,
            historyTexts: ["A", "B", "C", "D"],
            ocrText: nil
        )
        let out = sync { await res.resolve(persona: persona(.clipboardHistory, count: 3), prefilled: []) }
        expect(out.count == 3, "clipboardHistory respects persona.contextCount")
    }

    // MARK: helpers

    static func makeResolver(
        selectionText: String?,
        clipboardText: String?,
        historyTexts: [String],
        ocrText: String?
    ) -> ContextResolver {
        ContextResolver(
            selection: StubSource(.selectedText, text: selectionText),
            clipboard: StubSource(.clipboardItem, text: clipboardText),
            clipboardHistory: StubClipboardHistorySource(texts: historyTexts),
            windowOCR: StubSource(.ocrWindow, text: ocrText)
        )
    }

    static func persona(_ mode: ContextMode, count: Int = 1) -> Persona {
        Persona(
            id: "test", name: "T", icon: "x", stylePrompt: "",
            temperature: 0.0, hotkey: nil,
            contextMode: mode, contextCount: count,
            outputStrategy: .replaceFocusedText,
            builtIn: false,
            createdAt: Date(), updatedAt: Date()
        )
    }

    static func sync<T>(_ work: @escaping () async -> T) -> T {
        // Synchronously run an async closure on a fresh Task — sufficient for
        // our pure in-memory stubs (no actual concurrency).
        var result: T?
        let sema = DispatchSemaphore(value: 0)
        Task { result = await work(); sema.signal() }
        sema.wait()
        return result!
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}

final class StubSource: ContextSource {
    let providedKind: TextSource
    private let text: String?
    init(_ kind: TextSource, text: String?) {
        self.providedKind = kind
        self.text = text
    }
    func read() async throws -> TextFragment? {
        guard let t = text, !t.isEmpty else { return nil }
        return TextFragment(source: providedKind, text: t, meta: [:])
    }
}

final class StubClipboardHistorySource: ClipboardHistorySourceProtocol {
    let texts: [String]
    init(texts: [String]) { self.texts = texts }
    func read(count: Int) async throws -> [TextFragment] {
        texts.prefix(count).enumerated().map { (i, t) in
            TextFragment(source: .clipboardItem, text: t, meta: ["index": String(i)])
        }
    }
}
