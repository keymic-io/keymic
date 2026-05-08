import Foundation

/// Global ledger of hotkey ownership across KeyMic subsystems.
/// Used by recording UIs to flag internal conflicts before the user commits a binding.
/// Does NOT dispatch events — KeyMonitor remains the single dispatcher.
final class HotkeyRegistry {
    static let shared = HotkeyRegistry()

    enum Owner: Hashable {
        case voiceTrigger
        case clipboardPanel
        case keyMapping(id: String)
        case hotkeyBinding(id: UUID)
        case persona(id: String)
    }

    struct Entry {
        let owner: Owner
        let purpose: String
        let config: HotkeyConfig
    }

    private var entries: [Owner: Entry] = [:]
    private let lock = NSLock()

    /// Register or replace this owner's hotkey.
    func register(_ config: HotkeyConfig, owner: Owner, purpose: String) {
        lock.withLock {
            entries[owner] = Entry(owner: owner, purpose: purpose, config: config)
        }
    }

    func unregister(owner: Owner) {
        lock.withLock { entries.removeValue(forKey: owner) }
    }

    /// All entries that match this config exactly, optionally excluding one owner
    /// (used by recording UI: "is anyone OTHER THAN the persona I'm editing using this?").
    func conflicts(for config: HotkeyConfig, excluding: Owner?) -> [Entry] {
        lock.withLock {
            entries.values.filter { entry in
                entry.config == config && entry.owner != excluding
            }
        }
    }

    func all() -> [Entry] {
        lock.withLock { Array(entries.values) }
    }
}
