import CoreGraphics
import Foundation
import Observation

enum HotkeyFeature: String, Codable, CaseIterable, Equatable {
    case voiceTrigger
    case clipboardPanel
    case vaultPanel
    case settingsWindow
    case screenshot

    var displayName: String {
        switch self {
        case .voiceTrigger: return String(localized: "Voice trigger")
        case .clipboardPanel: return String(localized: "Clipboard panel")
        case .vaultPanel: return String(localized: "Vault panel")
        case .settingsWindow: return String(localized: "Settings window")
        case .screenshot: return String(localized: "Screenshot")
        }
    }

    static let defaults: [String: String] = [
        HotkeyFeature.voiceTrigger.rawValue: "fn",                  // Press and hold to start voice input.
        HotkeyFeature.clipboardPanel.rawValue: "alt+v",             // Open the clipboard history panel.
        HotkeyFeature.vaultPanel.rawValue: "alt+b",                 // Open the Vault panel.
        HotkeyFeature.settingsWindow.rawValue: "cmd+shift+,",       // Open the Settings window.
        HotkeyFeature.screenshot.rawValue: "ctrl+alt+a",            // Open screenshot selection and annotation.
    ]
}

extension HotkeyFeature {
    var registryOwner: HotkeyRegistry.Owner {
        switch self {
        case .voiceTrigger: return .voiceTrigger
        case .clipboardPanel: return .clipboardPanel
        case .vaultPanel: return .vaultPanel
        case .settingsWindow: return .settingsWindow
        case .screenshot: return .screenshot
        }
    }
}

extension HotkeyFeature {
    /// Dispersed per-module UserDefaults key. Synced by the module's own
    /// SyncSection (see SyncSection.userDefaultsKeys). Absent = default.
    var userDefaultsKey: String {
        switch self {
        case .voiceTrigger: return "voiceTriggerHotkey"
        case .clipboardPanel: return "clipboardPanelHotkey"
        case .vaultPanel: return "vaultPanelHotkey"
        case .settingsWindow: return "settingsWindowHotkey"
        case .screenshot: return "screenshotHotkey"
        }
    }
}

@Observable
final class HotkeySettingsStore {
    static let shared = HotkeySettingsStore()
    static let migratedFlagKey = "hotkeyStorageMigrated.v2"
    private static let legacyBlobKey = "hotkeySettings.v1"
    private static let legacyVoiceTriggerKey = "voiceTriggerKey"

    struct ValidationError: Error, Equatable {
        let message: String
    }

    /// Customized feature hotkeys only (feature rawValue → encoded string).
    /// Defaults are never stored — absent = HotkeyFeature.defaults.
    private(set) var featureHotkeys: [String: String]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registry: HotkeyRegistry

    init(defaults: UserDefaults = .standard, registry: HotkeyRegistry = .shared) {
        self.defaults = defaults
        self.registry = registry
        self.featureHotkeys = Self.load(defaults: defaults)
        registerAll()
    }

    /// Kept for AppDelegate call-site compatibility; construction is eager now.
    func ensureInitialized() {}

    /// Re-read dispersed keys (Config Sync download rewrote UserDefaults).
    func reload() {
        featureHotkeys = Self.load(defaults: defaults)
        registerAll()
    }

    func rawHotkey(for feature: HotkeyFeature) -> String {
        featureHotkeys[feature.rawValue] ?? HotkeyFeature.defaults[feature.rawValue]!
    }

    func hotkey(for feature: HotkeyFeature) -> HotkeyConfig? {
        HotkeyConfig.parse(rawHotkey(for: feature))
    }

    func setHotkey(_ config: HotkeyConfig, for feature: HotkeyFeature) throws {
        try assign(config, raw: config.encode(), feature: feature)
    }

    func resetHotkey(for feature: HotkeyFeature) throws {
        let raw = HotkeyFeature.defaults[feature.rawValue]!
        try assign(HotkeyConfig.parse(raw)!, raw: raw, feature: feature)
    }

    func validationMessage(for config: HotkeyConfig, owner: Owner) -> String? {
        do {
            try Self.validateStored(config, owner: owner)
        } catch let error as ValidationError {
            return error.message
        } catch {
            return error.localizedDescription
        }
        let excluding: HotkeyRegistry.Owner
        switch owner {
        case .feature(let f): excluding = f.registryOwner
        case .persona(let id): excluding = .persona(id: id)
        }
        // Persona-vs-persona conflicts resolve by kick-out at commit time — never block them.
        let conflicts = registry.conflicts(for: config, excluding: excluding)
            .filter { entry in
                if case .persona = owner, case .persona = entry.owner { return false }
                return true
            }
        return conflicts.first.map { String(localized: "Conflicts with: \($0.purpose)") }
    }

    enum Owner: Equatable {
        case feature(HotkeyFeature)
        case persona(String)
    }

    // MARK: - Private

    private func assign(_ config: HotkeyConfig, raw: String, feature: HotkeyFeature) throws {
        try Self.validateStored(config, owner: .feature(feature))
        if let msg = validationMessage(for: config, owner: .feature(feature)) {
            throw ValidationError(message: msg)
        }
        if raw == HotkeyFeature.defaults[feature.rawValue] {
            featureHotkeys.removeValue(forKey: feature.rawValue)
            defaults.removeObject(forKey: feature.userDefaultsKey)
        } else {
            featureHotkeys[feature.rawValue] = raw
            defaults.set(raw, forKey: feature.userDefaultsKey)
        }
        registry.register(config, owner: feature.registryOwner, purpose: feature.displayName)
    }

    private func registerAll() {
        for feature in HotkeyFeature.allCases {
            if let cfg = hotkey(for: feature) {
                registry.register(cfg, owner: feature.registryOwner, purpose: feature.displayName)
            }
        }
    }

    private static func load(defaults: UserDefaults) -> [String: String] {
        var out: [String: String] = [:]
        for feature in HotkeyFeature.allCases {
            guard let raw = defaults.string(forKey: feature.userDefaultsKey),
                  let config = HotkeyConfig.parse(raw),
                  (try? validateStored(config, owner: .feature(feature))) != nil,
                  raw != HotkeyFeature.defaults[feature.rawValue]
            else { continue }
            out[feature.rawValue] = raw
        }
        return out
    }

    static func validateStored(_ config: HotkeyConfig, owner: Owner) throws {
        switch owner {
        case .feature(.voiceTrigger):
            if !config.isPureModifier {
                throw ValidationError(message: String(localized: "Use a modifier key for voice trigger"))
            }
        case .feature, .persona:
            if config.isPureModifier {
                throw ValidationError(message: String(localized: "Need a key, not just modifiers"))
            }
            if config.modifiers.isEmpty, !HotkeyConfig.functionRowKeyCodes.contains(config.keyCode) {
                throw ValidationError(message: String(localized: "Need at least one modifier"))
            }
        }

        if config.isSystemReserved {
            throw ValidationError(message: String(localized: "\(config.displayString()) is reserved by macOS"))
        }
    }

    // MARK: - Migration

    /// One-time migration from the hotkeySettings.v1 blob (and the even older
    /// voiceTriggerKey). The blob's personaHotkeys are authoritative over any
    /// stale Persona.hotkey value. Old keys are left on disk, never read again.
    static func migrateIfNeeded(defaults: UserDefaults, personaStore: PersonaStore) {
        guard !defaults.bool(forKey: migratedFlagKey) else { return }
        defer { defaults.set(true, forKey: migratedFlagKey) }

        if let data = defaults.data(forKey: legacyBlobKey),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let featureHotkeys = obj["featureHotkeys"] as? [String: String] ?? [:]
            for feature in HotkeyFeature.allCases {
                guard let raw = featureHotkeys[feature.rawValue],
                      raw != HotkeyFeature.defaults[feature.rawValue],
                      let config = HotkeyConfig.parse(raw),
                      (try? validateStored(config, owner: .feature(feature))) != nil
                else { continue }
                defaults.set(raw, forKey: feature.userDefaultsKey)
            }
            let personaHotkeys = obj["personaHotkeys"] as? [String: String] ?? [:]
            for (personaId, raw) in personaHotkeys where HotkeyConfig.parse(raw) != nil {
                personaStore.setHotkey(raw, personaId: personaId)
            }
        } else if let legacy = defaults.string(forKey: legacyVoiceTriggerKey),
                  let config = HotkeyConfig.parse(legacy),
                  config.isPureModifier,
                  legacy != HotkeyFeature.defaults[HotkeyFeature.voiceTrigger.rawValue] {
            defaults.set(legacy, forKey: HotkeyFeature.voiceTrigger.userDefaultsKey)
        }
    }
}
