import Foundation

enum ClipboardHistoryKeyHandling {
    static func shouldHandleArrowKey(isSearchFocused: Bool, query: String) -> Bool {
        guard isSearchFocused else { return true }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldHandleReturn(isSearchFocused: Bool, hasPasteTarget: Bool) -> Bool {
        hasPasteTarget || !isSearchFocused
    }

    static func shouldHandleSpace(isSearchFocused: Bool) -> Bool {
        !isSearchFocused
    }
}
