import Cocoa

// NOTE (concern): The magnifier in v1 is a mock — a dark circle with a crosshair reticle.
// A true 4x-zoom magnifier using CGWindowListCreateImage is deferred because:
//   1. We must exclude our own overlay panel windowIDs from the capture, requiring the
//      window list to be known at draw-time (a threading/ordering hazard).
//   2. A live capture every mouseMoved tick is too expensive; a proper implementation
//      would capture a frozen frame once on drag-start and pass cropped chunks to the
//      view via a separate update path (ScreenshotController can wire this up later).
// ScreenshotController can upgrade this by calling setCursorPosition with a pre-cropped
// CGImage thumbnail; the view can then blit it inside the circle.

final class SelectionOverlayView: NSView {
    weak var panel: SelectionOverlayPanel?
    var selectionRect: NSRect? = nil
    var cursorPosition: NSPoint? = nil
    var frozen: Bool = false  // when another screen owns active drag

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }  // bottom-left origin matches NSScreen

    override init(frame: NSRect) {
        super.init(frame: frame)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 25% black mask over entire bounds
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        // 2. Selection rect: clear the region + dual border
        if let rect = selectionRect {
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            NSColor.clear.setFill()
            rect.fill()
            ctx.restoreGState()

            // White solid 1.5pt outer border
            NSColor.white.setStroke()
            let outer = NSBezierPath(rect: rect)
            outer.lineWidth = 1.5
            outer.stroke()

            // Black dashed 0.5pt inner border
            NSColor.black.withAlphaComponent(0.7).setStroke()
            let inner = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
            inner.lineWidth = 0.5
            inner.setLineDash([4, 4], count: 2, phase: 0)
            inner.stroke()
        }

        // 3. Crosshair guides (only when not frozen and cursor known)
        if !frozen, let cur = cursorPosition {
            // Black 2pt background lines
            NSColor.black.withAlphaComponent(0.6).setStroke()
            let hBack = NSBezierPath()
            hBack.move(to: NSPoint(x: bounds.minX, y: cur.y))
            hBack.line(to: NSPoint(x: bounds.maxX, y: cur.y))
            hBack.lineWidth = 2
            hBack.stroke()

            let vBack = NSBezierPath()
            vBack.move(to: NSPoint(x: cur.x, y: bounds.minY))
            vBack.line(to: NSPoint(x: cur.x, y: bounds.maxY))
            vBack.lineWidth = 2
            vBack.stroke()

            // White 1pt overlay lines
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let hFront = NSBezierPath()
            hFront.move(to: NSPoint(x: bounds.minX, y: cur.y))
            hFront.line(to: NSPoint(x: bounds.maxX, y: cur.y))
            hFront.lineWidth = 1
            hFront.stroke()

            let vFront = NSBezierPath()
            vFront.move(to: NSPoint(x: cur.x, y: bounds.minY))
            vFront.line(to: NSPoint(x: cur.x, y: bounds.maxY))
            vFront.lineWidth = 1
            vFront.stroke()
        }

        // 4. Magnifier (v1 mock: dark circle with crosshair reticle)
        // See concern note at top of file. True 4x zoom is deferred to a future task.
        if !frozen, let cur = cursorPosition {
            let magDiameter: CGFloat = 130
            let magOffset: CGFloat = 20
            var magOrigin = NSPoint(x: cur.x + magOffset, y: cur.y - magDiameter - magOffset)
            let magRect = NSRect(origin: magOrigin, size: NSSize(width: magDiameter, height: magDiameter))
            let clamped = clampToBounds(magRect)
            magOrigin = clamped.origin

            ctx.saveGState()

            // Dark fill
            NSColor.black.withAlphaComponent(0.65).setFill()
            let circlePath = NSBezierPath(ovalIn: clamped)
            circlePath.fill()

            // White 2pt outer border
            NSColor.white.setStroke()
            circlePath.lineWidth = 2
            circlePath.stroke()

            // Black 1pt inner border
            let innerCircle = NSBezierPath(ovalIn: clamped.insetBy(dx: 1.5, dy: 1.5))
            NSColor.black.withAlphaComponent(0.4).setStroke()
            innerCircle.lineWidth = 1
            innerCircle.stroke()

            // Crosshair inside magnifier circle
            let cx = clamped.midX
            let cy = clamped.midY
            NSColor.white.withAlphaComponent(0.4).setStroke()
            let xline = NSBezierPath()
            xline.move(to: NSPoint(x: clamped.minX + 10, y: cy))
            xline.line(to: NSPoint(x: clamped.maxX - 10, y: cy))
            xline.lineWidth = 1
            xline.stroke()

            let yline = NSBezierPath()
            yline.move(to: NSPoint(x: cx, y: clamped.minY + 10))
            yline.line(to: NSPoint(x: cx, y: clamped.maxY - 10))
            yline.lineWidth = 1
            yline.stroke()

            ctx.restoreGState()
        }

        // 5. Dimensions HUD
        if let rect = selectionRect, rect.width >= 1, rect.height >= 1 {
            let str = String(format: "%d × %d  @ %d,%d",
                             Int(rect.width), Int(rect.height),
                             Int(rect.origin.x), Int(rect.origin.y))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let textSize = (str as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 4
            var hudRect = NSRect(
                x: rect.minX,
                y: rect.minY - textSize.height - pad * 2 - 4,
                width: textSize.width + pad * 2,
                height: textSize.height + pad * 2
            )
            // Flip above selection if it would clip bottom of screen
            if hudRect.minY < bounds.minY {
                hudRect.origin.y = rect.maxY + 4
            }
            // Clamp horizontally
            if hudRect.maxX > bounds.maxX {
                hudRect.origin.x = bounds.maxX - hudRect.width
            }

            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: hudRect, xRadius: 3, yRadius: 3).fill()
            (str as NSString).draw(
                at: NSPoint(x: hudRect.minX + pad, y: hudRect.minY + pad),
                withAttributes: attrs
            )
        }

        // 6. Hint text (when no selection and not frozen)
        if selectionRect == nil && !frozen {
            let hint = "Click and drag to select a region  •  Press Esc to cancel"
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = .zero
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.white,
                .shadow: shadow,
            ]
            let size = (hint as NSString).size(withAttributes: attrs)
            (hint as NSString).draw(
                at: NSPoint(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2),
                withAttributes: attrs
            )
        }
    }

    // MARK: - Helpers

    private func clampToBounds(_ r: NSRect) -> NSRect {
        var rect = r
        if rect.minX < bounds.minX + 4 { rect.origin.x = bounds.minX + 4 }
        if rect.minY < bounds.minY + 4 { rect.origin.y = bounds.minY + 4 }
        if rect.maxX > bounds.maxX - 4 { rect.origin.x = bounds.maxX - rect.width - 4 }
        if rect.maxY > bounds.maxY - 4 { rect.origin.y = bounds.maxY - rect.height - 4 }
        return rect
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        panel?.onMouseDown?(event, panel!.owningScreen)
    }

    override func mouseDragged(with event: NSEvent) {
        panel?.onMouseDragged?(event, panel!.owningScreen)
    }

    override func mouseUp(with event: NSEvent) {
        panel?.onMouseUp?(event, panel!.owningScreen)
    }

    override func mouseMoved(with event: NSEvent) {
        panel?.onMouseMoved?(event, panel!.owningScreen)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            panel?.onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }
}
