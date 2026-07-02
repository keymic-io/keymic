import CoreGraphics
import Foundation

@main
struct ClipboardSwitcherStateTestRunner {
    static func main() {
        let alt: CGEventFlags = .maskAlternate
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]

        // Hold + cycle: open, move, move, release -> commit paste.
        do {
            var s = ClipboardSwitcherState()
            expect(s.onHotkeyTap(panelVisible: false, hotkeyModifiers: alt) == .open,
                   "first tap while hidden opens the panel")
            expect(s.active, "session is armed after open")
            expect(s.onHotkeyTap(panelVisible: true, hotkeyModifiers: alt) == .moveNext,
                   "second tap moves highlight")
            expect(s.onHotkeyTap(panelVisible: true, hotkeyModifiers: alt) == .moveNext,
                   "third tap moves highlight")
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: true) == .commitPaste,
                   "releasing modifier after >=2 taps commits the paste")
            expect(!s.active, "session disarms after commit")
        }

        // Single open-tap then release -> browse mode, no paste.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(panelVisible: false, hotkeyModifiers: alt)
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: true) == .none,
                   "releasing after a single open-tap does not paste (browse mode)")
            expect(!s.active, "session disarms on release")
        }

        // Browse mode: taps while not armed only move, release never pastes.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(panelVisible: false, hotkeyModifiers: alt)
            _ = s.onFlagsChanged(currentFlags: [], panelVisible: true) // disarm
            expect(s.onHotkeyTap(panelVisible: true, hotkeyModifiers: alt) == .moveNext,
                   "hotkey while browsing moves highlight")
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: true) == .none,
                   "release while not armed never pastes")
        }

        // Multi-modifier hotkey: lifting either modifier is the release edge.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(panelVisible: false, hotkeyModifiers: cmdShift)
            _ = s.onHotkeyTap(panelVisible: true, hotkeyModifiers: cmdShift)
            // Shift released, Cmd still held -> full set no longer satisfied.
            expect(s.onFlagsChanged(currentFlags: .maskCommand, panelVisible: true) == .commitPaste,
                   "lifting one of several required modifiers commits")
        }

        // Modifiers still fully held -> no release edge.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(panelVisible: false, hotkeyModifiers: cmdShift)
            _ = s.onHotkeyTap(panelVisible: true, hotkeyModifiers: cmdShift)
            expect(s.onFlagsChanged(currentFlags: cmdShift, panelVisible: true) == .none,
                   "no commit while all required modifiers remain held")
            expect(s.active, "session stays armed while modifiers held")
        }

        // Panel already gone (Esc/click-away) -> release disarms without pasting.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(panelVisible: false, hotkeyModifiers: alt)
            _ = s.onHotkeyTap(panelVisible: true, hotkeyModifiers: alt)
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: false) == .none,
                   "release with panel not visible does not paste")
            expect(!s.active, "session disarms even when panel already closed")
        }

        // reset() clears everything.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(panelVisible: false, hotkeyModifiers: alt)
            _ = s.onHotkeyTap(panelVisible: true, hotkeyModifiers: alt)
            s.reset()
            expect(!s.active, "reset disarms")
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: true) == .none,
                   "reset clears pending commit")
        }

        print("ClipboardSwitcherStateTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
