import Foundation

/// One selectable slot in the voice picker row.
enum PickerEntry: Equatable {
    /// Raw injection — no persona / no LLM (today's `activePersona == nil` path).
    case defaultInput
    case persona(Persona)
}

/// Pure logic for the voice picker row: entry construction, Tab cycling, and
/// which preview windows a highlighted entry should show.
enum VoicePickerModel {
    /// `[defaultInput]` fixed leftmost, then personas MRU-descending.
    static func buildEntries(personas: [Persona], history: [String]) -> [PickerEntry] {
        [.defaultInput] + PersonaMRU.order(personas: personas, history: history).map { .persona($0) }
    }

    /// Wrapping index step. `count` is the total entry count.
    static func cycle(index: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        let delta = forward ? 1 : -1
        return ((index + delta) % count + count) % count
    }

    /// Which context preview windows to show for the highlighted entry.
    static func previewVisibility(for entry: PickerEntry) -> (selection: Bool, clipboard: Bool) {
        switch entry {
        case .defaultInput:
            return (false, false)
        case .persona(let p):
            return (p.contextSources.contains(.selection), p.contextSources.contains(.clipboardTop))
        }
    }
}
