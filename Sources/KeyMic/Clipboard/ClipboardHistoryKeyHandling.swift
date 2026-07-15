import Foundation

enum ClipboardHistoryKeyHandling {
    static func shouldHandleArrowKey(isSearchFocused: Bool, query: String) -> Bool {
        guard isSearchFocused else { return true }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
