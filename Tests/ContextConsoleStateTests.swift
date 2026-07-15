import Foundation

@main
struct ContextConsoleStateTestRunner {
    static func main() {
        testOnlyCheckedCandidatesIncluded()
        testHistoryCandidatesBecomeArray()
        testUncheckedProducesEmptySources()
        print("ContextConsoleStateTests passed")
    }

    static func testOnlyCheckedCandidatesIncluded() {
        let cands = [
            ContextCandidate(id: "sel", kind: .selection, text: "S", isChecked: true),
            ContextCandidate(id: "clip", kind: .clipboardTop, text: "C", isChecked: false),
        ]
        let o = ContextConsoleState.assemble(candidates: cands)
        expect(o.context.selection == "S", "checked selection included")
        expect(o.context.clipboardTop == nil, "unchecked clipboard excluded")
        expect(o.sources == [.selection], "sources only reflect checked; got \(o.sources)")
    }

    static func testHistoryCandidatesBecomeArray() {
        let cands = [
            ContextCandidate(id: "h1", kind: .clipboardHistory, text: "a", isChecked: true),
            ContextCandidate(id: "h2", kind: .clipboardHistory, text: "b", isChecked: true),
        ]
        let o = ContextConsoleState.assemble(candidates: cands)
        expect(o.context.clipboardHistory == ["a", "b"], "history preserved in order; got \(String(describing: o.context.clipboardHistory))")
        expect(o.sources == [.clipboardHistory], "history source set")
    }

    static func testUncheckedProducesEmptySources() {
        let cands = [ContextCandidate(id: "sel", kind: .selection, text: "S", isChecked: false)]
        let o = ContextConsoleState.assemble(candidates: cands)
        expect(o.sources.isEmpty, "nothing checked → empty sources")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
