import AppKit

/// Custom `NSMenuItem.view` for the tray's on/off toggle rows
/// (Voice Enabled, Key Mapping, Clipboard History, Shortcuts).
///
/// Like `PersonaMenuItemView`, using a custom view bypasses `NSMenu`'s default
/// click-then-dismiss behavior: clicking the row flips the toggle and redraws it
/// in place, so the menu stays open and the user can flip several switches in one
/// pass. The menu closes normally when the pointer leaves it or a click lands
/// elsewhere.
///
/// The state column draws a colored badge instead of the system checkmark:
/// a white check on a green circle when ON, a white minus on a red circle when OFF.
final class ToggleMenuItemView: NSView {
    private let title: String
    private var hotkeyText: String?
    private let icon: NSImage?
    private let isOn: () -> Bool
    private let onToggle: () -> Void

    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    private static let rowHeight: CGFloat = 22
    private static let stateColumnWidth: CGFloat = 22
    private static let iconColumnWidth: CGFloat = 22
    private static let rightPadding: CGFloat = 14
    private static let hotkeyGap: CGFloat = 18
    // Trailing inset for the shortcut text. Larger than `rightPadding` because the
    // menu reserves a trailing gutter for the submenu-disclosure arrow (the "Set
    // Voice Persona" row has a submenu), and the system right-aligns the other rows'
    // key-equivalents to the LEFT of that gutter. Match it so all shortcuts line up.
    private static let shortcutTrailingInset: CGFloat = 24

    private static var titleX: CGFloat { stateColumnWidth + iconColumnWidth }

    // Template symbols (uncolored); tinted at draw time. `.circle.fill` keeps the
    // checkmark/minus as negative space, so tinting the circle leaves the glyph
    // transparent — it shows the menu background, reading as a white glyph on a
    // colored circle (and adapting to light/dark automatically).
    private static let onCheck = symbol("checkmark.circle.fill")
    private static let offMinus = symbol("minus.circle.fill")

    init(
        title: String,
        hotkeyText: String?,
        icon: NSImage?,
        isOn: @escaping () -> Bool,
        onToggle: @escaping () -> Void
    ) {
        self.title = title
        self.hotkeyText = hotkeyText
        self.icon = icon
        self.isOn = isOn
        self.onToggle = onToggle
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: Self.measureWidth(title: title, hotkeyText: hotkeyText),
            height: Self.rowHeight
        ))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    /// Refresh the trailing shortcut hint — the voice trigger key can change in Settings.
    func updateHotkey(_ text: String?) {
        guard text != hotkeyText else { return }
        hotkeyText = text
        var f = frame
        f.size.width = Self.measureWidth(title: title, hotkeyText: text)
        frame = f
        needsDisplay = true
    }

    static func measureWidth(title: String, hotkeyText: String?) -> CGFloat {
        let titleSize = (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)])
        if let hk = hotkeyText {
            let hkSize = (hk as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)])
            return ceil(titleX + titleSize.width + hotkeyGap + hkSize.width + shortcutTrailingInset)
        }
        return ceil(titleX + titleSize.width + rightPadding)
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
        onToggle()
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

        // State column: a checkmark in a circle when ON (circle follows the text
        // color — black on light, white on dark), a minus in a red circle when OFF.
        let badge = isOn() ? Self.onCheck : Self.offMinus
        let badgeColor: NSColor = isOn() ? textColor : .systemRed
        if let badge {
            let s = badge.size
            Self.tinted(badge, badgeColor).draw(in: NSRect(
                x: (Self.stateColumnWidth - s.width) / 2,
                y: (bounds.height - s.height) / 2,
                width: s.width,
                height: s.height
            ))
        }

        // Leading icon (template SF Symbol, tinted to match the text color).
        if let icon {
            let s = icon.size
            let rect = NSRect(
                x: Self.stateColumnWidth + (Self.iconColumnWidth - s.width) / 2,
                y: (bounds.height - s.height) / 2,
                width: s.width,
                height: s.height
            )
            Self.tinted(icon, textColor).draw(in: rect)
        }

        (title as NSString).draw(at: NSPoint(x: Self.titleX, y: textY), withAttributes: titleAttrs)

        if let hk = hotkeyText {
            let size = (hk as NSString).size(withAttributes: hkAttrs)
            let x = bounds.width - size.width - Self.shortcutTrailingInset
            (hk as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: hkAttrs)
        }
    }

    // MARK: - Image helpers

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Recolor a template symbol image to `color` (AppKit has no UIKit-style
    /// `withTintColor`, so composite the color over the alpha channel).
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}
