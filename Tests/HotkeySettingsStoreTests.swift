import CoreGraphics
import Foundation

private func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct HotkeySettingsStoreTests {
    static func main() throws {
        try testRejectsDuplicateAcrossFeatures()
        try testRejectsNonModifierVoiceTrigger()
        try testRejectsPureModifierFeatureHotkey()
        try testRejectsSingleKeyFeatureHotkey()
        try testValidationBlocksFeatureConflictViaRegistry()
        try testValidationSkipsPersonaPersonaConflict()
        try testDispersedKeyRoundTrip()
        try testSetterRegistersIntoRegistry()
        try testMigrationFromBlob()
        try testMigrationFromLegacyVoiceTriggerKey()
        print("HotkeySettingsStoreTests passed")
    }

    private static func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "HotkeySettingsStoreTests.\(name)")!
        defaults.removePersistentDomain(forName: "HotkeySettingsStoreTests.\(name)")
        return defaults
    }

    private static func makePersonaStore(personaIds: [String]) -> PersonaStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkey-settings-store-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = PersonaStore(storeURL: tmp.appendingPathComponent("personas.json"))
        let now = Date()
        for id in personaIds {
            store.add(Persona(
                id: id, name: id, icon: "star",
                stylePrompt: "", temperature: 0.5, hotkey: nil,
                contextSources: [], builtIn: false,
                createdAt: now, updatedAt: now
            ))
        }
        return store
    }

    private static func testRejectsDuplicateAcrossFeatures() throws {
        // Feature-vs-feature conflicts are registry-backed; the store's own
        // init/registerAll registers the clipboardPanel default into `registry`.
        let registry = HotkeyRegistry()
        let store = HotkeySettingsStore(defaults: makeDefaults(), registry: registry)
        do {
            try store.setHotkey(HotkeyConfig.parse("alt+v")!, for: .vaultPanel)
            assert(false, "duplicate feature hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message.contains("Clipboard"), "duplicate error should mention Clipboard")
        }
    }

    private static func testRejectsNonModifierVoiceTrigger() throws {
        let store = HotkeySettingsStore(defaults: makeDefaults(), registry: HotkeyRegistry())
        do {
            try store.setHotkey(HotkeyConfig.parse("cmd+alt+q")!, for: .voiceTrigger)
            assert(false, "non-modifier voice trigger should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message == "Use a modifier key for voice trigger", "voice trigger error should explain modifier requirement")
        }
    }

    private static func testRejectsPureModifierFeatureHotkey() throws {
        let store = HotkeySettingsStore(defaults: makeDefaults(), registry: HotkeyRegistry())
        do {
            try store.setHotkey(HotkeyConfig.parse("rightalt")!, for: .screenshot)
            assert(false, "pure modifier feature hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message == "Need a key, not just modifiers", "feature pure modifier error should match UI wording")
        }
    }

    private static func testRejectsSingleKeyFeatureHotkey() throws {
        let store = HotkeySettingsStore(defaults: makeDefaults(), registry: HotkeyRegistry())
        do {
            try store.setHotkey(HotkeyConfig.parse("q")!, for: .screenshot)
            assert(false, "single-key feature hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message == "Need at least one modifier", "feature single-key error should match UI wording")
        }
    }

    /// Registry-backed replacement for the deleted `testPersonaRecordingThrowsOnFeatureConflict`:
    /// a persona recording a hotkey already held by a feature (registered via the store's own
    /// registerAll at init) is blocked.
    private static func testValidationBlocksFeatureConflictViaRegistry() throws {
        let registry = HotkeyRegistry()
        let store = HotkeySettingsStore(defaults: makeDefaults(), registry: registry)
        let msg = store.validationMessage(for: HotkeyConfig.parse("alt+v")!, owner: .persona("p1"))
        assert(msg?.contains("Clipboard panel") == true, "persona recording blocked by feature entry")
    }

    /// Registry-backed replacement for the deleted `testValidationMessageSkipsPersonaConflictForPersonaOwner`:
    /// persona-vs-persona conflicts resolve by kick-out at commit time and must never block recording.
    private static func testValidationSkipsPersonaPersonaConflict() throws {
        let registry = HotkeyRegistry()
        registry.register(HotkeyConfig.parse("alt+q")!, owner: .persona(id: "other"), purpose: "Persona: Other")
        let store = HotkeySettingsStore(defaults: makeDefaults(), registry: registry)
        let msg = store.validationMessage(for: HotkeyConfig.parse("alt+q")!, owner: .persona("p1"))
        assert(msg == nil, "persona-persona conflicts resolve by kick-out, not blocked")
    }

    static func testDispersedKeyRoundTrip() throws {
        let defaults = makeDefaults()
        let store = HotkeySettingsStore(defaults: defaults, registry: HotkeyRegistry())
        // default: no key on disk, default value served
        assert(defaults.string(forKey: "clipboardPanelHotkey") == nil, "default not persisted")
        assert(store.rawHotkey(for: .clipboardPanel) == "alt+v", "default served when key absent")
        // customize: key written
        try store.setHotkey(HotkeyConfig.parse("alt+c")!, for: .clipboardPanel)
        assert(defaults.string(forKey: "clipboardPanelHotkey") == "alt+c", "customization persisted per-key")
        // reset: key removed
        try store.resetHotkey(for: .clipboardPanel)
        assert(defaults.string(forKey: "clipboardPanelHotkey") == nil, "reset removes the key")
        assert(store.rawHotkey(for: .clipboardPanel) == "alt+v", "reset restores default")
    }

    static func testSetterRegistersIntoRegistry() throws {
        let registry = HotkeyRegistry()
        let store = HotkeySettingsStore(defaults: makeDefaults(), registry: registry)
        try store.setHotkey(HotkeyConfig.parse("alt+c")!, for: .clipboardPanel)
        let hits = registry.conflicts(for: HotkeyConfig.parse("alt+c")!, excluding: nil as HotkeyRegistry.Owner?)
        assert(hits.contains { $0.owner == .clipboardPanel }, "setter refreshes registry entry")
    }

    static func testMigrationFromBlob() throws {
        let defaults = makeDefaults()
        // seed a legacy blob: customized screenshot key + one persona hotkey
        let blob: [String: Any] = [
            "version": 1,
            "featureHotkeys": ["screenshot": "ctrl+alt+s", "clipboardPanel": "alt+v"],
            "personaHotkeys": ["user-a": "alt+q"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: blob), forKey: "hotkeySettings.v1")
        let personaStore = makePersonaStore(personaIds: ["user-a"])   // temp-file store with one persona
        HotkeySettingsStore.migrateIfNeeded(defaults: defaults, personaStore: personaStore)
        assert(defaults.string(forKey: "screenshotHotkey") == "ctrl+alt+s", "customized feature migrated")
        assert(defaults.string(forKey: "clipboardPanelHotkey") == nil, "default-valued feature not migrated")
        assert(personaStore.persona(id: "user-a")?.hotkey == "alt+q", "persona hotkey migrated to model")
        assert(defaults.bool(forKey: "hotkeyStorageMigrated.v2"), "flag set")
        // idempotent: second run with mutated blob must be a no-op
        defaults.set("garbage".data(using: .utf8), forKey: "hotkeySettings.v1")
        HotkeySettingsStore.migrateIfNeeded(defaults: defaults, personaStore: personaStore)
        assert(defaults.string(forKey: "screenshotHotkey") == "ctrl+alt+s", "second run is a no-op")
    }

    static func testMigrationFromLegacyVoiceTriggerKey() throws {
        let defaults = makeDefaults()
        defaults.set("rightalt", forKey: "voiceTriggerKey")   // pre-v1 builds
        HotkeySettingsStore.migrateIfNeeded(defaults: defaults, personaStore: makePersonaStore(personaIds: []))
        assert(defaults.string(forKey: "voiceTriggerHotkey") == "rightalt", "legacy voice trigger migrated")
    }
}
