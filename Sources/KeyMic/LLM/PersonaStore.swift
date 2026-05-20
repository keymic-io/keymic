import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "PersonaStore")

/// JSON-backed store for personas. Singleton in production via `PersonaStore.shared`;
/// inject a custom `storeURL` in tests.
final class PersonaStore {
    static let shared: PersonaStore = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
            .appendingPathComponent("KeyMic", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return PersonaStore(storeURL: appSupport.appendingPathComponent("personas.json"))
    }()

    /// Posted whenever the persona list or active id changes. No userInfo.
    static let didChangeNotification = Notification.Name("io.keymic.app.PersonaStore.didChange")

    private var personas: [Persona] = []
    private(set) var activePersonaId: String?

    private let storeURL: URL

    init(storeURL: URL) {
        self.storeURL = storeURL
        load()
    }

    var activePersona: Persona? {
        guard let id = activePersonaId else { return nil }
        return persona(id: id)
    }

    /// All personas with `hidden == false`. Single source of truth for every
    /// UI surface (settings list, menu bar, hotkey-conflict view) and runtime
    /// iteration (persona-hotkey dispatch, registry sync).
    var visiblePersonas: [Persona] { personas.filter { !$0.hidden } }

    /// Full underlying array including hidden personas. Escape hatch for
    /// legitimate internal needs (importer / audit / debugging). UI must NEVER use this.
    var allPersonas: [Persona] { personas }

    /// The seeded hidden persona for shortcut voice config. Nil only if the
    /// seed has been physically removed (shouldn't happen — mergeWithBuiltIns re-injects on load).
    var shortcutConfigPersona: Persona? { personas.first { $0.id == "builtin-shortcut-config" } }

    func persona(id: String) -> Persona? {
        personas.first { $0.id == id }
    }

    func setActive(_ id: String?) {
        if let id, let p = persona(id: id) {
            if p.hidden { return }   // silent reject; activePersonaId unchanged; no save
            guard activePersonaId != id else { return }
            activePersonaId = id
            save()
            return
        }
        // Avoid writing when already nil — every save() posts didChangeNotification
        // which triggers rebuildPersonasMenu + syncPersonaHotkeysToRegistry. The
        // togglePersona deselect flow + "Clear Default" button repeatedly hit this
        // path (WR-02 write-amplification fix).
        guard activePersonaId != nil else { return }
        activePersonaId = nil
        save()
    }

    func add(_ persona: Persona) {
        personas.append(persona)
        save()
    }

    func update(_ persona: Persona) {
        guard let idx = personas.firstIndex(where: { $0.id == persona.id }) else { return }
        var bumped = persona
        bumped.updatedAt = Date()
        personas[idx] = bumped
        save()
    }

    /// Deletes a custom persona. Built-in personas cannot be deleted.
    func delete(id: String) {
        guard let p = persona(id: id), !p.builtIn else { return }
        personas.removeAll { $0.id == id }
        if activePersonaId == id { activePersonaId = nil }
        save()
    }

    @discardableResult
    func duplicate(id: String) -> Persona? {
        // Reject hidden source personas. The current UI never reaches this path
        // (PersonasView only shows visiblePersonas), but the API is the choke
        // point — any future caller (Phase 6 shortcut-config UI, importer,
        // debug menu) must not be able to clone the hidden persona into a
        // visible custom copy (WR-03).
        guard let source = persona(id: id), !source.hidden else { return nil }
        let now = Date()
        let copy = Persona(
            id: "user-\(UUID().uuidString.prefix(8))",
            name: "\(source.name) Copy",
            icon: source.icon,
            stylePrompt: source.stylePrompt,
            temperature: source.temperature,
            hotkey: nil,    // never inherit hotkey — would conflict
            contextMode: source.contextMode,
            builtIn: false,
            createdAt: now,
            updatedAt: now
        )
        personas.append(copy)
        save()
        return copy
    }

    // MARK: - Persistence

    private struct Envelope: Codable {
        var version: Int
        var personas: [Persona]
        var activePersonaId: String?
    }

    private static let currentVersion = 1

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            seedFirstLaunch()
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let envelope = try Self.decoder.decode(Envelope.self, from: data)
            // Schema-version dispatcher (WR-06). Phase 01 added `hidden` additively
            // via decodeIfPresent ?? false, so currentVersion stayed at 1. Future
            // non-additive changes (or additive changes with a non-default default)
            // must bump currentVersion and add a case here. The clipboard subsystem
            // solved this with clipboardSchemaVersion + an explicit wipe path
            // (AppDelegate.swift:130-137); this mirrors that discipline for personas.
            switch envelope.version {
            case Self.currentVersion:
                break  // current — no migration
            case ..<Self.currentVersion:
                // No migrations yet — Phase 01 added `hidden` additively via
                // decodeIfPresent. Older envelopes flow through unchanged.
                break
            default:
                logger.error("envelope.version \(envelope.version) > currentVersion \(Self.currentVersion); reseeding")
                seedFirstLaunch()
                return
            }
            self.personas = mergeWithBuiltIns(loaded: envelope.personas)

            // D-E re-sync: hidden persona stylePrompt is built-in, not user data.
            // Overwrite the post-merge value with HiddenPersonaPrompt.text whenever
            // they differ. This ships Phase 6 prompt updates to existing installs
            // without requiring users to delete personas.json (Plan 06-02).
            //
            // Safe because the hidden persona is hidden: true + builtIn: true and
            // the UI never exposes it — users cannot have legitimately customized it.
            // The condition is the dirty-check; without it, every launch would
            // re-save the file even when in sync (write amplification — mirrors
            // the WR-02 pattern at setActive:62-65).
            if let idx = self.personas.firstIndex(where: { $0.id == "builtin-shortcut-config" }),
               self.personas[idx].stylePrompt != HiddenPersonaPrompt.text {
                self.personas[idx].stylePrompt = HiddenPersonaPrompt.text
                self.personas[idx].updatedAt = Date()
                // Persist immediately so the next launch's load() short-circuits the
                // != comparison. Idempotent + atomic; harmless if the active-id
                // sanity check below also fires its own save() in the same load.
                save()
            }

            self.activePersonaId = envelope.activePersonaId
            // Drop active id if the persona no longer exists OR is hidden.
            // Hidden personas must never be active — same invariant as setActive(_:).
            // Without this, a hand-edited or legacy personas.json with
            // activePersonaId = "builtin-shortcut-config" would silently leave the
            // hidden persona active on next launch, bypassing the setActive guard.
            if let id = activePersonaId,
               let p = persona(id: id), !p.hidden {
                // OK — visible persona, keep it.
            } else if activePersonaId != nil {
                activePersonaId = nil
                save()
            }
        } catch {
            logger.error("load failed: \(error.localizedDescription, privacy: .public). Re-seeding.")
            seedFirstLaunch()
        }
    }

    /// Ensures all 5 built-ins exist; restores immutable seed fields
    /// ({id, name, builtIn, hidden}) for any disk persona whose id matches a seed.
    /// User-editable fields (stylePrompt, icon, temperature, hotkey,
    /// contextMode, createdAt, updatedAt) from disk are preserved.
    /// Custom personas pass through unchanged.
    ///
    /// `name` is restored from seed because (a) the Persona.builtInSeeds()
    /// docstring promises name is immutable for built-ins, (b) PersonasView
    /// disables the name TextField for built-ins (UI honors the same invariant),
    /// and (c) a stable canonical name is a future localization key candidate —
    /// letting it drift via disk tampering would break a later String(localized:)
    /// lookup keyed on the seed name.
    private func mergeWithBuiltIns(loaded: [Persona]) -> [Persona] {
        let seeds = Persona.builtInSeeds()
        var result: [Persona] = []
        for seed in seeds {
            if let existing = loaded.first(where: { $0.id == seed.id }) {
                var merged = existing
                merged.id = seed.id            // identity guard (no-op on match, defensive)
                merged.name = seed.name        // immutable — restore from seed (CR-02)
                merged.builtIn = seed.builtIn  // immutable — restore from seed
                merged.hidden = seed.hidden    // immutable — restore from seed (PERS-07)
                result.append(merged)
            } else {
                result.append(seed)
            }
        }
        let builtInIds = Set(seeds.map(\.id))
        result.append(contentsOf: loaded.filter { !builtInIds.contains($0.id) })
        return result
    }

    private func seedFirstLaunch() {
        self.personas = Persona.builtInSeeds()
        self.activePersonaId = nil
        save()
    }

    private func save() {
        let envelope = Envelope(
            version: Self.currentVersion,
            personas: personas,
            activePersonaId: activePersonaId
        )
        do {
            let data = try Self.encoder.encode(envelope)
            try data.write(to: storeURL, options: .atomic)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        } catch {
            logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(formatter.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = formatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c,
                    debugDescription: "Invalid ISO8601 date: \(s)")
            }
            return date
        }
        return d
    }()
}
