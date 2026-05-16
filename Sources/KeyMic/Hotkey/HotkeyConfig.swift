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
        guard let keyCode = tokenToKeyCode[last] else { return nil }
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

    func matches(keyCode otherKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard !isPureModifier else { return false }
        guard otherKey == keyCode else { return false }
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        return flags.intersection(mask) == modifiers
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
