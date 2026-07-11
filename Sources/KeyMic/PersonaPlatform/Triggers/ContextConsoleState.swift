import Foundation
import Observation

/// A single toggleable context candidate shown in the context console.
struct ContextCandidate: Identifiable, Equatable {
    enum Kind: Equatable { case selection, clipboardTop, clipboardHistory }
    let id: String
    let kind: Kind
    let text: String
    var isChecked: Bool
}

/// Backing state for the post-release context console: the editable transcript
/// plus the toggleable context candidates. Assembles a `ContextOverride` from
/// whatever the user leaves checked.
@Observable
@MainActor
final class ContextConsoleState {
    var transcript: String
    var candidates: [ContextCandidate]
    var isRunning: Bool = false

    init(transcript: String, candidates: [ContextCandidate]) {
        self.transcript = transcript
        self.candidates = candidates
    }

    func assembleOverride() -> ContextOverride {
        Self.assemble(candidates: candidates)
    }

    /// Pure: builds a `PersonaContext` + effective `Set<ContextSource>` from the
    /// checked candidates. `nonisolated` so the synchronous (non-MainActor) test
    /// runner can call it directly without an actor-isolation error.
    nonisolated static func assemble(candidates: [ContextCandidate]) -> ContextOverride {
        let checked = candidates.filter(\.isChecked)
        let selection = checked.first { $0.kind == .selection }?.text
        let clipboardTop = checked.first { $0.kind == .clipboardTop }?.text
        let history = checked.filter { $0.kind == .clipboardHistory }.map(\.text)

        var sources: Set<ContextSource> = []
        if selection != nil { sources.insert(.selection) }
        if clipboardTop != nil { sources.insert(.clipboardTop) }
        if !history.isEmpty { sources.insert(.clipboardHistory) }

        let context = PersonaContext(
            selection: selection,
            clipboardTop: clipboardTop,
            clipboardHistory: history.isEmpty ? nil : history,
            windowOCR: nil
        )
        return ContextOverride(context: context, sources: sources)
    }
}
