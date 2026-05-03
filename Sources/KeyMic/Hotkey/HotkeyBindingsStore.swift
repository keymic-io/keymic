import Foundation
import Observation

@Observable
final class HotkeyBindingsStore {
    static let shared = HotkeyBindingsStore()
    static let userDefaultsKey = "hotkeyBindings"

    var bindings: [HotkeyBinding] {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.load(from: defaults)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [HotkeyBinding] {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([HotkeyBinding].self, from: data)) ?? []
    }
}
