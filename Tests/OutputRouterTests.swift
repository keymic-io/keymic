import Foundation

@main
struct OutputRouterTestRunner {
    static func main() {
        Task {
            await runAll()
            print("OutputRouterTests passed")
            exit(0)
        }
        RunLoop.main.run()
    }

    static func runAll() async {
        // .replaceFocusedText dispatches via the focused-text handler.
        let injected: ArrayRef<String> = ArrayRef()
        let focused = FocusedTextStrategy(
            inject: { injected.values.append($0) },
            reactivate: { _ in }
        )
        let clipWrites: ArrayRef<String> = ArrayRef()
        let urlOpens: ArrayRef<URL> = ArrayRef()

        let router = OutputRouter(
            focusedText: focused,
            replaceSelection: ReplaceSelectionStrategy(
                fallback: focused,
                writeSelection: { _ in throw SelectionWriteError.notSettable }
            ),
            clipboard: ClipboardStrategy(write: { @MainActor text in clipWrites.values.append(text) }),
            openURLFactory: { template in
                OpenURLStrategy(template: template, opener: { urlOpens.values.append($0) })
            }
        )

        try! await router.dispatch(.replaceFocusedText, text: "hello", origin: nil)
        expect(injected.values == ["hello"], ".replaceFocusedText → injects")

        // .replaceSelection with notSettable error falls back to focused-text.
        injected.values.removeAll()
        try! await router.dispatch(.replaceSelection, text: "bye", origin: nil)
        expect(injected.values == ["bye"], ".replaceSelection → fallback to focused-text on notSettable")

        // .clipboard writes via clipboard handler only (no inject).
        injected.values.removeAll()
        try! await router.dispatch(.clipboard, text: "clip", origin: nil)
        expect(clipWrites.values == ["clip"], ".clipboard → writes pasteboard")
        expect(injected.values.isEmpty, ".clipboard → does NOT inject")

        // .openURL percent-encodes {query} and opens.
        try! await router.dispatch(
            .openURL(template: "https://duck.test/?q={query}"),
            text: "hello world & co",
            origin: nil
        )
        expect(urlOpens.values.count == 1, ".openURL → opens URL")
        let opened = urlOpens.values[0].absoluteString
        expect(opened.contains("hello%20world"),
            ".openURL percent-encodes spaces: \(opened)")
        expect(opened.contains("%26"),
            ".openURL percent-encodes ampersand: \(opened)")

        // .openURL with no {query} throws missingPlaceholder.
        do {
            try await router.dispatch(
                .openURL(template: "https://no-placeholder.test/"),
                text: "x",
                origin: nil
            )
            expect(false, ".openURL without {query} should throw")
        } catch OpenURLError.missingPlaceholder {
            // expected
        } catch {
            expect(false, ".openURL missingPlaceholder expected, got \(error)")
        }

        // .runShell and .iTermPane throw notSupportedYet (P3 deferred).
        do {
            try await router.dispatch(.runShell(command: "echo", confirm: true),
                                      text: "x", origin: nil)
            expect(false, ".runShell should throw notSupportedYet")
        } catch OutputError.notSupportedYet { /* ok */ } catch { expect(false, "wrong err") }

        do {
            try await router.dispatch(.iTermPane(confirm: true), text: "x", origin: nil)
            expect(false, ".iTermPane should throw notSupportedYet")
        } catch OutputError.notSupportedYet { /* ok */ } catch { expect(false, "wrong err") }
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}

final class ArrayRef<T>: @unchecked Sendable { var values: [T] = [] }
