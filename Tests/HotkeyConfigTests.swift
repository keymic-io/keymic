import CoreGraphics
import Foundation

@main
struct HotkeyConfigTestRunner {
    static func main() {
        // round-trip: alt+v
        let altV = HotkeyConfig.parse("alt+v")!
        expect(altV.encode() == "alt+v", "alt+v round-trips")
        expect(altV.modifiers == .maskAlternate, "alt+v modifier")
        expect(altV.keyCode == 0x09, "alt+v keyCode")

        // canonical order: parse accepts any order, encode emits canonical
        let a = HotkeyConfig.parse("shift+cmd+v")!
        let b = HotkeyConfig.parse("cmd+shift+v")!
        expect(a == b, "modifier order doesn't change identity")
        expect(a.encode() == "shift+cmd+v", "canonical order is shift+cmd")

        // displayString
        expect(a.displayString() == "⇧⌘V", "displayString uses symbols")

        // isSystemReserved
        let cmdC = HotkeyConfig.parse("cmd+c")!
        expect(cmdC.isSystemReserved, "cmd+c reserved")
        expect(!altV.isSystemReserved, "alt+v not reserved")

        // invalid input
        expect(HotkeyConfig.parse("") == nil, "empty rejected")
        expect(HotkeyConfig.parse("foo") == nil, "unknown key rejected")
        expect(HotkeyConfig.parse("alt+") == nil, "trailing + rejected")
        expect(HotkeyConfig.parse("+v") == nil, "leading + rejected")

        // pure-modifier
        let fn = HotkeyConfig.parse("fn")!
        expect(fn.isPureModifier, "fn is pure-modifier")
        expect(fn.keyCode == 0x3F, "fn keyCode")
        expect(fn.modifiers.isEmpty, "fn no modifiers flag")
        expect(fn.encode() == "fn", "fn round-trips")

        // legacy migration
        let legacy = HotkeyConfig.parse("rightoption")!
        expect(legacy.keyCode == 0x3D, "rightoption maps to 0x3D")
        expect(legacy.isPureModifier, "rightoption is pure-modifier")

        // matches()
        expect(altV.matches(keyCode: 0x09, flags: .maskAlternate), "alt+v matches ⌥V event")
        expect(!altV.matches(keyCode: 0x09, flags: [.maskAlternate, .maskCommand]), "extra modifier blocks match")
        expect(!altV.matches(keyCode: 0x08, flags: .maskAlternate), "different keyCode blocks match")
        expect(!fn.matches(keyCode: 0x3F, flags: .maskSecondaryFn), "pure-modifier .matches always false")

        let f2 = HotkeyConfig.parse("f2")!
        let fnF2 = HotkeyConfig.parse("fn+f2")!
        expect(f2.matches(keyCode: 0x78, flags: .maskSecondaryFn), "bare f2 matches implicit fn bit")
        expect(!f2.matches(keyCode: 0x78, flags: .maskSecondaryFn, fnHeld: true), "bare f2 does not match physical fn+f2")
        expect(fnF2.matches(keyCode: 0x78, flags: .maskSecondaryFn, fnHeld: true), "fn+f2 matches physical fn+f2")

        print("HotkeyConfigTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
