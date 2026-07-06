import CoreGraphics

/// Cmd+Tab-style state machine for the clipboard panel hotkey.
///
/// Holding the hotkey's modifier(s) and tapping the key repeatedly cycles the
/// highlight; releasing the modifier commits (pastes) the highlighted item —
/// but only when the highlight actually moved (>=2 taps). A single open-tap
/// followed by a modifier release leaves the panel open in browse mode, where
/// further taps just move the highlight and paste is manual (Return).
///
/// Pure logic, no KeyMonitor dependency, so it can be exercised by the
/// standalone swiftc test runner — same approach as `ClipboardHistoryKeyHandling`.
struct ClipboardSwitcherState {
    /// True while a "opened-then-held" session is in progress. Set only on open
    /// (session not already active); never re-armed while a session is active,
    /// so a release mid-browse never pastes.
    private(set) var active = false
    private var requiredModifiers: CGEventFlags = []
    private var tapCount = 0

    enum TapAction { case open, moveNext }
    enum ReleaseAction { case commitPaste, none }

    /// Call on each discrete hotkey keyDown (auto-repeat already filtered out).
    mutating func onHotkeyTap(hotkeyModifiers: CGEventFlags) -> TapAction {
        if !active {
            active = true
            requiredModifiers = hotkeyModifiers
            tapCount = 1
            return .open
        }
        tapCount += 1
        return .moveNext
    }

    /// Call on every `flagsChanged`. Returns `.commitPaste` on the modifier
    /// release edge of an armed session that moved the highlight.
    mutating func onFlagsChanged(currentFlags: CGEventFlags, panelVisible: Bool) -> ReleaseAction {
        guard active, !requiredModifiers.isEmpty else { return .none }
        guard !currentFlags.contains(requiredModifiers) else { return .none }
        // Release edge: at least one required modifier lifted.
        let shouldPaste = tapCount >= 2 && panelVisible
        active = false
        requiredModifiers = []
        tapCount = 0
        return shouldPaste ? .commitPaste : .none
    }

    mutating func reset() {
        active = false
        requiredModifiers = []
        tapCount = 0
    }
}
