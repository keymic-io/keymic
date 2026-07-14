import CoreGraphics
import Foundation

/// Global ledger of hotkey ownership across KeyMic subsystems.
/// Used by recording UIs to flag internal conflicts before the user commits a binding.
/// Does NOT dispatch events — KeyMonitor remains the single dispatcher.
final class HotkeyRegistry {
    static let shared = HotkeyRegistry()
    init() {}

    enum Owner: Hashable {
        case voiceTrigger
        case clipboardPanel
        case vaultPanel
        case settingsWindow
        case screenshot
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
        _ = lock.withLock { entries.removeValue(forKey: owner) }
    }

    /// All entries that conflict with this config, optionally excluding one owner.
    /// keyMapping entries match on keyCode alone: KeyMonitor runs remapIfNeeded
    /// before hotkey dispatch, so a remapped source key swallows every combo
    /// built on that key. All other owners require an exact config match.
    func conflicts(for config: HotkeyConfig, excluding: Owner?) -> [Entry] {
        lock.withLock {
            entries.values.filter { entry in
                guard entry.owner != excluding else { return false }
                if case .keyMapping = entry.owner {
                    return entry.config.keyCode == config.keyCode
                }
                return entry.config == config
            }
        }
    }

    /// Every entry whose trigger uses this keyCode at all (any modifiers).
    /// Used by the key-mapping editor: remapping a source key disables all of these.
    func entriesUsing(keyCode: CGKeyCode, excluding: Owner?) -> [Entry] {
        lock.withLock {
            entries.values.filter { $0.owner != excluding && $0.config.keyCode == keyCode }
        }
    }

    func all() -> [Entry] {
        lock.withLock { Array(entries.values) }
    }
}
