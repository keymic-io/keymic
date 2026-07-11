import Foundation

@main
struct VoicePickerModelTestRunner {
    static func main() {
        testDefaultInputIsAlwaysLeftmost()
        testPersonasFollowMRUOrder()
        testCycleForwardWraps()
        testCycleBackwardWraps()
        testVisibilityDefaultInputHasNoWindows()
        testVisibilityFollowsContextSources()
        print("VoicePickerModelTests passed")
    }

    static func testDefaultInputIsAlwaysLeftmost() {
        let entries = VoicePickerModel.buildEntries(personas: [p("a")], history: [])
        expect(entries.first == .defaultInput, "default input must be leftmost")
    }

    static func testPersonasFollowMRUOrder() {
        let entries = VoicePickerModel.buildEntries(personas: [p("a"), p("b")], history: ["b"])
        expect(entries == [.defaultInput, .persona(p("b")), .persona(p("a"))],
               "personas follow MRU after default input")
    }

    static func testCycleForwardWraps() {
        expect(VoicePickerModel.cycle(index: 2, count: 3, forward: true) == 0, "forward from last wraps to 0")
        expect(VoicePickerModel.cycle(index: 0, count: 3, forward: true) == 1, "forward advances")
    }

    static func testCycleBackwardWraps() {
        expect(VoicePickerModel.cycle(index: 0, count: 3, forward: false) == 2, "backward from 0 wraps to last")
        expect(VoicePickerModel.cycle(index: 2, count: 3, forward: false) == 1, "backward retreats")
    }

    static func testVisibilityDefaultInputHasNoWindows() {
        let v = VoicePickerModel.previewVisibility(for: .defaultInput)
        expect(!v.selection && !v.clipboard, "default input shows no preview windows")
    }

    static func testVisibilityFollowsContextSources() {
        let v = VoicePickerModel.previewVisibility(for: .persona(p("x", sources: [.selection])))
        expect(v.selection && !v.clipboard, "selection-only persona shows selection window only")
        let v2 = VoicePickerModel.previewVisibility(for: .persona(p("y", sources: [.selection, .clipboardTop])))
        expect(v2.selection && v2.clipboard, "both sources show both windows")
    }

    static func p(_ id: String, sources: Set<ContextSource> = []) -> Persona {
        let fixedDate = Date(timeIntervalSince1970: 0)
        return Persona(id: id, name: id, icon: "x", stylePrompt: "", temperature: 0, hotkey: nil,
                contextSources: sources, builtIn: false, createdAt: fixedDate, updatedAt: fixedDate)
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
