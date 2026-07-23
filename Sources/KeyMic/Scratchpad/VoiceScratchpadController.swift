import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "VoiceScratchpad")

/// Owns the single reusable scratchpad window. `present(text:)` fills the field,
/// activates KeyMic (an LSUIElement app that normally never takes focus), and makes
/// the window key so the text field is first responder.
///
/// Copy & Close writes `NSPasteboard.general` (so the user can paste immediately)
/// and records the text directly in `ClipboardStore` (R5), rather than relying on
/// `ClipboardMonitor` to pick the write up — whether the monitor sees it depends on
/// its 0.5 s poll firing before/after the window closes and on which app is
/// frontmost at that moment, so a direct write is the deterministic path. Discard /
/// Esc closes without writing the clipboard (R6). Nothing is auto-copied on open.
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

        let window: VoiceScratchpadWindow
        if let existing = self.window {
            existing.contentViewController = host
            window = existing
        } else {
            window = VoiceScratchpadWindow(contentViewController: host)
            self.window = window
        }

        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func copyAndClose(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Record directly rather than depending on ClipboardMonitor's poll (its
        // timing/frontmost-app attribution is non-deterministic here); identical-
        // newest dedup in ClipboardStore collapses any later monitor re-capture.
        clipboardStore.add(text: text, sourceBundleID: nil, sourceAppName: nil)
        logger.debug("scratchpad copy & close (length=\(text.count, privacy: .public))")
        window?.orderOut(nil)
    }

    private func discard() {
        window?.orderOut(nil)
    }
}
