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

        expect(ClipboardHistoryKeyHandling.shouldHandleReturn(isSearchFocused: false),
               "return should paste when search is not focused")
        expect(!ClipboardHistoryKeyHandling.shouldHandleReturn(isSearchFocused: true),
               "return should not conflict with search editing")

        expect(ClipboardHistoryKeyHandling.shouldHandleSpace(isSearchFocused: false),
               "space should toggle selection when search is not focused")
        expect(!ClipboardHistoryKeyHandling.shouldHandleSpace(isSearchFocused: true),
               "space should type into search instead of toggling selection")

        print("ClipboardHistoryKeyHandlingTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
