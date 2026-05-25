import Foundation

@main
struct PersonaStoreTestRunner {
    static func main() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-store-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("personas.json")

        // First load on empty disk → seeds 6 built-ins, active = nil
        let store1 = PersonaStore(storeURL: url)
        expect(store1.personas.count == 6, "first load seeds 6 built-ins")
        expect(store1.activePersonaId == nil,
               "first launch leaves active persona empty")
        expect(FileManager.default.fileExists(atPath: url.path),
               "first load writes file to disk")

        // Persistence: re-load same URL retains state
        let store2 = PersonaStore(storeURL: url)
        expect(store2.personas.count == 6, "reload keeps 6 personas")
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
            contextSources: [], builtIn: false,
            createdAt: now, updatedAt: now
        )
        store3.add(custom)
        expect(store3.personas.count == 7, "add appends")
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
            contextSources: [], builtIn: false,
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

        testBuiltinCliInjectionStrategyPromotedOnMerge()

        print("✅ PersonaStoreTests passed")
    }

    /// Existing installs have `builtin-cli.injectionStrategy = .replaceFocusedText` on disk
    /// (set by P2 seed before LOR-15). Without a migration the legacy JSON value wins and the
    /// new `.runShell({query})` strategy never activates. `mergeWithBuiltIns` must promote the
    /// seed's `injectionStrategy` onto the loaded built-in while preserving user-editable
    /// fields (stylePrompt, temperature).
    static func testBuiltinCliInjectionStrategyPromotedOnMerge() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-persona-migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storeURL = tmpDir.appendingPathComponent("personas.json")

        let legacyJSON = """
        {
          "version": 1,
          "personas": [
            {
              "builtIn": true,
              "contextSources": [],
              "createdAt": "2024-01-01T00:00:00.000Z",
              "icon": "terminal",
              "id": "builtin-cli",
              "injectionStrategy": { "replaceFocusedText": {} },
              "name": "CLI Wizard",
              "stylePrompt": "USER EDITED PROMPT",
              "temperature": 0.2,
              "updatedAt": "2024-01-01T00:00:00.000Z"
            }
          ],
          "activePersonaId": null
        }
        """
        try? legacyJSON.write(to: storeURL, atomically: true, encoding: .utf8)

        let store = PersonaStore(storeURL: storeURL)
        guard let cli = store.persona(id: "builtin-cli") else {
            expect(false, "builtin-cli missing after merge"); return
        }
        expect(cli.injectionStrategy == .runShell(commandTemplate: "{query}"),
               "merge must promote builtin-cli.injectionStrategy to .runShell({query})")
        expect(cli.stylePrompt == "USER EDITED PROMPT",
               "user-edited stylePrompt must survive the merge")
        expect(cli.temperature == 0.2, "user-edited temperature must survive the merge")
    }


    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }
}
