import Cocoa

@main
struct OverlayStateTests {
    static func main() {
        testIdleToDrafting()
        testDraftingTooSmallReturnsFalse()
        testDraftingValidTransitionsToDrafted()
        testHandleHitTakesPrecedenceOverInterior()
        testInteriorSelectionTarget()
        testAnnotationHit()
        testResize()
        testMove()
        testAddRemoveAnnotation()
        testClear()
        testCancelResetsState()
        print("✅ OverlayState tests passed")
    }

    static func testIdleToDrafting() {
        let s = OverlayState()
        assert(s.phase == .idle)
        s.beginDrafting(at: NSPoint(x: 100, y: 100))
        s.updateDrafting(to: NSPoint(x: 200, y: 200))
        assert(s.selection.width == 100 && s.selection.height == 100)
    }

    static func testDraftingTooSmallReturnsFalse() {
        let s = OverlayState()
        s.beginDrafting(at: NSPoint(x: 0, y: 0))
        s.updateDrafting(to: NSPoint(x: 2, y: 2))
        assert(s.finishDrafting() == false)
        assert(s.phase == .idle)
    }

    static func testDraftingValidTransitionsToDrafted() {
        let s = OverlayState()
        s.beginDrafting(at: NSPoint(x: 0, y: 0))
        s.updateDrafting(to: NSPoint(x: 100, y: 100))
        assert(s.finishDrafting() == true)
        assert(s.phase == .drafted)
    }

    static func testHandleHitTakesPrecedenceOverInterior() {
        let s = OverlayState()
        s.beginDrafting(at: NSPoint(x: 100, y: 100))
        s.updateDrafting(to: NSPoint(x: 300, y: 200))
        _ = s.finishDrafting()
        let target = s.target(for: NSPoint(x: 100, y: 100))
        if case .handle(let h) = target {
            assert(h == .bottomLeft)
        } else {
            fatalError("expected handle hit, got \(target)")
        }
    }

    static func testInteriorSelectionTarget() {
        let s = OverlayState()
        s.beginDrafting(at: NSPoint(x: 100, y: 100))
        s.updateDrafting(to: NSPoint(x: 300, y: 200))
        _ = s.finishDrafting()
        let target = s.target(for: NSPoint(x: 200, y: 150))
        if case .selectionInterior = target {} else {
            fatalError("expected selectionInterior")
        }
    }

    static func testAnnotationHit() {
        let s = OverlayState()
        s.beginDrafting(at: NSPoint(x: 100, y: 100))
        s.updateDrafting(to: NSPoint(x: 300, y: 300))
        _ = s.finishDrafting()
        let ann = Annotation(kind: .rect,
                             startPoint: NSPoint(x: 10, y: 10),
                             endPoint: NSPoint(x: 50, y: 50))
        s.addAnnotation(ann)
        let target = s.target(for: NSPoint(x: 130, y: 130))
        if case .annotation(let id) = target {
            assert(id == ann.id)
        } else {
            fatalError("expected annotation hit, got \(target)")
        }
    }

    static func testResize() {
        let s = OverlayState()
        s.beginDrafting(at: NSPoint(x: 100, y: 100))
        s.updateDrafting(to: NSPoint(x: 300, y: 200))
        _ = s.finishDrafting()
        s.beginResizing(handle: .topRight)
        s.updateResizing(to: NSPoint(x: 400, y: 300))
        assert(s.selection == NSRect(x: 100, y: 100, width: 300, height: 200))
        s.finishGesture()
        assert(s.phase == .drafted)
    }

    static func testMove() {
        let s = OverlayState()
        s.beginDrafting(at: NSPoint(x: 100, y: 100))
        s.updateDrafting(to: NSPoint(x: 300, y: 200))
        _ = s.finishDrafting()
        s.beginMoving(at: NSPoint(x: 200, y: 150))
        s.updateMoving(to: NSPoint(x: 250, y: 200))
        assert(s.selection.origin == NSPoint(x: 150, y: 150))
        assert(s.selection.size == NSSize(width: 200, height: 100))
    }

    static func testAddRemoveAnnotation() {
        let s = OverlayState()
        let a = Annotation(kind: .rect, startPoint: .zero, endPoint: NSPoint(x: 10, y: 10))
        s.addAnnotation(a)
        assert(s.annotations.count == 1)
        s.selectAnnotation(a.id)
        s.removeSelectedAnnotation()
        assert(s.annotations.isEmpty)
        assert(s.selectedAnnotationID == nil)
    }

    static func testClear() {
        let s = OverlayState()
        s.addAnnotation(Annotation(kind: .rect, startPoint: .zero, endPoint: NSPoint(x: 1, y: 1)))
        s.addAnnotation(Annotation(kind: .ellipse, startPoint: .zero, endPoint: NSPoint(x: 2, y: 2)))
        s.clearAnnotations()
        assert(s.annotations.isEmpty)
    }

    static func testCancelResetsState() {
        let s = OverlayState()
        s.beginDrafting(at: NSPoint(x: 0, y: 0))
        s.updateDrafting(to: NSPoint(x: 50, y: 50))
        _ = s.finishDrafting()
        s.addAnnotation(Annotation(kind: .rect, startPoint: .zero, endPoint: NSPoint(x: 10, y: 10)))
        s.cancel()
        assert(s.phase == .idle)
        assert(s.selection == .zero)
        assert(s.annotations.isEmpty)
    }
}
