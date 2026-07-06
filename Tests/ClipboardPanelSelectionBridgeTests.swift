import Foundation

@MainActor
@main
struct ClipboardPanelSelectionBridgeTestRunner {
    static func main() {
        orderedSelectionUsesVisibleOrder()
        hasCurrentTargetTracksFocusOrSelection()
        print("ClipboardPanelSelectionBridgeTests passed")
    }

    private static func orderedSelectionUsesVisibleOrder() {
        let ids = [UUID(), UUID(), UUID()]
        let bridge = ClipboardPanelSelectionBridge()
        bridge.visibleOrderedIDs = ids
        bridge.appendSelection(ids[2])
        bridge.appendSelection(ids[0])

        expect(
            bridge.orderedSelection() == [ids[0], ids[2]],
            "orderedSelection should follow visible order instead of selection order"
        )
    }

    private static func hasCurrentTargetTracksFocusOrSelection() {
        let id = UUID()
        let bridge = ClipboardPanelSelectionBridge()
        expect(!bridge.hasCurrentTarget, "empty bridge should not expose a current target")

        bridge.focus(id)
        expect(bridge.hasCurrentTarget, "focused item should count as current target")

        bridge.focus(nil)
        bridge.appendSelection(id)
        expect(bridge.hasCurrentTarget, "selection should count as current target")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
