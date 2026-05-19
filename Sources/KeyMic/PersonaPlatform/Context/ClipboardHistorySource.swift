import Foundation

final class ClipboardHistorySource {
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    /// Returns up to `count` most-recent `.plain` clipboard items, newest first,
    /// each tagged with meta["index"] = "<i>" (0 = newest).
    func read(count: Int) async throws -> [TextFragment] {
        guard count > 0 else { return [] }
        let texts = await fetchRecentPlainTexts(count: count)
        return texts.enumerated().map { (i, text) in
            TextFragment(source: .clipboardItem, text: text, meta: ["index": String(i)])
        }
    }

    @MainActor
    private func fetchRecentPlainTexts(count: Int) -> [String] {
        store.fetchAll()
            .lazy
            .filter { $0.kind == .plain }
            .prefix(count)
            .map(\.text)
            .filter { !$0.isEmpty }
    }
}
