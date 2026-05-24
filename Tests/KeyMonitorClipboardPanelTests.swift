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

        expect(KeyMonitor.shouldCancelVoiceForUnexpectedKeyPress(
            keyCode: 0x78,
            isAutoRepeat: false,
            isVoiceActive: true,
            voiceTriggerKeyCode: 0x3F,
            personaHotkeyKeyDown: CGKeyCode?.none
        ), "f2 cancels active fn voice session")
        expect(!KeyMonitor.shouldCancelVoiceForUnexpectedKeyPress(
            keyCode: 0x78,
            isAutoRepeat: false,
            isVoiceActive: false,
            voiceTriggerKeyCode: 0x3F,
            personaHotkeyKeyDown: CGKeyCode?.none
        ), "f2 does not cancel inactive voice session")
        expect(!KeyMonitor.shouldCancelVoiceForUnexpectedKeyPress(
            keyCode: 0x3F,
            isAutoRepeat: false,
            isVoiceActive: true,
            voiceTriggerKeyCode: 0x3F,
            personaHotkeyKeyDown: CGKeyCode?.none
        ), "voice trigger key does not cancel its own session")
        expect(!KeyMonitor.shouldCancelVoiceForUnexpectedKeyPress(
            keyCode: 0x06,
            isAutoRepeat: false,
            isVoiceActive: true,
            voiceTriggerKeyCode: 0x3F,
            personaHotkeyKeyDown: 0x06
        ), "persona hotkey key does not cancel its own session")
        expect(!KeyMonitor.shouldCancelVoiceForUnexpectedKeyPress(
            keyCode: 0x78,
            isAutoRepeat: true,
            isVoiceActive: true,
            voiceTriggerKeyCode: 0x3F,
            personaHotkeyKeyDown: CGKeyCode?.none
        ), "autorepeat keyDown does not repeatedly cancel voice session")

        var heldModifiers: Set<CGKeyCode> = []
        KeyMonitor.updateTrackedModifierState(
            heldModifiers: &heldModifiers,
            keyCode: 0x36,
            eventFlags: [],
            isResetRecoveryMode: true
        )
        expect(!heldModifiers.contains(0x36), "release after reset does not reinsert modifier")

        heldModifiers = [0x37]
        KeyMonitor.updateTrackedModifierState(
            heldModifiers: &heldModifiers,
            keyCode: 0x36,
            eventFlags: CGEventFlags.maskCommand,
            isResetRecoveryMode: false
        )
        expect(heldModifiers.contains(0x37), "left command remains held")
        expect(heldModifiers.contains(0x36), "right command press adds current key without clearing counterpart")

        print("KeyMonitorClipboardPanelTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
