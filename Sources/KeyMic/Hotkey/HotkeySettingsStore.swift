import CoreGraphics
import Foundation
import Observation
import os.log

private let hotkeySettingsLogger = Logger(subsystem: "io.keymic.app", category: "HotkeySettings")

enum HotkeyFeature: String, Codable, CaseIterable, Equatable {
    case voiceTrigger
    case clipboardPanel
    case vaultPanel
    case settingsWindow
    case screenshot
    case selectedTextEditor

    var displayName: String {
        switch self {
        case .voiceTrigger: return String(localized: "Voice trigger")
        case .clipboardPanel: return String(localized: "Clipboard panel")
        case .vaultPanel: return String(localized: "Vault panel")
        case .settingsWindow: return String(localized: "Settings window")
        case .screenshot: return String(localized: "Screenshot")
        case .selectedTextEditor: return String(localized: "Selected text editor")
        }
    }

    static let defaults: [String: String] = [
        HotkeyFeature.voiceTrigger.rawValue: "fn",                  // Press and hold to start voice input.
        HotkeyFeature.clipboardPanel.rawValue: "alt+v",             // Open the clipboard history panel.
        HotkeyFeature.vaultPanel.rawValue: "alt+b",                 // Open the Vault panel.
        HotkeyFeature.settingsWindow.rawValue: "cmd+shift+,",       // Open the Settings window.
        HotkeyFeature.screenshot.rawValue: "cmd+shift+a",           // Open screenshot selection and annotation.
        HotkeyFeature.selectedTextEditor.rawValue: "alt+e",         // Open Selected Text Editor panel.
    ]
}

struct HotkeySettingsSnapshot: Codable, Equatable {
    var version: Int
    var featureHotkeys: [String: String]
    var personaHotkeys: [String: String]
}

@Observable
final class HotkeySettingsStore {
    static let shared = HotkeySettingsStore(personasProvider: { PersonaStore.shared.personas })
    static let userDefaultsKey = "hotkeySettings.v1"

    struct ValidationError: Error, Equatable {
        let message: String
    }

    private static let currentVersion = 1

    private(set) var snapshot: HotkeySettingsSnapshot {
        didSet { save(snapshot) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let personasProvider: () -> [Persona]

    init(
        defaults: UserDefaults = .standard,
        personasProvider: @escaping () -> [Persona]
    ) {
        self.defaults = defaults
        self.personasProvider = personasProvider
        self.snapshot = Self.loadOrCreate(defaults: defaults, personas: personasProvider())
    }

    func ensureInitialized() {
        _ = snapshot
    }

    func rawHotkey(for feature: HotkeyFeature) -> String {
        let raw = snapshot.featureHotkeys[feature.rawValue] ?? Self.defaultRawHotkey(for: feature)
        guard let config = HotkeyConfig.parse(raw), Self.isValidStored(config, owner: .feature(feature)) else {
            return Self.defaultRawHotkey(for: feature)
        }
        return raw
    }

    func hotkey(for feature: HotkeyFeature) -> HotkeyConfig? {
        HotkeyConfig.parse(rawHotkey(for: feature))
    }

    func setHotkey(_ config: HotkeyConfig, for feature: HotkeyFeature) throws {
        try assignFeature(config, raw: config.encode(), feature: feature)
    }

    func resetHotkey(for feature: HotkeyFeature) throws {
        let raw = Self.defaultRawHotkey(for: feature)
        try assignFeature(HotkeyConfig.parse(raw)!, raw: raw, feature: feature)
    }

    private func assignFeature(_ config: HotkeyConfig, raw: String, feature: HotkeyFeature) throws {
        let owner: Owner = .feature(feature)
        try Self.validateStored(config, owner: owner)
        try validateFeatureConflict(config, owner: owner)
        try validatePersonaConflict(config, owner: owner)
        var next = snapshot
        next.featureHotkeys[feature.rawValue] = raw
        snapshot = next
    }

    func rawPersonaHotkey(personaId: String) -> String? {
        guard let raw = snapshot.personaHotkeys[personaId],
              let config = HotkeyConfig.parse(raw),
              Self.isValidStored(config, owner: .persona(personaId)) else { return nil }
        return raw
    }

    func personaHotkey(personaId: String) -> HotkeyConfig? {
        rawPersonaHotkey(personaId: personaId).flatMap(HotkeyConfig.parse)
    }

    /// Persona-to-persona conflicts are resolved by kick-out policy: if another
    /// persona already binds `config`, its binding is silently cleared so the
    /// new persona can claim the hotkey. Feature conflicts still throw —
    /// recording over a feature requires the user to clear/reset the feature
    /// hotkey explicitly in feature settings.
    func setPersonaHotkey(_ config: HotkeyConfig?, personaId: String) throws {
        var next = snapshot
        if let config {
            try Self.validateStored(config, owner: .persona(personaId))
            try validateFeatureConflict(config, owner: .persona(personaId))
            for (otherId, raw) in snapshot.personaHotkeys
            where otherId != personaId && HotkeyConfig.parse(raw) == config {
                next.personaHotkeys.removeValue(forKey: otherId)
            }
            next.personaHotkeys[personaId] = config.encode()
        } else {
            next.personaHotkeys.removeValue(forKey: personaId)
        }
        snapshot = next
    }

    func validationMessage(for config: HotkeyConfig, owner: Owner) -> String? {
        do {
            try Self.validateStored(config, owner: owner)
            try validateFeatureConflict(config, owner: owner)
            if case .feature = owner {
                try validatePersonaConflict(config, owner: owner)
            }
            return nil
        } catch let error as ValidationError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    enum Owner: Equatable {
        case feature(HotkeyFeature)
        case persona(String)
    }

    private func validateFeatureConflict(_ config: HotkeyConfig, owner: Owner) throws {
        for feature in HotkeyFeature.allCases {
            guard owner != .feature(feature),
                  let existing = hotkey(for: feature),
                  existing == config else { continue }
            throw ValidationError(message: String(localized: "Conflicts with: \(feature.displayName)"))
        }
    }

    private func validatePersonaConflict(_ config: HotkeyConfig, owner: Owner) throws {
        for (personaId, raw) in snapshot.personaHotkeys {
            guard owner != .persona(personaId),
                  HotkeyConfig.parse(raw) == config else { continue }
            let name = personasProvider().first { $0.id == personaId }?.name ?? personaId
            throw ValidationError(message: String(localized: "Conflicts with: Persona: \(name)"))
        }
    }

    private static let legacyVoiceTriggerKey = "voiceTriggerKey"

    private static func loadOrCreate(defaults: UserDefaults, personas: [Persona]) -> HotkeySettingsSnapshot {
        if let data = defaults.data(forKey: userDefaultsKey) {
            if let decoded = try? JSONDecoder().decode(HotkeySettingsSnapshot.self, from: data) {
                return sanitize(decoded)
            }
            hotkeySettingsLogger.error("failed to decode persisted hotkey settings; rebuilding defaults")
        }

        var featureHotkeys = HotkeyFeature.defaults
        // Migrate legacy voice trigger setting so users upgrading from
        // pre-hotkeySettings.v1 builds keep their customized modifier.
        if let legacy = defaults.string(forKey: legacyVoiceTriggerKey),
           let config = HotkeyConfig.parse(legacy),
           isValidStored(config, owner: .feature(.voiceTrigger)) {
            featureHotkeys[HotkeyFeature.voiceTrigger.rawValue] = legacy
        }

        let created = HotkeySettingsSnapshot(
            version: currentVersion,
            featureHotkeys: featureHotkeys,
            personaHotkeys: Dictionary(
                uniqueKeysWithValues: personas.compactMap { persona in
                    guard let raw = persona.hotkey,
                          let config = HotkeyConfig.parse(raw),
                          isValidStored(config, owner: .persona(persona.id)) else { return nil }
                    return (persona.id, raw)
                }
            )
        )
        save(created, defaults: defaults)
        return created
    }

    private static func sanitize(_ snapshot: HotkeySettingsSnapshot) -> HotkeySettingsSnapshot {
        var featureHotkeys = HotkeyFeature.defaults
        for feature in HotkeyFeature.allCases {
            if let raw = snapshot.featureHotkeys[feature.rawValue],
               let config = HotkeyConfig.parse(raw),
               isValidStored(config, owner: .feature(feature)) {
                featureHotkeys[feature.rawValue] = raw
            }
        }
        let personaHotkeys = snapshot.personaHotkeys.filter { personaId, raw in
            guard let config = HotkeyConfig.parse(raw) else { return false }
            return isValidStored(config, owner: .persona(personaId))
        }
        return HotkeySettingsSnapshot(version: currentVersion, featureHotkeys: featureHotkeys, personaHotkeys: personaHotkeys)
    }

    private static func isValidStored(_ config: HotkeyConfig, owner: Owner) -> Bool {
        (try? validateStored(config, owner: owner)) != nil
    }

    private static func validateStored(_ config: HotkeyConfig, owner: Owner) throws {
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

    private static func defaultRawHotkey(for feature: HotkeyFeature) -> String {
        HotkeyFeature.defaults[feature.rawValue]!
    }

    private func save(_ snapshot: HotkeySettingsSnapshot) {
        Self.save(snapshot, defaults: defaults)
    }

    private static func save(_ snapshot: HotkeySettingsSnapshot, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            hotkeySettingsLogger.error("failed to encode hotkey settings")
            return
        }
        defaults.set(data, forKey: userDefaultsKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }
}
