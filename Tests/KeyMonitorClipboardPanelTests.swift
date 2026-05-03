import CoreGraphics
import Foundation

@main
struct KeyMonitorClipboardPanelTestRunner {
    static func main() {
        expect(KeyMonitor.clipboardPanelQuickPasteIndex(keyCode: 0x12, flags: .maskAlternate) == 0, "alt+1 maps to first clipboard item")
        expect(KeyMonitor.clipboardPanelQuickPasteIndex(keyCode: 0x13, flags: .maskAlternate) == 1, "alt+2 maps to second clipboard item")
        expect(KeyMonitor.clipboardPanelQuickPasteIndex(keyCode: 0x1D, flags: .maskAlternate) == 9, "alt+0 maps to tenth clipboard item")
        expect(KeyMonitor.clipboardPanelQuickPasteIndex(keyCode: 0x13, flags: [.maskAlternate, .maskCommand]) == nil, "extra modifiers do not quick paste")
        expect(KeyMonitor.clipboardPanelQuickPasteIndex(keyCode: 0x09, flags: .maskAlternate) == nil, "non-number alt shortcut does not quick paste")

        print("KeyMonitorClipboardPanelTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
