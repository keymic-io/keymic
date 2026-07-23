import AppKit

/// Titled, resizable, KEY/activating window hosting the scratchpad. Unlike the
/// non-activating capsule/overlay, this must become key so the user can type into
/// the text field (`canBecomeKey == true`).
final class VoiceScratchpadWindow: NSPanel {
    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = String(localized: "Dictation Scratchpad")
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: 460, height: 320)
        self.contentViewController = contentViewController
        centerOnActiveScreen()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Centers on the screen under the mouse cursor (falls back to the main
    /// screen), using the visible frame so the title bar clears the menu bar.
    /// `NSWindow.center()` only ever targets the main screen and sits slightly
    /// high — this keeps the panel centered on whichever display the user is on.
    func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { center(); return }
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }
}
