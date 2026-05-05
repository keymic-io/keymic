import Cocoa

@main
struct SelectionHandleTests {
    static func main() {
        testAllCasesCount()
        testAnchorPoints()
        testOppositeMapping()
        testVisualVsHitSize()
        testHandleAtPoint()
        testResizeCorner()
        testResizeEdge()
        print("✅ SelectionHandle tests passed")
    }

    static let baseRect = NSRect(x: 100, y: 100, width: 200, height: 100)

    static func testAllCasesCount() {
        assert(ResizeHandle.allCases.count == 8)
    }

    static func testAnchorPoints() {
        assert(ResizeHandle.bottomLeft.anchor(in: baseRect) == NSPoint(x: 100, y: 100))
        assert(ResizeHandle.topRight.anchor(in: baseRect) == NSPoint(x: 300, y: 200))
        assert(ResizeHandle.top.anchor(in: baseRect) == NSPoint(x: 200, y: 200))
        assert(ResizeHandle.left.anchor(in: baseRect) == NSPoint(x: 100, y: 150))
    }

    static func testOppositeMapping() {
        assert(ResizeHandle.topLeft.opposite == .bottomRight)
        assert(ResizeHandle.top.opposite == .bottom)
        assert(ResizeHandle.left.opposite == .right)
        assert(ResizeHandle.bottomLeft.opposite == .topRight)
    }

    static func testVisualVsHitSize() {
        let v = ResizeHandle.topLeft.visualRect(in: baseRect)
        let h = ResizeHandle.topLeft.hitRect(in: baseRect)
        assert(v.width == ResizeHandle.visualSize)
        assert(h.width == ResizeHandle.hitSize)
        assert(h.contains(v))
    }

    static func testHandleAtPoint() {
        let blAnchor = ResizeHandle.bottomLeft.anchor(in: baseRect)
        assert(ResizeHandle.handle(at: blAnchor, in: baseRect) == .bottomLeft)
        assert(ResizeHandle.handle(at: NSPoint(x: baseRect.midX, y: baseRect.midY), in: baseRect) == nil)
    }

    static func testResizeCorner() {
        let r = ResizeHandle.bottomLeft.resize(rect: baseRect, to: NSPoint(x: 50, y: 50))
        assert(r.minX == 50 && r.minY == 50 && r.maxX == 300 && r.maxY == 200)
    }

    static func testResizeEdge() {
        let r = ResizeHandle.top.resize(rect: baseRect, to: NSPoint(x: 999, y: 300))
        assert(r.minX == baseRect.minX && r.maxX == baseRect.maxX)
        assert(r.minY == baseRect.minY && r.maxY == 300)
    }
}
