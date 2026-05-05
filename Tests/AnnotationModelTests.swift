import Cocoa

@main
struct AnnotationModelTests {
    static func main() {
        testRectComputation()
        testMinimumSize()
        testNSCopying()
        testHitTestRect()
        testHitTestArrow()
        testHitTestText()
        testResizeHandleGeometry()
        testMoveDelta()
        print("✅ AnnotationModel tests passed")
    }

    static func testRectComputation() {
        let a = Annotation(kind: .rect, startPoint: CGPoint(x: 10, y: 20), endPoint: CGPoint(x: 50, y: 60))
        assert(a.rect.origin.x == 10)
        assert(a.rect.origin.y == 20)
        assert(a.rect.width == 40)
        assert(a.rect.height == 40)
        let b = Annotation(kind: .rect, startPoint: CGPoint(x: 50, y: 60), endPoint: CGPoint(x: 10, y: 20))
        assert(b.rect.origin.x == 10)
        assert(b.rect.width == 40)
    }

    static func testMinimumSize() {
        let small = Annotation(kind: .rect, startPoint: .zero, endPoint: CGPoint(x: 2, y: 2))
        assert(!small.hasMinimumSize)
        let big = Annotation(kind: .rect, startPoint: .zero, endPoint: CGPoint(x: 10, y: 10))
        assert(big.hasMinimumSize)
    }

    static func testNSCopying() {
        let a = Annotation(kind: .ellipse, startPoint: .zero, endPoint: CGPoint(x: 100, y: 100), color: .systemBlue, lineWidth: 5)
        let b = a.copy() as! Annotation
        assert(b.kind == a.kind)
        assert(b.startPoint == a.startPoint)
        assert(b.endPoint == a.endPoint)
        assert(b.id != a.id)
    }

    static func testHitTestRect() {
        let a = Annotation(kind: .rect, startPoint: CGPoint(x: 10, y: 10), endPoint: CGPoint(x: 100, y: 100))
        let hitRect = a.rect.insetBy(dx: -6, dy: -6)
        assert(hitRect.contains(CGPoint(x: 50, y: 50)))
        assert(!hitRect.contains(CGPoint(x: 200, y: 200)))
    }

    static func testHitTestArrow() {
        let a = Annotation(kind: .arrow, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 100, y: 0), lineWidth: 3)
        let p = CGPoint(x: 50, y: 0)
        let dist = distanceFromPoint(p, toLineSegmentFrom: a.startPoint, to: a.endPoint)
        assert(dist <= max(CGFloat(6), a.lineWidth + 3))
        let q = CGPoint(x: 50, y: 50)
        let dist2 = distanceFromPoint(q, toLineSegmentFrom: a.startPoint, to: a.endPoint)
        assert(dist2 > max(CGFloat(6), a.lineWidth + 3))
    }

    static func testHitTestText() {
        let a = Annotation(kind: .text, startPoint: CGPoint(x: 10, y: 10), text: "Hello", fontSize: 18)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold)]
        let size = (a.text as NSString).size(withAttributes: attrs)
        let textRect = CGRect(origin: a.startPoint, size: size).insetBy(dx: -6, dy: -6)
        assert(textRect.contains(CGPoint(x: 20, y: 15)))
    }

    static func testResizeHandleGeometry() {
        let a = Annotation(kind: .rect, startPoint: CGPoint(x: 10, y: 10), endPoint: CGPoint(x: 100, y: 100))
        let selRect = a.rect.insetBy(dx: -4, dy: -4)
        let tl = CGPoint(x: selRect.minX, y: selRect.maxY)
        let tr = CGPoint(x: selRect.maxX, y: selRect.maxY)
        let bl = CGPoint(x: selRect.minX, y: selRect.minY)
        let br = CGPoint(x: selRect.maxX, y: selRect.minY)
        assert(tl.x == 6 && tl.y == 104)
        assert(tr.x == 104 && tr.y == 104)
        assert(bl.x == 6 && bl.y == 6)
        assert(br.x == 104 && br.y == 6)
    }

    static func testMoveDelta() {
        let a = Annotation(kind: .rect, startPoint: CGPoint(x: 10, y: 10), endPoint: CGPoint(x: 100, y: 100))
        let dx: CGFloat = 20, dy: CGFloat = 30
        a.startPoint = CGPoint(x: a.startPoint.x + dx, y: a.startPoint.y + dy)
        a.endPoint = CGPoint(x: a.endPoint.x + dx, y: a.endPoint.y + dy)
        assert(a.rect.origin.x == 30)
        assert(a.rect.origin.y == 40)
        assert(a.rect.width == 90)
    }

    static func distanceFromPoint(_ point: CGPoint, toLineSegmentFrom p1: CGPoint, to p2: CGPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - p1.x, point.y - p1.y) }
        let t = max(0, min(1, ((point.x - p1.x) * dx + (point.y - p1.y) * dy) / lengthSquared))
        let proj = CGPoint(x: p1.x + t * dx, y: p1.y + t * dy)
        return hypot(point.x - proj.x, point.y - proj.y)
    }
}
