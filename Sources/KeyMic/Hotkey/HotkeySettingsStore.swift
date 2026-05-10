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
        case .voiceTrigger: return "Voice trigger"
        case .clipboardPanel: return "Clipboard panel"
        case .vaultPanel: return "Vault panel"
        case .settingsWindow: return "Settings window"
        case .screenshot: return "Screenshot"
        }
    }

    static let defaults: [String: String] = [
        HotkeyFeature.voiceTrigger.rawValue: "fn",                  // Press and hold to start voice input.
        HotkeyFeature.clipboardPanel.rawValue: "alt+v",             // Open the clipboard history panel.
        HotkeyFeature.vaultPanel.rawValue: "alt+b",                 // Open the Vault panel.
        HotkeyFeature.settingsWindow.rawValue: "cmd+shift+comma",   // Open the Settings window.
        HotkeyFeature.screenshot.rawValue: "cmd+shift+a",           // Open screenshot selection and annotation.
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
        guard HotkeyConfig.parse(raw) != nil else { return Self.defaultRawHotkey(for: feature) }
        return raw
    }

    func hotkey(for feature: HotkeyFeature) -> HotkeyConfig? {
        HotkeyConfig.parse(rawHotkey(for: feature))
    }

    func setHotkey(_ config: HotkeyConfig, for feature: HotkeyFeature) throws {
        try validate(config, owner: .feature(feature))
        var next = snapshot
        next.featureHotkeys[feature.rawValue] = config.encode()
        snapshot = next
    }

    func resetHotkey(for feature: HotkeyFeature) {
        var next = snapshot
        next.featureHotkeys[feature.rawValue] = Self.defaultRawHotkey(for: feature)
        snapshot = next
    }

    func rawPersonaHotkey(personaId: String) -> String? {
        guard let raw = snapshot.personaHotkeys[personaId], HotkeyConfig.parse(raw) != nil else { return nil }
        return raw
    }

    func personaHotkey(personaId: String) -> HotkeyConfig? {
        rawPersonaHotkey(personaId: personaId).flatMap(HotkeyConfig.parse)
    }

    func setPersonaHotkey(_ config: HotkeyConfig?, personaId: String) throws {
        if let config {
            try validate(config, owner: .persona(personaId))
        }
        var next = snapshot
        if let config {
            next.personaHotkeys[personaId] = config.encode()
        } else {
            next.personaHotkeys.removeValue(forKey: personaId)
        }
        snapshot = next
    }

    func validationMessage(for config: HotkeyConfig, owner: Owner) -> String? {
        do {
            try validate(config, owner: owner)
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

    private func validate(_ config: HotkeyConfig, owner: Owner) throws {
        if config.isSystemReserved {
            throw ValidationError(message: "\(config.displayString()) is reserved by macOS")
        }

        for feature in HotkeyFeature.allCases {
            guard owner != .feature(feature), let existing = hotkey(for: feature), existing == config else { continue }
            throw ValidationError(message: "Conflicts with: \(feature.displayName)")
        }

        for (personaId, raw) in snapshot.personaHotkeys {
            guard owner != .persona(personaId), HotkeyConfig.parse(raw) == config else { continue }
            let name = personasProvider().first { $0.id == personaId }?.name ?? personaId
            throw ValidationError(message: "Conflicts with: Persona: \(name)")
        }
    }

    private static func loadOrCreate(defaults: UserDefaults, personas: [Persona]) -> HotkeySettingsSnapshot {
        if let data = defaults.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(HotkeySettingsSnapshot.self, from: data) {
            return sanitize(decoded)
        }

        if defaults.data(forKey: userDefaultsKey) != nil {
            hotkeySettingsLogger.error("failed to decode persisted hotkey settings; rebuilding defaults")
        }

        let created = HotkeySettingsSnapshot(
            version: currentVersion,
            featureHotkeys: HotkeyFeature.defaults,
            personaHotkeys: Dictionary(
                uniqueKeysWithValues: personas.compactMap { persona in
                    guard let raw = persona.hotkey, HotkeyConfig.parse(raw) != nil else { return nil }
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
            if let raw = snapshot.featureHotkeys[feature.rawValue], HotkeyConfig.parse(raw) != nil {
                featureHotkeys[feature.rawValue] = raw
            }
        }
        let personaHotkeys = snapshot.personaHotkeys.filter { HotkeyConfig.parse($0.value) != nil }
        return HotkeySettingsSnapshot(version: currentVersion, featureHotkeys: featureHotkeys, personaHotkeys: personaHotkeys)
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
