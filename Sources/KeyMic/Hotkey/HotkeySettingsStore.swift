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

    /// Re-read the snapshot from persistence (e.g. after Config Sync overwrote
    /// `hotkeySettings.v1`). Observers refresh via the resulting change.
    func reload() {
        snapshot = Self.loadOrCreate(defaults: defaults, personas: personasProvider())
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
        try Self.validateStored(config, owner: .feature(feature))
        if let msg = validationMessage(for: config, owner: .feature(feature)) {
            throw ValidationError(message: msg)
        }
        var next = snapshot
        next.featureHotkeys[feature.rawValue] = raw
        snapshot = next
        HotkeyRegistry.shared.register(config, owner: feature.registryOwner, purpose: feature.displayName)
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
        let conflicts = HotkeyRegistry.shared.conflicts(for: config, excluding: excluding)
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
            personaHotkeys: [:]
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
        return HotkeySettingsSnapshot(version: currentVersion, featureHotkeys: featureHotkeys, personaHotkeys: [:])
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
        // `defaults.set` itself posts UserDefaults.didChangeNotification; do NOT
        // post it manually here or every observer (menu sync, KeyMonitor reload,
        // clipboard prefs, updater policy) runs twice per save.
        defaults.set(data, forKey: userDefaultsKey)
    }
}
