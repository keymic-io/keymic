import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Raw context inputs gathered around a persona invocation.
/// Owned by the LLM layer because two consumers read it: LLMRefiner prompt building
/// and OutputRouter `.openURL` template substitution.
struct PersonaContext: Equatable {
    let selection: String?
    let clipboardTop: String?

    static let empty = PersonaContext(selection: nil, clipboardTop: nil)

    /// Builds the LLM user-prompt string, injecting selection + clipboard as sections
    /// when contextMode is `.selectionAndClipboard`. Returns just the transcript otherwise.
    /// Caps result at 7500 UTF-16 units, snapped to character boundary.
    func buildPrompt(transcript: String, contextMode: ContextMode) -> String {
        guard contextMode == .selectionAndClipboard else { return transcript }

        let sel = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clip = clipboardTop?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var sections: [String] = []
        var includeTranscript = true

        if !sel.isEmpty {
            sections.append("[Selected text]\n\(sel)")
            if transcript == sel || sel.utf16.count > 2000 {
                includeTranscript = false
            }
        }
        if !clip.isEmpty && clip != sel {
            sections.append("[Recent clipboard]\n\(clip)")
        }
        if includeTranscript {
            sections.append("[User said]\n\(transcript)")
        }

        let result = sections.joined(separator: "\n\n")
        if result.utf16.count > 7500 {
            var capped = ""
            for ch in result {
                if capped.utf16.count + ch.utf16.count > 7500 { break }
                capped.append(ch)
            }
            return capped
        }
        return result
    }

    #if canImport(AppKit)
    /// Snapshots the current environment using existing providers. Side-effecting
    /// (reads pasteboard, runs accessibility queries).
    static func snapshotCurrent() -> PersonaContext {
        let sel = SelectionTextProvider.currentSelection()
        let clip = NSPasteboard.general.string(forType: .string)
        return PersonaContext(selection: sel, clipboardTop: clip)
    }
    #endif
}
