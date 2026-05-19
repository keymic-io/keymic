import Foundation

@main
struct SelectionSourceTestRunner {
    static func main() {
        // Provided kind sanity.
        let src = SelectionSource()
        expect(src.providedKind == .selectedText, "providedKind == .selectedText")

        // SelectionWriteError shape.
        let err = SelectionWriteError.notSettable
        expect("\(err)" == "notSettable", "SelectionWriteError.notSettable description")

        // AX-touching paths (currentSelection / replaceSelection) require a focused
        // editable element in another app and AX trust; they're exercised manually
        // and via the running app, not in headless CI.

        print("SelectionSourceTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
