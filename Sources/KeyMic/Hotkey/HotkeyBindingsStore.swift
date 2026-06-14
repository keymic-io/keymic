import Foundation
import Observation
import os

@Observable
final class HotkeyBindingsStore {
    static let shared = HotkeyBindingsStore()
    static let userDefaultsKey = "hotkeyBindings"

    private static let logger = Logger(subsystem: "io.keymic.app", category: "HotkeyBindingsStore")

    var bindings: [HotkeyBinding] {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Guards against any save during init — a decode failure must never trigger an
    /// immediate write-back that overwrites the (possibly recoverable) data on disk.
    @ObservationIgnored private var isLoaded = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.load(from: defaults)
        self.isLoaded = true
    }

    private func save() {
        guard isLoaded else { return }
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
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
