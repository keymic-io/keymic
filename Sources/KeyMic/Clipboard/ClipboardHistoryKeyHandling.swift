import Foundation

enum ClipboardHistoryKeyHandling {
    /// Up/Down always drive list navigation (Alfred-style): even while typing a
    /// query, ↑/↓ move the highlighted result instead of the text caret. Left/Right
    /// are not intercepted, so they still edit the query.
    static func shouldHandleArrowKey(isSearchFocused: Bool, query: String) -> Bool {
        true
    }

    static func shouldHandleReturn(isSearchFocused: Bool, hasPasteTarget: Bool) -> Bool {
        hasPasteTarget || !isSearchFocused
    }

    /// Space toggles multi-selection unless the user is actively typing a query.
    /// Mirrors `shouldHandleArrowKey`: while the search field is focused but
    /// still empty, space drives selection; once the query has text, space is a
    /// literal character so the field can contain multi-word searches.
    static func shouldHandleSpace(isSearchFocused: Bool, query: String) -> Bool {
        guard isSearchFocused else { return true }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
