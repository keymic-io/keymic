import AppKit
import Carbon

final class TextInjector {
    /// Optional hook called with the exact pasteboard changeCount of each write KeyMic
    /// performs (transcript + restore), so ClipboardMonitor can exclude precisely those
    /// changeCounts from history — not whatever changeCount happens to be current when
    /// the hook runs.
    var onMarkIgnored: ((Int) -> Void)?

    /// Optional hook called synchronously right before KeyMic overwrites the pasteboard
    /// with the transcript. Lets ClipboardMonitor drain a user copy made since its last
    /// 0.5 s tick into history *before* our own write advances the monitor's changeCount
    /// past it (that copy's changeCount is marked ignored, so it would otherwise be lost
    /// forever). Mirrors the capture-before-write that ClipboardController performs on its
    /// own paste paths.
    var onCapturePending: (() -> Void)?

    /// Deferred-restore state of the most recent injection. Kept as a single controlled
    /// instance so overlapping `inject` calls (<0.5 s apart) can settle the previous
    /// one instead of trampling its saved clipboard / input source.
    private struct InFlight {
        let savedItems: [NSPasteboardItem]?
        let writeChangeCount: Int
        /// Non-nil when the user's input source must be restored (we switched to ASCII,
        /// or a previous overlapping injection did and hasn't restored yet).
        let originalSource: TISInputSource?
        let sourceRestoreWork: DispatchWorkItem
        let clipboardRestoreWork: DispatchWorkItem
    }

    private var inFlight: InFlight?

    func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general

        // Serialize with any in-flight injection: cancel its pending restore timers and
        // carry over its saved state, so the snapshot below never captures our own
        // transcript (or the temporary ASCII input source) as "the user's" state.
        var savedItems: [NSPasteboardItem]? = nil
        var carriedSnapshot = false
        var carriedSource: TISInputSource? = nil
        if let previous = inFlight {
            previous.sourceRestoreWork.cancel()
            previous.clipboardRestoreWork.cancel()
            carriedSource = previous.originalSource
            if pasteboard.changeCount == previous.writeChangeCount {
                // Pasteboard still holds the previous transcript — the user's real
                // clipboard is the previous injection's snapshot.
                savedItems = previous.savedItems
                carriedSnapshot = true
            }
            inFlight = nil
        }

        // Save current clipboard content (unless carried over from the previous injection)
        if !carriedSnapshot {
            savedItems = pasteboard.pasteboardItems?.map { item in
                let newItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        newItem.setData(data, forType: type)
                    }
                }
                return newItem
            }
        }

        // Drain any pending user copy into history before we overwrite the pasteboard.
        // Safe to call unconditionally: if the pasteboard currently holds our own
        // previous transcript (carried-over injection), the monitor's ignore/last-seen
        // guards skip it; only a genuine user copy gets recorded.
        onCapturePending?()

        // Write transcription to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writeChangeCount = pasteboard.changeCount
        onMarkIgnored?(writeChangeCount)

        // If a non-ASCII input source (e.g. Chinese IME) is active, temporarily
        // switch to an ASCII-capable one so the Cmd+V paste is not intercepted.
        let currentSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needSwitch = !isASCIICapable(currentSource)
        // If a previous overlapping injection already switched away, *its* original
        // (the user's real IME) is the source to restore — not the current one.
        let originalSource: TISInputSource? = carriedSource ?? (needSwitch ? currentSource : nil)

        if needSwitch {
            if let asciiSource = findASCIICapableSource() {
                TISSelectInputSource(asciiSource)
                usleep(50_000) // 50ms for system to settle
            }
        }

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 0x09

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        // Restore input source after paste
        let sourceRestoreWork = DispatchWorkItem {
            if let originalSource {
                TISSelectInputSource(originalSource)
            }
        }

        // Restore original clipboard content — but only if the user hasn't copied
        // anything new in the meantime; otherwise we'd silently destroy their copy.
        let capturedSavedItems = savedItems
        let clipboardRestoreWork = DispatchWorkItem { [weak self] in
            defer { self?.inFlight = nil }
            guard pasteboard.changeCount == writeChangeCount else { return }
            pasteboard.clearContents()
            if let saved = capturedSavedItems {
                pasteboard.writeObjects(saved)
            }
            // Mark unconditionally — non-text restores (images, files) and the bare
            // clearContents() above also bump changeCount and must not be re-captured
            // by ClipboardMonitor as a fresh user copy.
            self?.onMarkIgnored?(pasteboard.changeCount)
        }

        inFlight = InFlight(
            savedItems: savedItems,
            writeChangeCount: writeChangeCount,
            originalSource: originalSource,
            sourceRestoreWork: sourceRestoreWork,
            clipboardRestoreWork: clipboardRestoreWork
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: sourceRestoreWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: clipboardRestoreWork)
    }

    // MARK: - Input Source Helpers

    private func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return false
        }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private func findASCIICapableSource() -> TISInputSource? {
        let criteria = [kTISPropertyInputSourceIsASCIICapable: true, kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let sourceList = TISCreateInputSourceList(criteria, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        // Prefer ABC or US keyboard
        for source in sourceList {
            if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                if id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" {
                    return source
                }
            }
        }
        return sourceList.first
    }
}
