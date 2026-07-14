import Foundation
import Observation
import os

@Observable
final class HotkeyBindingsStore {
    static let shared = HotkeyBindingsStore()
    static let userDefaultsKey = "hotkeyBindings"

    private static let logger = Logger(subsystem: "io.keymic.app", category: "HotkeyBindingsStore")

    var bindings: [HotkeyBinding] {
        didSet {
            save()
            syncRegistry()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registry: HotkeyRegistry
    /// Guards against any save during init — a decode failure must never trigger an
    /// immediate write-back that overwrites the (possibly recoverable) data on disk.
    @ObservationIgnored private var isLoaded = false

    init(defaults: UserDefaults = .standard, registry: HotkeyRegistry = .shared) {
        self.defaults = defaults
        self.registry = registry
        self.bindings = Self.load(from: defaults)
        self.isLoaded = true
        syncRegistry()
    }

    /// Re-read from defaults (Config Sync download rewrote the key) and re-sync.
    func reload() {
        isLoaded = false
        bindings = Self.load(from: defaults)
        isLoaded = true
        syncRegistry()
    }

    private func save() {
        guard isLoaded else { return }
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }

    private func syncRegistry() {
        for entry in registry.all() {
            if case .hotkeyBinding = entry.owner { registry.unregister(owner: entry.owner) }
        }
        for binding in bindings where binding.enabled {
            guard let cfg = HotkeyConfig.parse(binding.trigger) else { continue }
            registry.register(cfg, owner: .hotkeyBinding(id: binding.id),
                              purpose: String(localized: "Shortcut: \(cfg.displayString())"))
        }
    }

    /// Wrapper that swallows per-element decode failures, so one corrupt record (or a
    /// binding written by a newer version with an unknown HotkeyAction case) doesn't
    /// wipe every other binding. Mirrors HotkeySettingsStore's per-entry tolerance.
    private struct FailableBinding: Decodable {
        let value: HotkeyBinding?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(HotkeyBinding.self)
        }
    }

    private static func load(from defaults: UserDefaults) -> [HotkeyBinding] {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([FailableBinding].self, from: data)
            let bindings = decoded.compactMap(\.value)
            if bindings.count != decoded.count {
                logger.error("skipped \(decoded.count - bindings.count) undecodable hotkey bindings (kept \(bindings.count))")
            }
            return bindings
        } catch {
            logger.error("failed to decode persisted bindings: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
