import ApplicationServices

/// Reads the focused element's selected text via the Accessibility API.
/// Returns nil if no selection, no AX permission, or the focused element
/// does not implement kAXSelectedTextAttribute (e.g. some Electron apps).
enum SelectionTextProvider {
    static func currentSelection() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let any = focused else { return nil }

        let element = any as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selected
        ) == .success, let s = selected as? String, !s.isEmpty else { return nil }

        return s
    }
}
