import Foundation

protocol ContextSource {
    var providedKind: TextSource { get }
    func read() async throws -> TextFragment?
}

protocol ClipboardHistorySourceProtocol {
    func read(count: Int) async throws -> [TextFragment]
}

final class ContextResolver {
    private let selection: ContextSource
    private let clipboard: ContextSource
    private let clipboardHistory: ClipboardHistorySourceProtocol
    private let windowOCR: ContextSource

    init(selection: ContextSource,
         clipboard: ContextSource,
         clipboardHistory: ClipboardHistorySourceProtocol,
         windowOCR: ContextSource) {
        self.selection = selection
        self.clipboard = clipboard
        self.clipboardHistory = clipboardHistory
        self.windowOCR = windowOCR
    }

    /// Fills gaps based on persona.contextMode. Existing fragments of the same
    /// source are kept (trigger wins over resolver).
    func resolve(persona: Persona, prefilled: [TextFragment]) async -> [TextFragment] {
        var out = prefilled
        let have: (TextSource) -> Bool = { kind in out.contains { $0.source == kind } }

        func addIfMissing(_ kind: TextSource, via src: ContextSource) async {
            guard !have(kind) else { return }
            if let frag = try? await src.read() { out.append(frag) }
        }

        switch persona.contextMode {
        case .none:
            break
        case .selection:
            await addIfMissing(.selectedText, via: selection)
        case .clipboard:
            await addIfMissing(.clipboardItem, via: clipboard)
        case .clipboardHistory:
            // History always resolved (even if prefilled has clipboard, history is
            // a distinct user request for N items).
            if let frags = try? await clipboardHistory.read(count: max(0, persona.contextCount)) {
                out.append(contentsOf: frags)
            }
        case .selectionAndClipboard:
            await addIfMissing(.selectedText, via: selection)
            await addIfMissing(.clipboardItem, via: clipboard)
        case .windowOCR:
            await addIfMissing(.ocrWindow, via: windowOCR)
        }
        return out
    }
}
