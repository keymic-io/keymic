import Foundation

/// Where a section reads and writes its live values. Injected so tests can use
/// a scratch `UserDefaults` suite and a temp personas file.
struct SyncEnvironment {
    var defaults: UserDefaults
    var personasFileURL: URL

    static var live: SyncEnvironment {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyMic", isDirectory: true)
        return SyncEnvironment(
            defaults: .standard,
            personasFileURL: appSupport.appendingPathComponent("personas.json")
        )
    }
}

/// The eight synchronizable configuration sections. Raw values are the stable
/// keys shared with the backend (`/api/desktop/config`) — do NOT rename.
enum SyncSection: String, CaseIterable {
    case general
    case voice
    case llm
    case personas
    case hotkeys
    case keyMapping
    case clipboard
    case screenshot

    /// Current section payload schema version. Bump when a key's meaning changes.
    static let payloadVersion = 1

    /// UserDefaults keys this section owns. Empty for `personas` (file-backed).
    /// NOTE: `llm` deliberately omits `llmAPIKey` — the API key never syncs.
    var userDefaultsKeys: [String] {
        switch self {
        case .general:
            return ["automaticallyUpdates", "settingsWindowHotkey"]
        case .voice:
            return ["voiceEnabled", "selectedLocaleCode", "voiceModel",
                     "enableSelectionCopyFallback", "voiceTriggerHotkey"]
        case .llm:
            return ["llmAPIBaseURL", "llmModel"]
        case .clipboard:
            return ["clipboardEnabled", "clipboardMaxHistory", "clipboardIgnoreConfidential",
                    "clipboardPanelPosition", "clipboardCleanupMode", "clipboardCleanupDays",
                    "clipboardPanelHotkey", "vaultPanelHotkey"]
        case .screenshot:
            return ["screenshotEnabled", "screenshotHotkey"]
        case .hotkeys:
            return ["hotkeysEnabled", "hotkeyBindings"]
        case .keyMapping:
            return ["keyMappingEnabled", "keyMappingList"]
        case .personas:
            return []
        }
    }

    private static let personasField = "envelope"

    /// Read the section's current local state, overlaid onto `base` (the last
    /// payload seen from the server). Keys we own are refreshed from local
    /// state; unknown keys from `base` — written by a newer app version — are
    /// preserved untouched. A locally-unset owned key is removed (absent =
    /// default), never re-uploaded stale.
    func collectData(base: [String: JSONValue] = [:], env: SyncEnvironment) -> [String: JSONValue] {
        var out = base
        switch self {
        case .personas:
            if let data = try? Data(contentsOf: env.personasFileURL),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let jv = JSONValue.from(foundation: obj) {
                out[Self.personasField] = jv
            } else {
                out.removeValue(forKey: Self.personasField)
            }
        default:
            for key in userDefaultsKeys {
                if let raw = env.defaults.object(forKey: key), let jv = JSONValue.from(foundation: raw) {
                    out[key] = jv
                } else {
                    out.removeValue(forKey: key)
                }
            }
        }
        return out
    }

    /// Write a downloaded payload's data into local state. Owned keys present in
    /// `data` are set; owned keys absent from `data` are cleared (revert to
    /// default). Keys we don't own are ignored — never written blindly.
    func applyData(_ data: [String: JSONValue], env: SyncEnvironment) {
        switch self {
        case .personas:
            guard let env0 = data[Self.personasField] else { return }
            let obj = env0.foundationValue
            if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: env.personasFileURL, options: .atomic)
            }
        default:
            for key in userDefaultsKeys {
                if let jv = data[key] {
                    env.defaults.set(jv.foundationValue, forKey: key)
                } else {
                    env.defaults.removeObject(forKey: key)
                }
            }
        }
    }
}

/// How a section reconciles a 3-way (base/local/remote) difference.
enum MergePolicy {
    /// Whole-payload last-write-wins (scalar sections).
    case replace
    /// Item-level merge of the array at `path`, keyed by `idKey`; scalar
    /// siblings follow section-LWW.
    case mergeCollection(path: [String], idKey: String)
}

extension SyncSection {
    /// NOTE: hotkeys/keyMapping arrays live under `__json_data__` because their
    /// UserDefaults values are JSON-encoded `Data` blobs that
    /// `JSONValue.from(foundation:)` wraps; personas is file-backed and is not.
    var mergePolicy: MergePolicy {
        switch self {
        case .personas:   return .mergeCollection(path: ["envelope", "personas"], idKey: "id")
        case .hotkeys:    return .mergeCollection(path: ["hotkeyBindings", "__json_data__"], idKey: "id")
        case .keyMapping: return .mergeCollection(path: ["keyMappingList", "__json_data__"], idKey: "id")
        default:          return .replace
        }
    }

    /// Reconcile a section payload. `.replace` picks the newer side whole.
    /// `.mergeCollection` takes scalar fields from the newer side (`frame`) and
    /// item-merges the array at `path`. When every side lacks the collection
    /// path, the frame is returned untouched (never materialize an empty blob).
    func mergedPayload(base: [String: JSONValue], local: [String: JSONValue],
                       remote: [String: JSONValue], localNewer: Bool) -> [String: JSONValue] {
        switch mergePolicy {
        case .replace:
            return localNewer ? local : remote
        case let .mergeCollection(path, idKey):
            // Scalar fields follow section-LWW (newer side wins shared keys), but a
            // key only the other side has — e.g. an unknown field a newer client
            // added to the cloud — is unioned in so it is never dropped.
            var frame = localNewer ? local : remote
            let other = localNewer ? remote : local
            for (k, v) in other where frame[k] == nil { frame[k] = v }
            let b = jsonArrayIfPresent(at: path, in: base)
            let l = jsonArrayIfPresent(at: path, in: local)
            let r = jsonArrayIfPresent(at: path, in: remote)
            if b == nil, l == nil, r == nil { return frame }
            let items = mergeItemArrays(base: b ?? [], local: l ?? [], remote: r ?? [],
                                        idKey: idKey, localNewer: localNewer)
            return settingJSONArray(items, at: path, in: frame)
        }
    }
}

/// The wire shape stored per section on the backend: `{ "v": 1, "data": {...} }`.
struct SectionPayload: Codable, Equatable {
    var v: Int
    var data: [String: JSONValue]

    init(v: Int = SyncSection.payloadVersion, data: [String: JSONValue]) {
        self.v = v
        self.data = data
    }
}
