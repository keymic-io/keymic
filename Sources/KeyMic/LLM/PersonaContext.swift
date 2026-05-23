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
    let clipboardHistory: [String]?
    let windowOCR: String?

    static let empty = PersonaContext(selection: nil, clipboardTop: nil, clipboardHistory: nil, windowOCR: nil)

    /// Legacy P1 entry point. Kept for backward compatibility during the LOR-18 migration.
    /// Removed in a later cleanup task once all callers move to `buildPrompt(transcript:sources:)`.
    /// Difference vs the new overload: when contextMode is `.selectionAndClipboard` we still
    /// wrap the transcript in `[User said]\n…` even if no context sections are emitted.
    func buildPrompt(transcript: String, contextMode: ContextMode) -> String {
        guard contextMode == .selectionAndClipboard else { return transcript }
        return buildPrompt(transcript: transcript, sources: [.selection, .clipboardTop], wrapTranscriptWhenNoSections: true)
    }

    /// Builds the labelled user prompt for an LLM call.
    /// Sections are emitted in canonical order when present:
    ///   [Selected text] → [Recent clipboard] → [Clipboard history] → [Window text] → [User said]
    /// Empty / nil providers produce no section even when their source is in `sources`.
    /// Result capped at 7500 UTF-16 units, snapped to character boundary.
    func buildPrompt(transcript: String, sources: Set<ContextSource>) -> String {
        return buildPrompt(transcript: transcript, sources: sources, wrapTranscriptWhenNoSections: false)
    }

    private func buildPrompt(transcript: String, sources: Set<ContextSource>, wrapTranscriptWhenNoSections: Bool) -> String {
        let sel = sources.contains(.selection)
            ? (selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""
        let clip = sources.contains(.clipboardTop)
            ? (clipboardTop?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""
        let history: [String] = sources.contains(.clipboardHistory)
            ? (clipboardHistory?.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
              } ?? [])
            : []
        let ocr = sources.contains(.windowOCR)
            ? (windowOCR?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""

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
        if !history.isEmpty {
            let numbered = history.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            sections.append("[Clipboard history]\n\(numbered)")
        }
        if !ocr.isEmpty {
            sections.append("[Window text]\n\(ocr)")
        }

        // New API: when there are no context sections, emit just the transcript verbatim
        // (no `[User said]` wrapper). Legacy API opts back into wrapping via the private flag
        // to preserve the prior P1 contract that downstream callers rely on.
        if sections.isEmpty && !wrapTranscriptWhenNoSections {
            return transcript
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
    /// Snapshots the current environment using existing providers.
    /// Captures selection + clipboard top only. `clipboardHistory` and `windowOCR`
    /// are caller-provided when needed.
    static func snapshotCurrent() -> PersonaContext {
        let sel = SelectionTextProvider.currentSelection()
        let clip = NSPasteboard.general.string(forType: .string)
        return PersonaContext(selection: sel, clipboardTop: clip, clipboardHistory: nil, windowOCR: nil)
    }
    #endif
}
