import Foundation

/// Per-section sync bookkeeping. Persisted to UserDefaults under `sync.state.v1`.
struct SectionState: Codable, Equatable {
    /// Local wall-clock of the last local edit to this section (the LWW key we upload).
    var localModifiedAt: Date?
    /// Server revision this device last observed/matched. Guards against re-upload echo.
    var serverRevision: Int?
    /// Last payload data seen from the server — the base onto which `collectData`
    /// overlays known keys so unknown (newer-version) fields survive.
    var lastRemoteData: [String: JSONValue]?
}

struct SyncStateSnapshot: Codable, Equatable {
    var version: Int = 1
    var sections: [String: SectionState] = [:]
}

/// Owns per-section sync state plus the enabled-section set and master toggle.
/// Also routes UserDefaults key changes to the section they belong to and gates
/// dirty-marking while a remote apply is in progress (echo guard).
final class SyncStateStore {
    static let masterEnabledKey = "sync.enabled"
    static let enabledSectionsKey = "sync.enabledSections.v1"
    static let stateKey = "sync.state.v1"

    private let defaults: UserDefaults
    private let now: () -> Date
    private(set) var snapshot: SyncStateSnapshot

    /// Set true around `SyncEngine.apply`; suppresses dirty-marking so an applied
    /// remote value is never re-uploaded as a local edit.
    var isApplyingRemote = false

    /// Reverse index: UserDefaults key → owning section.
    private static let keyToSection: [String: SyncSection] = {
        var map: [String: SyncSection] = [:]
        for section in SyncSection.allCases {
            for key in section.userDefaultsKeys { map[key] = section }
        }
        return map
    }()

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.stateKey),
           let decoded = try? JSONDecoder().decode(SyncStateSnapshot.self, from: data) {
            self.snapshot = decoded
        } else {
            self.snapshot = SyncStateSnapshot()
        }
    }

    // MARK: - Section-of-key routing

    static func section(forDefaultsKey key: String) -> SyncSection? { keyToSection[key] }

    // MARK: - Dirty marking

    /// Mark a section locally edited (bumps its localModifiedAt). No-op while a
    /// remote apply is in progress.
    func markDirty(_ section: SyncSection) {
        guard !isApplyingRemote else { return }
        var s = snapshot.sections[section.rawValue] ?? SectionState()
        s.localModifiedAt = now()
        snapshot.sections[section.rawValue] = s
        persist()
    }

    /// Route a changed UserDefaults key to its section and mark it dirty.
    /// Returns the section if the key was owned by one.
    @discardableResult
    func noteDefaultsKeyChanged(_ key: String) -> SyncSection? {
        guard let section = Self.section(forDefaultsKey: key) else { return nil }
        markDirty(section)
        return section
    }

    // MARK: - Post-apply / post-upload bookkeeping

    /// Record that we now hold the server's version of a section (after download
    /// or an accepted upload). Clears local dirtiness relative to that revision.
    func recordSynced(_ section: SyncSection, remoteData: [String: JSONValue], revision: Int, modifiedAt: Date) {
        var s = snapshot.sections[section.rawValue] ?? SectionState()
        s.serverRevision = revision
        s.lastRemoteData = remoteData
        s.localModifiedAt = modifiedAt
        snapshot.sections[section.rawValue] = s
        persist()
    }

    func state(for section: SyncSection) -> SectionState { snapshot.sections[section.rawValue] ?? SectionState() }

    /// Reset all per-section revision/remote caches (used on sign-out or master
    /// toggle off) so re-enabling runs the first-enable bootstrap again.
    func reset() {
        snapshot = SyncStateSnapshot()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }
}
