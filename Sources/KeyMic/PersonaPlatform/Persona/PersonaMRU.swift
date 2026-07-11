import Foundation

/// Tracks persona invocation recency so the voice picker can list
/// most-recently-used personas leftmost. Any invocation (voice picker or
/// persona hotkey) calls `record(_:)`. Persisted in UserDefaults.
final class PersonaMRU {
    static let shared = PersonaMRU()

    private let defaults: UserDefaults
    private let key = "personaInvocationHistory"
    /// Upper bound so the array cannot grow forever as personas are created/deleted.
    private let maxEntries = 50

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Most-recent-first list of persona ids.
    func historyIDs() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Move `id` to the front (most recent); dedupe; cap length.
    func record(_ id: String) {
        var ids = historyIDs()
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > maxEntries { ids = Array(ids.prefix(maxEntries)) }
        defaults.set(ids, forKey: key)
    }

    /// Personas ordered MRU-descending; personas never recorded keep their
    /// input order after the recorded ones.
    func ordered(_ personas: [Persona]) -> [Persona] {
        Self.order(personas: personas, history: historyIDs())
    }

    /// Pure ordering used by `ordered(_:)`; extracted for testing.
    static func order(personas: [Persona], history: [String]) -> [Persona] {
        let byID = Dictionary(personas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Persona] = []
        var seen = Set<String>()
        for id in history {
            if let p = byID[id], !seen.contains(id) {
                result.append(p); seen.insert(id)
            }
        }
        for p in personas where !seen.contains(p.id) {
            result.append(p); seen.insert(p.id)
        }
        return result
    }
}
