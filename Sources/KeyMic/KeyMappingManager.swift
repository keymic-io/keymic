import CoreGraphics
import Foundation
import Observation

struct KeyMapping: Codable, Equatable, Identifiable {
    var id: UUID
    var fromKeyCode: CGKeyCode?
    var toKeyCode: CGKeyCode?
    var enabled: Bool

    init(
        id: UUID = UUID(),
        fromKeyCode: CGKeyCode? = nil,
        toKeyCode: CGKeyCode? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.fromKeyCode = fromKeyCode
        self.toKeyCode = toKeyCode
        self.enabled = enabled
    }

    var isComplete: Bool { fromKeyCode != nil && toKeyCode != nil }

    var fromFlag: CGEventFlags? { fromKeyCode.flatMap(Self.modifierFlag(for:)) }
    var toFlag: CGEventFlags? { toKeyCode.flatMap(Self.modifierFlag(for:)) }
    var fromName: String { fromKeyCode.map(Self.displayName(for:)) ?? "Click to record" }
    var toName: String { toKeyCode.map(Self.displayName(for:)) ?? "Click to record" }

    static func modifierFlag(for kc: CGKeyCode) -> CGEventFlags? {
        switch kc {
        case 0x36, 0x37: return .maskCommand
        case 0x38, 0x3C: return .maskShift
        case 0x3A, 0x3D: return .maskAlternate
        case 0x3B, 0x3E: return .maskControl
        case 0x39: return .maskAlphaShift
        case 0x3F: return .maskSecondaryFn
        default: return nil
        }
    }

    static func displayName(for kc: CGKeyCode) -> String {
        if let name = specialKeyNames[kc] { return name }
        return HotkeyConfig(modifiers: [], keyCode: kc).displayString()
    }

    private static let specialKeyNames: [CGKeyCode: String] = [
        0x75: "⌦ Forward Delete",
        0x73: "Home",
        0x77: "End",
        0x74: "Page Up",
        0x79: "Page Down",
        0x7B: "←",
        0x7C: "→",
        0x7D: "↓",
        0x7E: "↑",
    ]
}

@Observable
final class KeyMappingManager {
    static let shared = KeyMappingManager()

    var mappings: [KeyMapping] {
        didSet {
            guard oldValue != mappings else { return }
            save()
            applyHIDMappings()
        }
    }

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            userDefaults.set(isEnabled, forKey: Self.enabledKey)
            applyHIDMappings()
        }
    }

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private static let enabledKey = "keyMappingEnabled"
    @ObservationIgnored private static let mappingsKey = "keyMappingList"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.mappings = Self.loadOrSeed(from: userDefaults, key: Self.mappingsKey)
        self.isEnabled = userDefaults.object(forKey: Self.enabledKey) as? Bool ?? true
        applyHIDMappings()
    }

    func mapping(for sourceKeyCode: CGKeyCode) -> KeyMapping? {
        guard isEnabled else { return nil }
        return mappings.first { m in
            m.enabled && m.fromKeyCode == sourceKeyCode && m.toKeyCode != nil
        }
    }

    func targetKeyCode(for sourceKeyCode: CGKeyCode) -> CGKeyCode? {
        mapping(for: sourceKeyCode)?.toKeyCode
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        userDefaults.set(data, forKey: Self.mappingsKey)
    }

    /// Re-install HID-level mappings for the current state. `AppDelegate` calls this at
    /// launch *after* `HIDRemapper.reset()`: this singleton's init-time `apply` runs
    /// *before* that reset on HIDRemapper's shared serial queue, so without an explicit
    /// reapply the reset would be the last write and silently clobber Caps Lock-sourced
    /// mappings until the user toggles key mapping off/on.
    func reapplyHIDMappings() {
        applyHIDMappings()
    }

    private func applyHIDMappings() {
        HIDRemapper.apply(mappings, enabled: isEnabled)
    }

    private static func loadOrSeed(from defaults: UserDefaults, key: String) -> [KeyMapping] {
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([KeyMapping].self, from: data) {
            return list
        }
        let seeded = presets
        if let data = try? JSONEncoder().encode(seeded) {
            defaults.set(data, forKey: key)
        }
        return seeded
    }

    static let presets: [KeyMapping] = [
        KeyMapping(fromKeyCode: 0x36, toKeyCode: 0x75),  // Right ⌘ → Forward Delete
        KeyMapping(fromKeyCode: 0x3c, toKeyCode: 0x39),  // Right ⇧ → Caps Lock
        KeyMapping(fromKeyCode: 0x39, toKeyCode: 0x3b),  // Caps Lock → Left ⌃
    ]
}
