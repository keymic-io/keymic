import Foundation

/// Tri-state classification of the focused element's editability. Defined here
/// (not in SelectionTextProvider) so a standalone `swiftc` test runner can
/// exercise `VoiceScratchpadDecision` without pulling in AppKit / AX plumbing.
enum FocusEditability {
    case editable
    case nonEditable
    case unknown
}

/// Pure, side-effect-free decision for the voice-dictation scratchpad fallback.
/// Kept separate from the live AX probe so it is unit-testable in isolation
/// (mirrors `ClipboardHistoryKeyHandling`).
enum VoiceScratchpadDecision {
    /// Divert dictation to the scratchpad ONLY on a high-confidence non-editable
    /// target. `.editable` and `.unknown` both paste as before — `.unknown` is the
    /// safety bucket for AX-unsupported-but-editable apps (Electron/VSCode/Slack).
    static func shouldOpen(for editability: FocusEditability) -> Bool {
        editability == .nonEditable
    }
}
