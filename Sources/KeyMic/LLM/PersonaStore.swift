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

    private(set) var personas: [Persona] = []
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

    func persona(id: String) -> Persona? {
        personas.first { $0.id == id }
    }

    func persona(forHotkey hotkey: String) -> Persona? {
        personas.first { $0.hotkey == hotkey }
    }

    func setActive(_ id: String?) {
        if let id, persona(id: id) == nil {
            activePersonaId = nil
        } else {
            activePersonaId = id
        }
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
        guard let source = persona(id: id) else { return nil }
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
            self.personas = mergeWithBuiltIns(loaded: envelope.personas)
            self.activePersonaId = envelope.activePersonaId
            // If active id no longer exists, drop it.
            if let id = activePersonaId, persona(id: id) == nil {
                activePersonaId = nil
                save()
            }
        } catch {
            logger.error("load failed: \(error.localizedDescription, privacy: .public). Re-seeding.")
            seedFirstLaunch()
        }
    }

    /// Ensures all 4 built-ins exist (preserves user edits to existing built-ins;
    /// adds any built-in seed not yet on disk). Custom personas pass through unchanged.
    private func mergeWithBuiltIns(loaded: [Persona]) -> [Persona] {
        let seeds = Persona.builtInSeeds()
        var result: [Persona] = []
        for seed in seeds {
            if let existing = loaded.first(where: { $0.id == seed.id }) {
                result.append(existing)
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
        // First launch: default persona is active (preserves current LLM-refiner UX).
        self.activePersonaId = "builtin-default"
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
