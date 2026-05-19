import Foundation

enum HotkeyAction: Equatable {
    case typeText(String)
    case keyPress(keyCode: UInt16, modifiers: UInt64)
    case wait(ms: Int)
    case shell(String)
}

extension HotkeyAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, keyCode, modifiers, ms, command
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .typeText(let s):
            try c.encode("typeText", forKey: .type)
            try c.encode(s, forKey: .text)
        case .keyPress(let kc, let mods):
            try c.encode("keyPress", forKey: .type)
            try c.encode(kc, forKey: .keyCode)
            try c.encode(mods, forKey: .modifiers)
        case .wait(let ms):
            try c.encode("wait", forKey: .type)
            try c.encode(ms, forKey: .ms)
        case .shell(let cmd):
            try c.encode("shell", forKey: .type)
            try c.encode(cmd, forKey: .command)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "typeText":
            self = .typeText(try c.decode(String.self, forKey: .text))
        case "keyPress":
            self = .keyPress(
                keyCode: try c.decode(UInt16.self, forKey: .keyCode),
                modifiers: try c.decode(UInt64.self, forKey: .modifiers)
            )
        case "wait":
            self = .wait(ms: try c.decode(Int.self, forKey: .ms))
        case "shell":
            self = .shell(try c.decode(String.self, forKey: .command))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown HotkeyAction type: \(type)"
            )
        }
    }
}

struct HotkeyBinding: Codable, Equatable, Identifiable {
    var id: UUID
    var trigger: String
    var actions: [HotkeyAction]
    var enabled: Bool
    /// Bundle IDs the binding applies to. Empty means global (all apps).
    var appBundleIDs: [String]
    /// Origin marker. `"voice"` for voice imports; nil for manual / pre-Phase-3 origin
    /// (per .planning/phases/03-importer-audit-log-safety-gates/03-CONTEXT.md D-A-1).
    var createdBy: String?
    /// Phase 2 `ParsedShortcut.label` persisted alongside the binding for UI display
    /// (per .planning/phases/03-importer-audit-log-safety-gates/03-CONTEXT.md D-A-4).
    var label: String?

    init(
        id: UUID = UUID(),
        trigger: String,
        actions: [HotkeyAction],
        enabled: Bool = true,
        appBundleIDs: [String] = [],
        createdBy: String? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.actions = actions
        self.enabled = enabled
        self.appBundleIDs = appBundleIDs
        self.createdBy = createdBy
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case id, trigger, actions, enabled, appBundleIDs, createdBy, label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.trigger = try c.decode(String.self, forKey: .trigger)
        self.actions = try c.decode([HotkeyAction].self, forKey: .actions)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.appBundleIDs = try c.decodeIfPresent([String].self, forKey: .appBundleIDs) ?? []
        self.createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
    }
}
