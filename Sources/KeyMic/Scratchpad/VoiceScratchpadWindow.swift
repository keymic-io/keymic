import AppKit

/// Titled, resizable, KEY/activating window hosting the scratchpad. Unlike the
/// non-activating capsule/overlay, this must become key so the user can type into
/// the text field (`canBecomeKey == true`).
final class VoiceScratchpadWindow: NSPanel {
    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = String(localized: "Dictation Scratchpad")
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: 380, height: 220)
        self.contentViewController = contentViewController
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
