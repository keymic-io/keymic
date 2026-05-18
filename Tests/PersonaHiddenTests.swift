import Foundation

@main
struct PersonaHiddenTestRunner {
    static func main() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-hidden-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // D-10 #1: seeds contain exactly one hidden persona (builtin-shortcut-config),
        //          and the total seed count is 5.
        testSeedsContainExactlyOneHiddenPersona()

        // D-10 #2: on a fresh PersonaStore(storeURL:), shortcutConfigPersona returns the
        //          seeded hidden persona (non-nil, id matches, hidden == true).
        testShortcutConfigPersonaGetter(tmpDir: tmp)

        // D-10 #3: setActive("builtin-shortcut-config") is a no-op — the previously-active
        //          visible persona stays active (NOT nil, NOT the hidden id).
        testSetActiveRejectsHiddenIdPreservesPrevious(tmpDir: tmp)

        // D-10 #4: a pre-Phase-1 personas.json (no `hidden` key on any persona) loads with
        //          hidden == false on every disk-sourced persona — covers backwards-compat
        //          of `decodeIfPresent(Bool.self, forKey: .hidden) ?? false`.
        testDecodingOldPersonasJsonDefaultsHiddenFalse(tmpDir: tmp)

        // D-10 #5: mergeWithBuiltIns(loaded:) overrides {id, builtIn, hidden} from the seed
        //          when a disk persona's id matches a built-in seed. User-editable fields
        //          (stylePrompt, temperature, icon, name, etc.) survive from disk.
        //          Regression for the latent hand-edit BLOCKER closed by PERS-07.
        testReMergeOverridesHiddenFromSeed(tmpDir: tmp)

        // D-10 #6: visiblePersonas excludes the hidden seed; allPersonas includes it.
        testVisiblePersonasFiltersHidden(tmpDir: tmp)

        print("✅ PersonaHiddenTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }

    // MARK: - D-10 #1

    static func testSeedsContainExactlyOneHiddenPersona() {
        let seeds = Persona.builtInSeeds()
        expect(seeds.count == 5, "exactly 5 built-in seeds (was 4 pre-Phase-1)")
        let hidden = seeds.filter { $0.hidden }
        expect(hidden.count == 1, "exactly one hidden seed")
        expect(hidden.first?.id == "builtin-shortcut-config",
               "the hidden seed is builtin-shortcut-config")
    }

    // MARK: - D-10 #2

    static func testShortcutConfigPersonaGetter(tmpDir: URL) {
        let url = tmpDir.appendingPathComponent("\(UUID().uuidString)-personas.json")
        let store = PersonaStore(storeURL: url)
        let shortcut = store.shortcutConfigPersona
        expect(shortcut != nil, "shortcutConfigPersona returns non-nil on fresh store")
        expect(shortcut?.id == "builtin-shortcut-config",
               "shortcutConfigPersona has id builtin-shortcut-config")
        expect(shortcut?.hidden == true,
               "shortcutConfigPersona is hidden == true")
    }

    // MARK: - D-10 #3

    static func testSetActiveRejectsHiddenIdPreservesPrevious(tmpDir: URL) {
        let url = tmpDir.appendingPathComponent("\(UUID().uuidString)-personas.json")
        let store = PersonaStore(storeURL: url)

        // Establish a visible-persona baseline as the active one.
        store.setActive("builtin-default")
        expect(store.activePersonaId == "builtin-default",
               "setActive on a visible persona is honored")

        // Attempt to activate the hidden seed — must be a silent no-op:
        // activePersonaId stays "builtin-default" (NOT nil, NOT the hidden id).
        store.setActive("builtin-shortcut-config")
        expect(store.activePersonaId == "builtin-default",
               "setActive(hidden) is a no-op; previous visible active preserved")
        expect(store.activePersonaId != "builtin-shortcut-config",
               "setActive(hidden) did NOT switch to the hidden persona")
        expect(store.activePersonaId != nil,
               "setActive(hidden) did NOT demote activePersonaId to nil")

        // Sanity: visiblePersonas does not include the hidden id at all.
        expect(store.visiblePersonas.contains { $0.id == "builtin-shortcut-config" } == false,
               "visiblePersonas excludes the hidden id even after setActive attempt")
    }

    // MARK: - D-10 #4

    static func testDecodingOldPersonasJsonDefaultsHiddenFalse(tmpDir: URL) {
        let url = tmpDir.appendingPathComponent("\(UUID().uuidString)-personas.json")
        // Verbatim from RESEARCH.md "Test fixture JSON for 'old personas.json without hidden field' (D-10 case 4)"
        // — pre-Phase-1 envelope, no `hidden` key on any persona. Date format requires .000
        // fractional seconds because the decoder uses [.withInternetDateTime, .withFractionalSeconds].
        let oldPersonasJSON = """
        {
          "activePersonaId" : null,
          "personas" : [
            {
              "builtIn" : true,
              "contextMode" : "none",
              "createdAt" : "2024-01-01T00:00:00.000Z",
              "hotkey" : null,
              "icon" : "sparkles",
              "id" : "builtin-default",
              "name" : "Default",
              "stylePrompt" : "old prompt",
              "temperature" : 0.3,
              "updatedAt" : "2024-01-01T00:00:00.000Z"
            },
            {
              "builtIn" : false,
              "contextMode" : "none",
              "createdAt" : "2024-01-01T00:00:00.000Z",
              "hotkey" : null,
              "icon" : "star",
              "id" : "user-pre-phase1",
              "name" : "Pre-Phase-1 Custom",
              "stylePrompt" : "user wrote this",
              "temperature" : 0.5,
              "updatedAt" : "2024-01-01T00:00:00.000Z"
            }
          ],
          "version" : 1
        }
        """
        try! oldPersonasJSON.write(to: url, atomically: true, encoding: .utf8)

        let store = PersonaStore(storeURL: url)

        // Both disk-sourced personas decode hidden == false. The shortcut-config seed
        // is RE-MERGED in by mergeWithBuiltIns (covered by D-10 #5), so we target
        // the 2 disk-sourced personas by id rather than asserting on the whole list.
        let oldDefault = store.allPersonas.first { $0.id == "builtin-default" }
        expect(oldDefault != nil, "builtin-default loaded from disk")
        expect(oldDefault?.hidden == false,
               "pre-Phase-1 builtin-default decodes hidden=false (decodeIfPresent default)")

        let userPersona = store.allPersonas.first { $0.id == "user-pre-phase1" }
        expect(userPersona != nil, "user-pre-phase1 loaded from disk")
        expect(userPersona?.hidden == false,
               "pre-Phase-1 custom persona decodes hidden=false (decodeIfPresent default)")

        // User-editable fields preserved from disk for the disk-only personas.
        expect(oldDefault?.stylePrompt == "old prompt",
               "pre-Phase-1 stylePrompt preserved on disk-sourced built-in")
        expect(userPersona?.stylePrompt == "user wrote this",
               "pre-Phase-1 custom stylePrompt preserved")
    }

    // MARK: - D-10 #5

    static func testReMergeOverridesHiddenFromSeed(tmpDir: URL) {
        let url = tmpDir.appendingPathComponent("\(UUID().uuidString)-personas.json")
        // Verbatim from RESEARCH.md "Test fixture JSON for 're-merge override' (D-10 case 5)"
        // — hand-edited `personas.json` where builtin-shortcut-config has hidden=false
        // AND builtIn=false (tampered). The merge step must restore those immutable
        // fields from the seed while preserving user-editable fields from disk.
        let tamperedJSON = """
        {
          "activePersonaId" : null,
          "personas" : [
            {
              "builtIn" : false,
              "contextMode" : "none",
              "createdAt" : "2024-01-01T00:00:00.000Z",
              "hidden" : false,
              "hotkey" : null,
              "icon" : "wrench",
              "id" : "builtin-shortcut-config",
              "name" : "Tampered Name",
              "stylePrompt" : "user-edited prompt — should survive merge",
              "temperature" : 0.99,
              "updatedAt" : "2024-01-01T00:00:00.000Z"
            }
          ],
          "version" : 1
        }
        """
        try! tamperedJSON.write(to: url, atomically: true, encoding: .utf8)

        let store = PersonaStore(storeURL: url)
        let shortcut = store.shortcutConfigPersona
        expect(shortcut != nil, "shortcutConfigPersona present after tampered load")

        // Immutable fields restored from seed (PERS-07 + latent builtIn:false bug fix):
        expect(shortcut?.id == "builtin-shortcut-config",
               "id restored to seed value")
        expect(shortcut?.builtIn == true,
               "builtIn restored to seed value (was false on disk)")
        expect(shortcut?.hidden == true,
               "hidden restored to seed value (was false on disk)")

        // User-editable fields preserved from disk:
        expect(shortcut?.stylePrompt == "user-edited prompt — should survive merge",
               "user's stylePrompt edit preserved through merge")
        expect(shortcut?.temperature == 0.99,
               "temperature preserved from disk")
        expect(shortcut?.icon == "wrench",
               "icon preserved from disk")
        expect(shortcut?.name == "Tampered Name",
               "name preserved from disk")
    }

    // MARK: - D-10 #6

    static func testVisiblePersonasFiltersHidden(tmpDir: URL) {
        let url = tmpDir.appendingPathComponent("\(UUID().uuidString)-personas.json")
        let store = PersonaStore(storeURL: url)

        // Fresh first-launch seed: 5 total, 4 visible, 1 hidden.
        expect(store.allPersonas.count == 5,
               "allPersonas includes all 5 seeded built-ins")
        expect(store.visiblePersonas.count == 4,
               "visiblePersonas excludes the 1 hidden seed (5 - 1 == 4)")
        expect(store.visiblePersonas.allSatisfy { !$0.hidden },
               "every persona in visiblePersonas has hidden == false")
        expect(store.allPersonas.contains { $0.hidden && $0.id == "builtin-shortcut-config" },
               "allPersonas contains the hidden builtin-shortcut-config persona")
        expect(store.visiblePersonas.contains { $0.id == "builtin-shortcut-config" } == false,
               "visiblePersonas excludes builtin-shortcut-config")
    }
}
