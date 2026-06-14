import AppKit

/// Custom view used as `NSMenuItem.view` for persona entries in the tray submenu.
///
/// Using a custom view (instead of a plain `NSMenuItem` with an action) bypasses
/// `NSMenu`'s default click-then-dismiss behavior — the menu stays open after the
/// click, and only closes when the mouse leaves the submenu (which `NSMenu`
/// handles automatically via its tracking).
final class PersonaMenuItemView: NSView {
    let personaId: String
    /// Exposed (with `hotkeyText`) so `rebuildPersonasMenu`'s fast path can
    /// detect rename/re-record and rebuild instead of redrawing stale copies.
    let title: String
    let hotkeyText: String?
    private let onClick: () -> Void

    /// Re-read at draw time so view state always reflects the latest store value.
    private var isActive: Bool { PersonaStore.shared.activePersonaId == personaId }
    private var isHovered = false { didSet { needsDisplay = true } }

    private var trackingArea: NSTrackingArea?

    private static let rowHeight: CGFloat = 22
    private static let leftPadding: CGFloat = 22
    private static let rightPadding: CGFloat = 14
    private static let hotkeyGap: CGFloat = 18

    init(personaId: String, title: String, hotkeyText: String?, onClick: @escaping () -> Void) {
        self.personaId = personaId
        self.title = title
        self.hotkeyText = hotkeyText
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: PersonaMenuItemView.measureWidth(title: title, hotkeyText: hotkeyText), height: Self.rowHeight))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    static func measureWidth(title: String, hotkeyText: String?) -> CGFloat {
        let titleSize = (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)])
        var width = leftPadding + titleSize.width + rightPadding
        if let hk = hotkeyText {
            let hkSize = (hk as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)])
            width += hotkeyGap + hkSize.width
        }
        return ceil(width)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        onClick()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let textColor: NSColor = isHovered ? .selectedMenuItemTextColor : .labelColor
        let secondaryColor: NSColor = isHovered ? .selectedMenuItemTextColor : .secondaryLabelColor

        if isHovered {
            NSColor.selectedMenuItemColor.setFill()
            bounds.fill()
        }

        let baseFont = NSFont.menuFont(ofSize: 0)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: textColor]
        let hkAttrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: secondaryColor]

        let textY = (bounds.height - baseFont.ascender + baseFont.descender) / 2 - 1

        if isActive {
            let mark = "✓" as NSString
            let markSize = mark.size(withAttributes: titleAttrs)
            mark.draw(at: NSPoint(x: (Self.leftPadding - markSize.width) / 2, y: textY), withAttributes: titleAttrs)
        }

        (title as NSString).draw(at: NSPoint(x: Self.leftPadding, y: textY), withAttributes: titleAttrs)

        if let hk = hotkeyText {
            let size = (hk as NSString).size(withAttributes: hkAttrs)
            let x = bounds.width - size.width - Self.rightPadding
            (hk as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: hkAttrs)
        }
    }
}
