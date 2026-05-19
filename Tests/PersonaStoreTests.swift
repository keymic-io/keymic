import Foundation

@main
struct PersonaStoreTestRunner {
    static func main() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-store-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("personas.json")

        // First load on empty disk → seeds 4 built-ins, active = nil
        let store1 = PersonaStore(storeURL: url)
        expect(store1.personas.count == 4, "first load seeds 4 built-ins")
        expect(store1.activePersonaId == nil,
               "first launch leaves active persona empty")
        expect(FileManager.default.fileExists(atPath: url.path),
               "first load writes file to disk")

        // Persistence: re-load same URL retains state
        let store2 = PersonaStore(storeURL: url)
        expect(store2.personas.count == 4, "reload keeps 4 personas")
        expect(store2.activePersonaId == nil, "reload keeps empty active persona")

        // setActive(nil) → passthrough mode
        store2.setActive(nil)
        let store3 = PersonaStore(storeURL: url)
        expect(store3.activePersonaId == nil, "setActive(nil) persists")

        // add: custom persona
        let now = Date()
        let custom = Persona(
            id: "user-1", name: "Mine", icon: "star",
            stylePrompt: "test", temperature: 0.8, hotkey: nil,
            contextMode: .none, contextCount: 1,
            outputStrategy: .replaceFocusedText, builtIn: false,
            createdAt: now, updatedAt: now
        )
        store3.add(custom)
        expect(store3.personas.count == 5, "add appends")
        expect(store3.persona(id: "user-1") != nil, "lookup by id works")

        // delete: built-in cannot be deleted
        store3.delete(id: "builtin-default")
        expect(store3.persona(id: "builtin-default") != nil, "built-in NOT deleted")

        // delete: custom can be deleted
        store3.delete(id: "user-1")
        expect(store3.persona(id: "user-1") == nil, "custom deleted")

        // setActive rejects unknown id → nil
        store3.setActive("user-2-doesnt-exist")
        expect(store3.activePersonaId == nil, "setActive rejects unknown id")

        // delete active → active becomes nil
        let now2 = Date()
        let custom2 = Persona(
            id: "user-2", name: "Mine2", icon: "star",
            stylePrompt: "x", temperature: 0.5, hotkey: nil,
            contextMode: .none, contextCount: 1,
            outputStrategy: .replaceFocusedText, builtIn: false,
            createdAt: now2, updatedAt: now2
        )
        store3.add(custom2)
        store3.setActive("user-2")
        store3.delete(id: "user-2")
        expect(store3.activePersonaId == nil, "deleting active clears active")

        // update: stylePrompt change persists, updatedAt bumps
        let original = store3.persona(id: "builtin-default")!
        var modified = original
        modified.stylePrompt = "modified"
        store3.update(modified)
        let reloaded = PersonaStore(storeURL: url).persona(id: "builtin-default")!
        expect(reloaded.stylePrompt == "modified", "stylePrompt update persisted")
        expect(reloaded.updatedAt > original.updatedAt, "updatedAt bumped on update")

        // duplicate: id changes, builtIn=false, name suffixed
        let dup = store3.duplicate(id: "builtin-translate")!
        expect(dup.id != "builtin-translate", "duplicate gets new id")
        expect(!dup.builtIn, "duplicate is not built-in")
        expect(dup.name.contains("Auto Translate"), "duplicate name derived from source")

        // persona(forHotkey:)
        var withHotkey = dup
        withHotkey.hotkey = "alt+q"
        store3.update(withHotkey)
        expect(store3.persona(forHotkey: "alt+q")?.id == dup.id,
               "lookup by hotkey works")
        expect(store3.persona(forHotkey: "alt+w") == nil,
               "missing hotkey returns nil")

        // --- v1 → v2 migration ---
        let migTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-store-migration-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: migTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: migTmp) }
        let migURL = migTmp.appendingPathComponent("personas.json")

        // Write a v1 envelope on disk (no contextCount, no outputStrategy).
        let v1Json = """
        {
          "version": 1,
          "personas": [
            {
              "id": "user-legacy",
              "name": "Legacy",
              "icon": "sparkles",
              "stylePrompt": "legacy",
              "temperature": 0.3,
              "hotkey": null,
              "contextMode": "none",
              "builtIn": false,
              "createdAt": "2026-01-01T00:00:00.000Z",
              "updatedAt": "2026-01-01T00:00:00.000Z"
            }
          ],
          "activePersonaId": null
        }
        """
        try! v1Json.data(using: .utf8)!.write(to: migURL)

        let migrated = PersonaStore(storeURL: migURL)
        let legacy = migrated.persona(id: "user-legacy")!
        expect(legacy.contextCount == 1, "v1 migration: contextCount defaults to 1")
        expect(legacy.outputStrategy == .replaceFocusedText,
            "v1 migration: outputStrategy defaults to .replaceFocusedText")

        // Reload the same file: it should now decode as v2 with no migration.
        let reloadedMigrated = PersonaStore(storeURL: migURL)
        expect(reloadedMigrated.persona(id: "user-legacy") != nil,
            "v2 reload preserves migrated user persona")

        print("✅ PersonaStoreTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }
}
