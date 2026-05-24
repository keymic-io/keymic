import AppKit
import ApplicationServices
import Foundation

/// Reads the focused element's selected text. Tries the Accessibility API first
/// (`kAXSelectedTextAttribute`); when the focused element does not implement
/// that attribute (Electron / Chrome / VSCode / iTerm / Preview PDF / Figma …),
/// falls back to a Cmd+C round-trip that copies the selection, reads it from
/// `NSPasteboard.general`, then restores the original clipboard.
///
/// `onMarkIgnored` is invoked for every pasteboard write the fallback performs
/// (the Cmd+C result and the restore) so ClipboardMonitor can drop them from
/// history. `enableFallback` lets users disable the Cmd+C path via the
/// `enableSelectionCopyFallback` UserDefaults key (default ON).
enum SelectionTextProvider {
    static var onMarkIgnored: ((String) -> Void)?

    static var enableFallback: () -> Bool = {
        UserDefaults.standard.object(forKey: "enableSelectionCopyFallback") as? Bool ?? true
    }

    static func currentSelection() -> String? {
        switch axSelection() {
        case .text(let s):
            return s
        case .emptyButSupported:
            return nil
        case .unsupported:
            guard enableFallback() else { return nil }
            return copyFallbackSelection()
        }
    }

    // MARK: - AX path

    private enum AXResult {
        case text(String)
        case emptyButSupported
        case unsupported
    }

    private static func axSelection() -> AXResult {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .success,
            let any = focused,
            CFGetTypeID(any) == AXUIElementGetTypeID()
        else { return .unsupported }

        // Safe: guarded by CFGetTypeID check above. AXUIElement is a CF type,
        // Swift's `as?` bridge does not accept it, so a checked force-cast is required.
        let element = any as! AXUIElement

        var selected: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selected
        )
        guard status == .success else { return .unsupported }
        if let s = selected as? String {
            return s.isEmpty ? .emptyButSupported : .text(s)
        }
        return .unsupported
    }

    // MARK: - Cmd+C fallback

    private static func copyFallbackSelection() -> String? {
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let snapshot = PasteboardSnapshot.capture(pasteboard)

        postCmdC()

        let deadline = Date().addingTimeInterval(0.25)
        let changed = SelectionCopyWait.waitForChange(
            initial: originalChangeCount,
            get: { pasteboard.changeCount },
            deadline: deadline,
            tick: {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        )
        guard changed else { return nil }

        let copied = pasteboard.string(forType: .string)
        if let copied, !copied.isEmpty {
            onMarkIgnored?(copied)
        }

        PasteboardSnapshot.restore(snapshot, to: pasteboard)
        if let token = snapshot.ignoredToken, !token.isEmpty {
            onMarkIgnored?(token)
        }

        guard let copied,
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return copied
    }

    private static func postCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKeyCode: CGKeyCode = 0x08
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
