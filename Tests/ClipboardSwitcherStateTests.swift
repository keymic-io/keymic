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
            expect(s.onHotkeyTap(hotkeyModifiers: alt) == .open,
                   "first tap while hidden opens the panel")
            expect(s.active, "session is armed after open")
            expect(s.onHotkeyTap(hotkeyModifiers: alt) == .moveNext,
                   "second tap moves highlight")
            expect(s.onHotkeyTap(hotkeyModifiers: alt) == .moveNext,
                   "third tap moves highlight")
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: true) == .commitPaste,
                   "releasing modifier after >=2 taps commits the paste")
            expect(!s.active, "session disarms after commit")
        }

        // Single open-tap then release -> browse mode, no paste.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(hotkeyModifiers: alt)
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: true) == .none,
                   "releasing after a single open-tap does not paste (browse mode)")
            expect(!s.active, "session disarms on release")
        }

        // Browse mode: after disarm, the next tap re-arms a new session (open),
        // so a single subsequent tap+release still does not paste.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(hotkeyModifiers: alt)
            _ = s.onFlagsChanged(currentFlags: [], panelVisible: true) // disarm
            expect(s.onHotkeyTap(hotkeyModifiers: alt) == .open,
                   "hotkey after disarm starts a new session")
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: true) == .none,
                   "release after a single tap in the new session never pastes")
        }

        // Multi-modifier hotkey: lifting either modifier is the release edge.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(hotkeyModifiers: cmdShift)
            _ = s.onHotkeyTap(hotkeyModifiers: cmdShift)
            // Shift released, Cmd still held -> full set no longer satisfied.
            expect(s.onFlagsChanged(currentFlags: .maskCommand, panelVisible: true) == .commitPaste,
                   "lifting one of several required modifiers commits")
        }

        // Modifiers still fully held -> no release edge.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(hotkeyModifiers: cmdShift)
            _ = s.onHotkeyTap(hotkeyModifiers: cmdShift)
            expect(s.onFlagsChanged(currentFlags: cmdShift, panelVisible: true) == .none,
                   "no commit while all required modifiers remain held")
            expect(s.active, "session stays armed while modifiers held")
        }

        // Panel already gone (Esc/click-away) -> release disarms without pasting.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(hotkeyModifiers: alt)
            _ = s.onHotkeyTap(hotkeyModifiers: alt)
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: false) == .none,
                   "release with panel not visible does not paste")
            expect(!s.active, "session disarms even when panel already closed")
        }

        // reset() clears everything.
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(hotkeyModifiers: alt)
            _ = s.onHotkeyTap(hotkeyModifiers: alt)
            s.reset()
            expect(!s.active, "reset disarms")
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: true) == .none,
                   "reset clears pending commit")
        }

        // Rapid taps before the panel's async open lands: both taps see panelVisible=false
        // at the KeyMonitor call site, yet the second tap must still advance the count so
        // release commits the paste (previously reset tapCount -> 1 -> lost paste).
        do {
            var s = ClipboardSwitcherState()
            _ = s.onHotkeyTap(hotkeyModifiers: alt)   // first tap: arm, count = 1
            _ = s.onHotkeyTap(hotkeyModifiers: alt)   // second tap arrives before panel shown
            expect(s.onFlagsChanged(currentFlags: [], panelVisible: true) == .commitPaste,
                   "two discrete taps commit the paste even if the panel had not yet been shown")
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
