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

    /// AX-only selection read (no Cmd+C fallback). Used by the voice picker
    /// preview while the trigger modifier is held, where a synthetic Cmd+C is
    /// unreliable. Returns nil when the focused element has no AX selection.
    static func axOnlySelection() -> String? {
        if case .text(let s) = axSelection() { return s }
        return nil
    }

    /// AX-only read of the FULL text value of the focused field (`kAXValue`).
    /// Used by the voice picker preview to show "what's in the input field". Nil
    /// when the focused element exposes no readable string value (non-text
    /// control, or an app that doesn't implement the attribute).
    static func axFocusedFieldValue() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .success,
            let any = focused,
            CFGetTypeID(any) == AXUIElementGetTypeID()
        else { return nil }

        // Safe: guarded by the CFGetTypeID check above (see axSelection()).
        let element = any as! AXUIElement

        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &value
            ) == .success,
            let s = value as? String,
            !s.isEmpty
        else { return nil }
        return s
    }

    /// AX-only check of whether the focused element's selected text can be
    /// written back — asks `AXUIElementIsAttributeSettable` about
    /// `kAXSelectedTextAttribute`, the same attribute `AXSelectionWriter.write`
    /// sets, so it predicts whether the `.replaceSelection` AX write will be
    /// accepted without actually mutating anything.
    ///
    /// Returns `false` when the attribute is not settable, when the focused
    /// element doesn't implement it (Electron / Chrome / VSCode / PDF viewers),
    /// or when nothing is focused. `false` therefore means "not confirmed
    /// editable", not strictly "read-only"; some clients also mis-report
    /// settability, so treat the result as a hint, not a guarantee.
    static func isSelectionEditable() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .success,
            let any = focused,
            CFGetTypeID(any) == AXUIElementGetTypeID()
        else { return false }

        // Safe: guarded by the CFGetTypeID check above (see axSelection()).
        let element = any as! AXUIElement

        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        )
        return status == .success && settable.boolValue
    }

    /// Conservative pre-flight classification of the current focused element, used
    /// to decide whether a raw-dictation Cmd+V has any editable target at all.
    /// Cmd+V is fire-and-forget, so this must run BEFORE injecting.
    ///
    /// - `.editable`    : focused element exposes a settable text value/selection.
    /// - `.nonEditable` : there is no focused UI element at all, OR a focused
    ///                    element resolves whose value/selectedText is not settable
    ///                    AND whose role is a known non-editable role.
    /// - `.unknown`     : AX could not decide (attribute unsupported / app doesn't
    ///                    implement AX — Electron / Chrome / VSCode / Slack). Callers
    ///                    MUST treat `.unknown` as editable to avoid regressing those
    ///                    apps, which accept Cmd+V despite failing AX probes.
    static func focusedTargetEditability() -> FocusEditability {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .success,
            let any = focused,
            CFGetTypeID(any) == AXUIElementGetTypeID()
        else {
            // No focused UI element at all — the high-confidence "nowhere to type"
            // case (Finder desktop, image/PDF viewer, game).
            return .nonEditable
        }

        // Safe: guarded by the CFGetTypeID check above (see axSelection()).
        let element = any as! AXUIElement

        if isAttributeSettable(element, kAXSelectedTextAttribute)
            || isAttributeSettable(element, kAXValueAttribute) {
            return .editable
        }

        var roleRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXRoleAttribute as CFString, &roleRef
            ) == .success,
            let role = roleRef as? String
        else {
            // Role unreadable → can't tell → be safe, let paste proceed.
            return .unknown
        }

        // Roles that are text-editable but sometimes mis-report settability →
        // stay in the safety bucket so paste proceeds.
        let editableRoles: Set<String> = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
            "AXSearchField",
        ]
        if editableRoles.contains(role) { return .unknown }

        // Confidently non-editable roles. Container roles (AXGroup, AXScrollArea,
        // AXList, AXTable) are deliberately EXCLUDED: a partial-AX web/Electron app
        // can report a focused contenteditable as AXGroup with a non-settable value
        // yet still accept Cmd+V, so they must stay in the .unknown safety bucket.
        let nonEditableRoles: Set<String> = [
            kAXStaticTextRole, kAXImageRole, "AXWebArea", kAXButtonRole,
            kAXMenuItemRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
        ]
        if nonEditableRoles.contains(role) { return .nonEditable }

        // Any other role → can't tell → favor pasting.
        return .unknown
    }

    private static func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    // MARK: - AX path

    enum AXResult {
        case text(String)
        case emptyButSupported
        case unsupported
    }

    static func axSelection() -> AXResult {
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
