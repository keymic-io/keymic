import AppKit
import CoreGraphics
import Foundation

struct HotkeyConfig: Hashable {
    let modifiers: CGEventFlags
    let keyCode: CGKeyCode

    static func == (lhs: HotkeyConfig, rhs: HotkeyConfig) -> Bool {
        lhs.modifiers.rawValue == rhs.modifiers.rawValue && lhs.keyCode == rhs.keyCode
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(modifiers.rawValue)
        hasher.combine(keyCode)
    }

    static let modifierKeyCodes: Set<CGKeyCode> = [
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
    ]

    static let cgModifierMask: CGEventFlags =
        [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    /// `CGEventType` in Swift has no `.systemDefined` case; NSEvent defines it
    /// with raw value 14. Used for media-key (volume/brightness/play) events.
    static let cgSystemDefinedRawValue: UInt32 = 14

    /// `NSEvent.systemDefined` subtype for the aux-control buttons (volume,
    /// brightness, play/pause, etc.) that ride on top of F1-F12 when "Use F1,
    /// F2…" is disabled in System Settings.
    static let auxControlSubtype: Int16 = 8

    /// F-row keyCodes only — F1 through F20.
    private static let fRowKeyCodes: [CGKeyCode] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1-F12
        105, 107, 113, 106, 64, 79, 80, 90,                     // F13-F20
    ]

    /// Arrow keys + navigation cluster (page up/down, home, end, fwd-delete).
    private static let navKeyCodes: [CGKeyCode] = [
        123, 124, 125, 126, 115, 116, 117, 119, 121,
    ]

    /// keyCodes for which macOS asserts `.maskSecondaryFn` on the keyDown even
    /// when the user did not press fn. Must be stripped from event flags before
    /// comparing against a recorded HotkeyConfig (which is itself recorded with
    /// fn stripped). See AGENTS.md for the underlying HID gotcha.
    static let implicitFnKeyCodes: Set<CGKeyCode> = Set(fRowKeyCodes + navKeyCodes)

    /// F1-F20 keyCodes — allowed as standalone hotkey (no modifier required).
    static let functionRowKeyCodes: Set<CGKeyCode> = Set(fRowKeyCodes)

    /// NX_KEYTYPE_* → F-row keyCode. F3 (Mission Control) / F4 (Spotlight or
    /// Launchpad) are consumed by WindowServer/Dock before reaching app event
    /// taps — they have no NX_KEYTYPE entry and cannot be captured in media mode.
    static let nxKeyTypeToFKey: [Int32: CGKeyCode] = [
        0:  111, // NX_KEYTYPE_SOUND_UP        → F12
        1:  103, // NX_KEYTYPE_SOUND_DOWN      → F11
        2:  120, // NX_KEYTYPE_BRIGHTNESS_UP   → F2
        3:  122, // NX_KEYTYPE_BRIGHTNESS_DOWN → F1
        7:  109, // NX_KEYTYPE_MUTE            → F10
        16: 100, // NX_KEYTYPE_PLAY            → F8
        17: 101, // NX_KEYTYPE_NEXT            → F9
        18:  98, // NX_KEYTYPE_PREVIOUS        → F7
        21:  97, // NX_KEYTYPE_ILLUMINATION_UP → F6
        22:  96, // NX_KEYTYPE_ILLUMINATION_DOWN → F5
    ]

    /// Recorded modifier flags for a press: masks to the five tracked modifier
    /// bits and strips the implicit fn that macOS asserts for F-row, arrows,
    /// and the nav cluster.
    static func recordedFlags(event: CGEvent, keyCode: CGKeyCode) -> CGEventFlags {
        var f = event.flags.intersection(cgModifierMask)
        if implicitFnKeyCodes.contains(keyCode) {
            f.remove(.maskSecondaryFn)
        }
        return f
    }

    /// Decode an aux-control systemDefined CGEvent into the underlying F-row
    /// keyCode (only on key-down). Returns nil for unrelated events or key-up.
    static func decodeMediaFKey(type: CGEventType, event: CGEvent) -> CGKeyCode? {
        guard type.rawValue == cgSystemDefinedRawValue,
              let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == auxControlSubtype else { return nil }
        let data1 = ns.data1
        let nxKeyType = Int32((data1 & 0xFFFF0000) >> 16)
        let keyFlags = Int32(data1 & 0x0000FFFF)
        let pressed = ((keyFlags & 0xFF00) >> 8) == 0x0A  // NX_KEYDOWN
        guard pressed else { return nil }
        return nxKeyTypeToFKey[nxKeyType]
    }


    var isPureModifier: Bool {
        modifiers.isEmpty && Self.modifierKeyCodes.contains(keyCode)
    }

    // MARK: - Encode

    func encode() -> String {
        if isPureModifier {
            return Self.pureModifierTokens[keyCode] ?? "unknown"
        }
        var parts: [String] = []
        if modifiers.contains(.maskSecondaryFn) { parts.append("fn") }
        if modifiers.contains(.maskControl)     { parts.append("ctrl") }
        if modifiers.contains(.maskAlternate)   { parts.append("alt") }
        if modifiers.contains(.maskShift)       { parts.append("shift") }
        if modifiers.contains(.maskCommand)     { parts.append("cmd") }
        parts.append(Self.keyToken(for: keyCode) ?? String(format: "0x%02x", keyCode))
        return parts.joined(separator: "+")
    }

    func displayString() -> String {
        if isPureModifier {
            return Self.pureModifierDisplay[keyCode] ?? encode()
        }
        var s = ""
        if modifiers.contains(.maskSecondaryFn) { s += "fn " }
        if modifiers.contains(.maskControl)     { s += "⌃" }
        if modifiers.contains(.maskAlternate)   { s += "⌥" }
        if modifiers.contains(.maskShift)       { s += "⇧" }
        if modifiers.contains(.maskCommand)     { s += "⌘" }
        s += (Self.keyDisplay[keyCode] ?? Self.keyToken(for: keyCode) ?? "?").uppercased()
        return s
    }

    // MARK: - Parse

    static func parse(_ raw: String) -> HotkeyConfig? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let normalized = pureModifierAliases[s] ?? s
        if let kc = pureModifierTokens.first(where: { $0.value == normalized })?.key {
            return HotkeyConfig(modifiers: [], keyCode: kc)
        }

        let tokens = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.isEmpty, !tokens.contains(where: { $0.isEmpty }) else { return nil }
        guard let last = tokens.last else { return nil }
        var keyCode: CGKeyCode?
        if let kc = tokenToKeyCode[last] {
            keyCode = kc
        } else if last.hasPrefix("0x"), let hex = UInt16(last.dropFirst(2), radix: 16) {
            keyCode = hex
        }
        guard let keyCode else { return nil }
        guard !modifierKeyCodes.contains(keyCode) || tokens.count > 1 else { return nil }

        var modifiers: CGEventFlags = []
        for mod in tokens.dropLast() {
            switch mod {
            case "cmd":   modifiers.insert(.maskCommand)
            case "shift": modifiers.insert(.maskShift)
            case "ctrl":  modifiers.insert(.maskControl)
            case "alt", "option":   modifiers.insert(.maskAlternate)
            case "fn":    modifiers.insert(.maskSecondaryFn)
            default:      return nil
            }
        }
        return HotkeyConfig(modifiers: modifiers, keyCode: keyCode)
    }

    // MARK: - Match

    func matches(keyCode otherKey: CGKeyCode, flags: CGEventFlags, fnHeld: Bool = false) -> Bool {
        guard !isPureModifier else { return false }
        guard otherKey == keyCode else { return false }
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        var eventModifiers = flags.intersection(mask)
        // F-row / arrow / nav keys arrive with .maskSecondaryFn asserted by
        // macOS even without a real fn press. Strip only implicit fn. Preserve
        // real physical Fn tracked from the dedicated flagsChanged event.
        if Self.implicitFnKeyCodes.contains(otherKey), !fnHeld {
            eventModifiers.remove(.maskSecondaryFn)
        }
        return eventModifiers == modifiers
    }

    // MARK: - Tables

    static let pureModifierTokens: [CGKeyCode: String] = [
        0x36: "rightcmd", 0x37: "leftcmd",
        0x38: "leftshift", 0x3C: "rightshift",
        0x39: "caps",
        0x3A: "leftalt", 0x3D: "rightalt",
        0x3B: "leftctrl", 0x3E: "rightctrl",
        0x3F: "fn",
    ]

    static let pureModifierDisplay: [CGKeyCode: String] = [
        0x36: "Right ⌘", 0x37: "Left ⌘",
        0x38: "Left ⇧", 0x3C: "Right ⇧",
        0x39: "Caps Lock",
        0x3A: "Left ⌥", 0x3D: "Right ⌥",
        0x3B: "Left ⌃", 0x3E: "Right ⌃",
        0x3F: "fn",
    ]

    private static let pureModifierAliases: [String: String] = [
        "rightoption": "rightalt",
        "leftoption":  "leftalt",
    ]

    static let tokenToKeyCode: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
        "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
        "return": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "escape": 0x35,
        ",": 0x2B, ".": 0x2F, "/": 0x2C, ";": 0x29, "'": 0x27,
        "[": 0x21, "]": 0x1E, "-": 0x1B, "=": 0x18, "`": 0x32,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    private static let keyDisplay: [CGKeyCode: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋",
    ]

    private static func keyToken(for code: CGKeyCode) -> String? {
        tokenToKeyCode.first(where: { $0.value == code })?.key
    }

    // MARK: - Reserved

    var isSystemReserved: Bool { Self.reservedShortcuts.contains(self) }

    private static let reservedShortcuts: Set<HotkeyConfig> = {
        let cmd: CGEventFlags = .maskCommand
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        let cmdAlt: CGEventFlags = [.maskCommand, .maskAlternate]
        let ctrl: CGEventFlags = .maskControl
        return [
            HotkeyConfig(modifiers: cmd, keyCode: 0x08), // ⌘C
            HotkeyConfig(modifiers: cmd, keyCode: 0x09), // ⌘V
            HotkeyConfig(modifiers: cmd, keyCode: 0x07), // ⌘X
            HotkeyConfig(modifiers: cmd, keyCode: 0x06), // ⌘Z
            HotkeyConfig(modifiers: cmdShift, keyCode: 0x06), // ⌘⇧Z
            HotkeyConfig(modifiers: cmd, keyCode: 0x00), // ⌘A
            HotkeyConfig(modifiers: cmd, keyCode: 0x01), // ⌘S
            HotkeyConfig(modifiers: cmd, keyCode: 0x1F), // ⌘O
            HotkeyConfig(modifiers: cmd, keyCode: 0x2D), // ⌘N
            HotkeyConfig(modifiers: cmd, keyCode: 0x0D), // ⌘W
            HotkeyConfig(modifiers: cmd, keyCode: 0x0C), // ⌘Q
            HotkeyConfig(modifiers: cmd, keyCode: 0x23), // ⌘P
            HotkeyConfig(modifiers: cmd, keyCode: 0x03), // ⌘F
            HotkeyConfig(modifiers: cmd, keyCode: 0x11), // ⌘T
            HotkeyConfig(modifiers: cmdShift, keyCode: 0x11), // ⌘⇧T
            HotkeyConfig(modifiers: cmd, keyCode: 0x30), // ⌘Tab
            HotkeyConfig(modifiers: cmd, keyCode: 0x31), // ⌘Space
            HotkeyConfig(modifiers: cmd, keyCode: 0x04), // ⌘H
            HotkeyConfig(modifiers: cmd, keyCode: 0x2E), // ⌘M
            HotkeyConfig(modifiers: cmdAlt, keyCode: 0x35), // ⌘⌥Esc
            HotkeyConfig(modifiers: cmdShift, keyCode: 0x14), // ⌘⇧3
            HotkeyConfig(modifiers: cmdShift, keyCode: 0x15), // ⌘⇧4
            HotkeyConfig(modifiers: cmdShift, keyCode: 0x17), // ⌘⇧5
            HotkeyConfig(modifiers: ctrl, keyCode: 0x31), // ⌃Space
        ]
    }()
}
