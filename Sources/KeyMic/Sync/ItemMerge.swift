import Foundation

// Pure, side-effect-free item-level 3-way merge for collection sync sections.
// See docs/superpowers/specs/2026-07-13-config-sync-merge-design.md.

/// The id string of a JSON item, or nil if it isn't an object with a string
/// `idKey`. Items without a usable id are dropped by the merge.
func itemId(_ item: JSONValue, idKey: String) -> String? {
    guard case let .object(obj) = item, case let .string(s)? = obj[idKey] else { return nil }
    return s
}

/// Align `base`/`local`/`remote` item arrays by `idKey` and reconcile per id.
/// `localNewer` is the section-level LWW verdict; it decides every genuine
/// conflict (both-edit, delete-vs-edit). Kept items are emitted in local order
/// first, then remote-only kept items in remote order. Items without a usable
/// id are dropped; duplicate ids collapse to the first occurrence.
func mergeItemArrays(base: [JSONValue], local: [JSONValue], remote: [JSONValue],
                     idKey: String, localNewer: Bool) -> [JSONValue] {
    func indexed(_ arr: [JSONValue]) -> [String: JSONValue] {
        var m: [String: JSONValue] = [:]
        for entry in arr { if let id = itemId(entry, idKey: idKey), m[id] == nil { m[id] = entry } }
        return m
    }
    let baseById = indexed(base)
    let localById = indexed(local)
    let remoteById = indexed(remote)

    var result: [JSONValue] = []
    var emitted = Set<String>()

    for entry in local {
        guard let id = itemId(entry, idKey: idKey), !emitted.contains(id) else { continue }
        emitted.insert(id)
        if let remoteItem = remoteById[id] {
            // Present on both sides.
            if entry == remoteItem {
                result.append(entry)                                 // identical
            } else {
                let baseItem = baseById[id]
                let localChanged = entry != baseItem                 // (baseItem == nil ⇒ changed)
                let remoteChanged = remoteItem != baseItem
                if localChanged && remoteChanged {
                    result.append(localNewer ? entry : remoteItem)   // genuine both-edit → LWW
                } else if localChanged {
                    result.append(entry)                             // only local changed
                } else {
                    result.append(remoteItem)                        // only remote changed
                }
            }
        } else if let baseItem = baseById[id] {
            // Remote deleted it.
            if entry == baseItem { /* local unchanged; honor deletion → drop */ }
            else if localNewer { result.append(entry) }              // delete-vs-edit, local wins
            // else honor remote deletion → drop
        } else {
            result.append(entry)                                     // local-only add
        }
    }

    for entry in remote {
        guard let id = itemId(entry, idKey: idKey), localById[id] == nil, !emitted.contains(id) else { continue }
        emitted.insert(id)
        // Local absent for this id.
        if let baseItem = baseById[id] {
            // Local deleted it.
            if entry == baseItem { continue }        // remote unchanged; honor deletion → drop
            if localNewer { continue }               // edit-vs-delete, local (delete) wins → drop
            result.append(entry)                     // edit-vs-delete, remote (edit) wins → take remote
        } else {
            result.append(entry)                     // remote-only add
        }
    }
    return result
}

/// The JSON array at `path` inside an object payload, or nil if the path is
/// missing or the terminal value is not an array. Distinguishes an absent
/// collection from a present-but-empty one.
func jsonArrayIfPresent(at path: [String], in payload: [String: JSONValue]) -> [JSONValue]? {
    var current: JSONValue = .object(payload)
    for key in path {
        guard case let .object(obj) = current, let next = obj[key] else { return nil }
        current = next
    }
    if case let .array(a) = current { return a }
    return nil
}

/// The JSON array at `path`, or [] if missing/not-array (convenience).
func jsonArray(at path: [String], in payload: [String: JSONValue]) -> [JSONValue] {
    jsonArrayIfPresent(at: path, in: payload) ?? []
}

/// A copy of `payload` with the array at `path` replaced by `array`, creating
/// intermediate objects as needed and preserving sibling keys.
func settingJSONArray(_ array: [JSONValue], at path: [String],
                      in payload: [String: JSONValue]) -> [String: JSONValue] {
    guard let first = path.first else { return payload }
    var out = payload
    if path.count == 1 {
        out[first] = .array(array)
        return out
    }
    var inner: [String: JSONValue] = [:]
    if case let .object(o)? = out[first] { inner = o }
    out[first] = .object(settingJSONArray(array, at: Array(path.dropFirst()), in: inner))
    return out
}
