import AppKit
import Foundation

final class ClipboardSource: ContextSource {
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    var providedKind: TextSource { .clipboardItem }

    func read() async throws -> TextFragment? {
        if let text = await mostRecentPlainText(), !text.isEmpty {
            return TextFragment(source: .clipboardItem, text: text, meta: ["index": "0"])
        }
        // Fallback to live pasteboard (covers items copied before app start).
        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            return TextFragment(source: .clipboardItem, text: s, meta: ["index": "0"])
        }
        return nil
    }

    @MainActor
    private func mostRecentPlainText() -> String? {
        store.fetchAll()
            .first { $0.kind == .plain }?
            .text
    }
}
