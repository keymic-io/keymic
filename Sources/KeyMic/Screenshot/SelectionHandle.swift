import Cocoa

/// Eight resize handles on a selection rectangle.
enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Visual size of the handle (used for drawing).
    static let visualSize: CGFloat = 8
    /// Hit test size (slightly larger for easier grabbing).
    static let hitSize: CGFloat = 14

    /// Anchor point on a selection rect. Coordinates are bottom-left-origin (NSView default).
    func anchor(in rect: NSRect) -> NSPoint {
        switch self {
        case .topLeft:     return NSPoint(x: rect.minX, y: rect.maxY)
        case .top:         return NSPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return NSPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return NSPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return NSPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return NSPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:  return NSPoint(x: rect.minX, y: rect.minY)
        case .left:        return NSPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// The opposite anchor — stays fixed during resize.
    var opposite: ResizeHandle {
        switch self {
        case .topLeft:     return .bottomRight
        case .top:         return .bottom
        case .topRight:    return .bottomLeft
        case .right:       return .left
        case .bottomRight: return .topLeft
        case .bottom:      return .top
        case .bottomLeft:  return .topRight
        case .left:        return .right
        }
    }

    /// Visual rect for drawing the handle (centered on anchor).
    func visualRect(in rect: NSRect) -> NSRect {
        let p = anchor(in: rect)
        let s = ResizeHandle.visualSize
        return NSRect(x: p.x - s/2, y: p.y - s/2, width: s, height: s)
    }

    /// Hit-test rect (slightly larger).
    func hitRect(in rect: NSRect) -> NSRect {
        let p = anchor(in: rect)
        let s = ResizeHandle.hitSize
        return NSRect(x: p.x - s/2, y: p.y - s/2, width: s, height: s)
    }

    /// Pick the handle whose hit rect contains `point`. Returns nil if none.
    static func handle(at point: NSPoint, in rect: NSRect) -> ResizeHandle? {
        for h in allCases where h.hitRect(in: rect).contains(point) {
            return h
        }
        return nil
    }

    /// Cursor to display when hovering this handle.
    var cursor: NSCursor {
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
        }
    }

    /// Resize the rect by moving this handle to `newPoint` while keeping the opposite anchor fixed.
    /// Returns a normalized NSRect (always positive width/height).
    func resize(rect: NSRect, to newPoint: NSPoint) -> NSRect {
        let opp = opposite.anchor(in: rect)
        var minX = min(opp.x, newPoint.x)
        var maxX = max(opp.x, newPoint.x)
        var minY = min(opp.y, newPoint.y)
        var maxY = max(opp.y, newPoint.y)

        switch self {
        case .top, .bottom:
            minX = rect.minX
            maxX = rect.maxX
        case .left, .right:
            minY = rect.minY
            maxY = rect.maxY
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            break
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
