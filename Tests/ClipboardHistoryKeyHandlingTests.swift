import Foundation

@main
struct ClipboardHistoryKeyHandlingTestRunner {
    static func main() {
        expect(ClipboardHistoryKeyHandling.shouldHandleArrowKey(isSearchFocused: false, query: ""),
               "arrow should navigate list when search is not focused")
        expect(ClipboardHistoryKeyHandling.shouldHandleArrowKey(isSearchFocused: true, query: ""),
               "arrow should leave empty search and enter list navigation")
        expect(ClipboardHistoryKeyHandling.shouldHandleArrowKey(isSearchFocused: true, query: "   "),
               "arrow should leave whitespace-only search and enter list navigation")
        expect(!ClipboardHistoryKeyHandling.shouldHandleArrowKey(isSearchFocused: true, query: "abc"),
               "arrow should stay in populated search field")

        expect(ClipboardHistoryKeyHandling.shouldHandleReturn(isSearchFocused: true, hasPasteTarget: true),
               "return should paste when search is focused but an item is highlighted/selected (paste on open)")
        expect(!ClipboardHistoryKeyHandling.shouldHandleReturn(isSearchFocused: true, hasPasteTarget: false),
               "return should defer to search editing when there is no paste target")
        expect(ClipboardHistoryKeyHandling.shouldHandleReturn(isSearchFocused: false, hasPasteTarget: true),
               "return should paste when search is not focused and an item is highlighted")
        expect(ClipboardHistoryKeyHandling.shouldHandleReturn(isSearchFocused: false, hasPasteTarget: false),
               "return is handled outside the search field even without an explicit target")

        expect(ClipboardHistoryKeyHandling.shouldHandleSpace(isSearchFocused: false, query: ""),
               "space should toggle selection when search is not focused")
        expect(ClipboardHistoryKeyHandling.shouldHandleSpace(isSearchFocused: false, query: "abc"),
               "space toggles selection outside the search field regardless of query")
        expect(ClipboardHistoryKeyHandling.shouldHandleSpace(isSearchFocused: true, query: ""),
               "space toggles selection while the focused search field is still empty")
        expect(ClipboardHistoryKeyHandling.shouldHandleSpace(isSearchFocused: true, query: "   "),
               "whitespace-only query still counts as empty, so space toggles selection")
        expect(!ClipboardHistoryKeyHandling.shouldHandleSpace(isSearchFocused: true, query: "abc"),
               "once the query has text, space is typed into the search field")

        print("ClipboardHistoryKeyHandlingTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
