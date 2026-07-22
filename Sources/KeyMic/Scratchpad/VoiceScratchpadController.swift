import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "VoiceScratchpad")

/// Owns the single reusable scratchpad window. `present(text:)` fills the field,
/// activates KeyMic (an LSUIElement app that normally never takes focus), and makes
/// the window key so the text field is first responder.
///
/// Copy & Close writes `NSPasteboard.general` (so the user can paste immediately)
/// and records the text directly in `ClipboardStore` (R5). The direct store write
/// is required because the copy happens while KeyMic is frontmost, and
/// `ClipboardMonitor` skips pasteboard writes whose source app is its own bundle —
/// so the write would never reach history via the monitor. Discard / Esc closes
/// without writing the clipboard (R6). Nothing is auto-copied on open.
@MainActor
final class VoiceScratchpadController {
    private let clipboardStore: ClipboardStore
    private var window: VoiceScratchpadWindow?

    init(clipboardStore: ClipboardStore) {
        self.clipboardStore = clipboardStore
    }

    func present(text: String) {
        // Rebuild the hosting view each time so the TextEditor is re-seeded with the
        // new transcript; reuse the same window instance.
        let host = NSHostingController(
            rootView: VoiceScratchpadView(
                text: text,
                onCopyClose: { [weak self] edited in self?.copyAndClose(edited) },
                onDiscard: { [weak self] in self?.discard() }
            )
        )

        let window = window ?? VoiceScratchpadWindow(contentViewController: host)
        window.contentViewController = host
        self.window = window

        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func copyAndClose(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Record directly: the ClipboardMonitor would skip this write (KeyMic is
        // frontmost, so the write's source is our own bundle).
        clipboardStore.add(text: text, sourceBundleID: nil, sourceAppName: nil)
        logger.debug("scratchpad copy & close (length=\(text.count, privacy: .public))")
        window?.orderOut(nil)
    }

    private func discard() {
        window?.orderOut(nil)
    }
}
