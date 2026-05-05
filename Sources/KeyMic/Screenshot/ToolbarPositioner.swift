import Cocoa

/// Pure positioning logic for the floating toolbar panel.
///
/// Decides where to place the toolbar relative to the selection:
///  - Prefer below selection (8pt gap).
///  - If would clip screen bottom, flip above selection.
///  - Horizontally clamp to screen bounds (at least 8pt margin).
enum ToolbarPositioner {
    static let verticalGap: CGFloat = 8
    static let horizontalMargin: CGFloat = 8

    /// All inputs in the screen's coordinate space (bottom-left origin).
    static func origin(
        for toolbarSize: NSSize,
        selection: NSRect,
        screenFrame: NSRect
    ) -> NSPoint {
        // Horizontal: center under selection, then clamp to screen.
        var x = selection.midX - toolbarSize.width / 2
        let minX = screenFrame.minX + horizontalMargin
        let maxX = screenFrame.maxX - toolbarSize.width - horizontalMargin
        x = max(minX, min(maxX, x))

        // Vertical: prefer below (i.e. y = selection.minY - gap - height).
        let belowY = selection.minY - verticalGap - toolbarSize.height
        let aboveY = selection.maxY + verticalGap

        let y: CGFloat
        if belowY >= screenFrame.minY + horizontalMargin {
            y = belowY
        } else if aboveY + toolbarSize.height <= screenFrame.maxY - horizontalMargin {
            y = aboveY
        } else {
            // Both clip — pin to bottom of screen (with margin).
            y = screenFrame.minY + horizontalMargin
        }
        return NSPoint(x: x, y: y)
    }
}
