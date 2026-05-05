import Cocoa

@main
struct ToolbarPositionerTests {
    static func main() {
        testBelowWhenRoom()
        testFlipAboveWhenBottomClipped()
        testHorizontalClampLeft()
        testHorizontalClampRight()
        testCenteredUnderSelection()
        print("✅ ToolbarPositioner tests passed")
    }

    static let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    static let toolbar = NSSize(width: 400, height: 80)

    static func testBelowWhenRoom() {
        let sel = NSRect(x: 800, y: 500, width: 200, height: 200)
        let p = ToolbarPositioner.origin(for: toolbar, selection: sel, screenFrame: screen)
        // Expected y: sel.minY - gap - height = 500 - 8 - 80 = 412
        assert(p.y == 412)
    }

    static func testFlipAboveWhenBottomClipped() {
        let sel = NSRect(x: 800, y: 30, width: 200, height: 200)
        let p = ToolbarPositioner.origin(for: toolbar, selection: sel, screenFrame: screen)
        // Below would be 30 - 8 - 80 = -58 (< 8 margin) → flip above
        // Above y = sel.maxY + gap = 230 + 8 = 238
        assert(p.y == 238)
    }

    static func testHorizontalClampLeft() {
        let sel = NSRect(x: 0, y: 500, width: 50, height: 50)
        let p = ToolbarPositioner.origin(for: toolbar, selection: sel, screenFrame: screen)
        // midX = 25, want x = -175, clamped to 8
        assert(p.x == 8)
    }

    static func testHorizontalClampRight() {
        let sel = NSRect(x: 1900, y: 500, width: 20, height: 20)
        let p = ToolbarPositioner.origin(for: toolbar, selection: sel, screenFrame: screen)
        // midX = 1910, want x = 1710, max = 1920 - 400 - 8 = 1512 → clamp to 1512
        assert(p.x == 1512)
    }

    static func testCenteredUnderSelection() {
        let sel = NSRect(x: 600, y: 500, width: 200, height: 100)
        let p = ToolbarPositioner.origin(for: toolbar, selection: sel, screenFrame: screen)
        // midX = 700; toolbar width 400 → x = 500
        assert(p.x == 500)
    }
}
