import ApplicationServices
import Foundation

// Temporary minimal protocol — moved into ContextResolver.swift in Task 9.
protocol ContextSource {
    var providedKind: TextSource { get }
    func read() async throws -> TextFragment?
}

enum SelectionWriteError: Error, CustomStringConvertible {
    case notSettable
    case axCallFailed(AXError)

    var description: String {
        switch self {
        case .notSettable: return "notSettable"
        case .axCallFailed(let e): return "axCallFailed(\(e.rawValue))"
        }
    }
}

final class SelectionSource: ContextSource {
    var providedKind: TextSource { .selectedText }

    func read() async throws -> TextFragment? {
        guard let s = Self.currentSelection(), !s.isEmpty else { return nil }
        return TextFragment(source: .selectedText, text: s, meta: [:])
    }

    /// Returns the focused element's selected text, or nil if no selection / no AX
    /// permission / the element does not implement kAXSelectedTextAttribute.
    static func currentSelection() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success,
              let any = focused,
              CFGetTypeID(any) == AXUIElementGetTypeID() else { return nil }
        let element = any as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selected
        ) == .success, let s = selected as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Writes `text` to the focused element's selected-text attribute, replacing
    /// the current selection. Throws `SelectionWriteError.notSettable` when the
    /// element is not settable (webviews, terminal emulators), or `.axCallFailed`
    /// for other AX errors. Caller is expected to fall back (e.g. to
    /// `.replaceFocusedText` strategy) on `.notSettable`.
    static func replaceSelection(with text: String) throws {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success,
              let any = focused,
              CFGetTypeID(any) == AXUIElementGetTypeID() else {
            throw SelectionWriteError.notSettable
        }
        let element = any as! AXUIElement

        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        )
        guard settableStatus == .success, settable.boolValue else {
            throw SelectionWriteError.notSettable
        }

        let status = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        guard status == .success else {
            throw SelectionWriteError.axCallFailed(status)
        }
    }
}
