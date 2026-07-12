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
        try testInitializesCompleteSnapshot()
        try testPersistsFeatureHotkey()
        try testFeatureFallbackForInvalidStoredValue()
        try testRejectsDuplicateAcrossFeatures()
        try testRejectsNonModifierVoiceTrigger()
        try testRejectsPureModifierFeatureHotkey()
        try testRejectsSingleKeyFeatureHotkey()
        try testSanitizesInvalidStoredFeatureShape()
        try testResetHotkeyPersistsDefault()
        try testResetHotkeyRejectsConflictingDefault()
        try testValidationBlocksFeatureConflictViaRegistry()
        try testValidationSkipsPersonaPersonaConflict()
        print("HotkeySettingsStoreTests passed")
    }

    private static func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "HotkeySettingsStoreTests.\(name)")!
        defaults.removePersistentDomain(forName: "HotkeySettingsStoreTests.\(name)")
        return defaults
    }

    private static func makeStore(
        defaults: UserDefaults = makeDefaults(),
        personas: [Persona] = []
    ) -> HotkeySettingsStore {
        HotkeySettingsStore(defaults: defaults, personasProvider: { personas })
    }

    private static func testInitializesCompleteSnapshot() throws {
        let store = makeStore(personas: [
            Persona(
                id: "p1",
                name: "P1",
                icon: "sparkles",
                stylePrompt: "",
                temperature: 0.3,
                hotkey: "cmd+alt+1",
                contextSources: [],
                builtIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        ])

        assert(store.rawHotkey(for: .voiceTrigger) == "fn", "voice default should be fn")
        assert(store.rawHotkey(for: .clipboardPanel) == "alt+v", "clipboard default should be alt+v")
        assert(store.rawHotkey(for: .vaultPanel) == "alt+b", "vault default should be alt+b")
        assert(store.rawHotkey(for: .settingsWindow) == "cmd+shift+,", "settings default should be cmd+shift+,")
        assert(store.rawHotkey(for: .screenshot) == "ctrl+alt+a", "screenshot default should be ctrl+alt+a")
        for feature in HotkeyFeature.allCases {
            assert(store.hotkey(for: feature) != nil, "default hotkey for \(feature.rawValue) should parse")
        }
    }

    private static func testPersistsFeatureHotkey() throws {
        let defaults = makeDefaults()
        var store = makeStore(defaults: defaults)
        try store.setHotkey(HotkeyConfig(modifiers: [.maskCommand, .maskShift], keyCode: 0x0B), for: .screenshot)

        store = makeStore(defaults: defaults)
        assert(store.rawHotkey(for: .screenshot) == "shift+cmd+b", "feature hotkey should persist")
    }

    private static func testFeatureFallbackForInvalidStoredValue() throws {
        let defaults = makeDefaults()
        var featureHotkeys = HotkeyFeature.defaults
        featureHotkeys[HotkeyFeature.screenshot.rawValue] = "not-a-hotkey"
        let snapshot = HotkeySettingsSnapshot(version: 1, featureHotkeys: featureHotkeys, personaHotkeys: [:])
        defaults.set(try JSONEncoder().encode(snapshot), forKey: HotkeySettingsStore.userDefaultsKey)

        let store = makeStore(defaults: defaults)
        assert(store.rawHotkey(for: .screenshot) == "ctrl+alt+a", "invalid feature hotkey should fall back to default")
    }

    private static func testRejectsDuplicateAcrossFeatures() throws {
        // Feature-vs-feature conflicts are registry-backed; in production
        // AppDelegate registers built-in defaults at startup, so simulate that here.
        let registry = HotkeyRegistry.shared
        registry.register(HotkeyConfig.parse("alt+v")!, owner: .clipboardPanel, purpose: "Clipboard panel")
        defer { registry.unregister(owner: .clipboardPanel) }

        let store = makeStore()
        do {
            try store.setHotkey(HotkeyConfig.parse("alt+v")!, for: .vaultPanel)
            assert(false, "duplicate feature hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message.contains("Clipboard"), "duplicate error should mention Clipboard")
        }
    }

    private static func testRejectsNonModifierVoiceTrigger() throws {
        let store = makeStore()
        do {
            try store.setHotkey(HotkeyConfig.parse("cmd+alt+q")!, for: .voiceTrigger)
            assert(false, "non-modifier voice trigger should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message == "Use a modifier key for voice trigger", "voice trigger error should explain modifier requirement")
        }
    }

    private static func testRejectsPureModifierFeatureHotkey() throws {
        let store = makeStore()
        do {
            try store.setHotkey(HotkeyConfig.parse("rightalt")!, for: .screenshot)
            assert(false, "pure modifier feature hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message == "Need a key, not just modifiers", "feature pure modifier error should match UI wording")
        }
    }

    private static func testRejectsSingleKeyFeatureHotkey() throws {
        let store = makeStore()
        do {
            try store.setHotkey(HotkeyConfig.parse("q")!, for: .screenshot)
            assert(false, "single-key feature hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message == "Need at least one modifier", "feature single-key error should match UI wording")
        }
    }

    private static func testSanitizesInvalidStoredFeatureShape() throws {
        let defaults = makeDefaults()
        var featureHotkeys = HotkeyFeature.defaults
        featureHotkeys[HotkeyFeature.screenshot.rawValue] = "fn"
        featureHotkeys[HotkeyFeature.clipboardPanel.rawValue] = "q"
        let snapshot = HotkeySettingsSnapshot(version: 1, featureHotkeys: featureHotkeys, personaHotkeys: [:])
        defaults.set(try JSONEncoder().encode(snapshot), forKey: HotkeySettingsStore.userDefaultsKey)

        let store = makeStore(defaults: defaults)
        assert(store.rawHotkey(for: .screenshot) == "ctrl+alt+a", "stored pure-modifier feature hotkey should fall back to default")
        assert(store.rawHotkey(for: .clipboardPanel) == "alt+v", "stored single-key feature hotkey should fall back to default")
    }

    private static func testResetHotkeyPersistsDefault() throws {
        let defaults = makeDefaults()
        var store = makeStore(defaults: defaults)
        try store.setHotkey(HotkeyConfig.parse("ctrl+shift+a")!, for: .screenshot)
        try store.resetHotkey(for: .screenshot)

        store = makeStore(defaults: defaults)
        assert(store.rawHotkey(for: .screenshot) == "ctrl+alt+a", "reset feature hotkey should persist default")
    }

    private static func testResetHotkeyRejectsConflictingDefault() throws {
        let registry = HotkeyRegistry.shared
        let store = makeStore()
        try store.setHotkey(HotkeyConfig.parse("ctrl+shift+a")!, for: .screenshot)
        registry.register(HotkeyConfig.parse("ctrl+alt+a")!, owner: .persona(id: "p1"), purpose: "Persona: P1")
        defer { registry.unregister(owner: .persona(id: "p1")) }

        do {
            try store.resetHotkey(for: .screenshot)
            assert(false, "reset should reject a default hotkey already used by another owner")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message.contains("Persona"), "reset conflict should mention the conflicting owner")
        }
        assert(store.rawHotkey(for: .screenshot) == "ctrl+shift+a", "failed reset should leave existing feature hotkey unchanged")
    }

    /// Registry-backed replacement for the deleted `testPersonaRecordingThrowsOnFeatureConflict`:
    /// a persona recording a hotkey already held by a feature (registered in `HotkeyRegistry`,
    /// as AppDelegate does at startup) is blocked.
    private static func testValidationBlocksFeatureConflictViaRegistry() throws {
        let registry = HotkeyRegistry.shared
        registry.register(HotkeyConfig.parse("alt+v")!, owner: .clipboardPanel, purpose: "Clipboard panel")
        defer { registry.unregister(owner: .clipboardPanel) }
        let store = HotkeySettingsStore(defaults: makeDefaults(), personasProvider: { [] })
        let msg = store.validationMessage(for: HotkeyConfig.parse("alt+v")!, owner: .persona("p1"))
        assert(msg?.contains("Clipboard panel") == true, "persona recording blocked by feature entry")
    }

    /// Registry-backed replacement for the deleted `testValidationMessageSkipsPersonaConflictForPersonaOwner`:
    /// persona-vs-persona conflicts resolve by kick-out at commit time and must never block recording.
    private static func testValidationSkipsPersonaPersonaConflict() throws {
        let registry = HotkeyRegistry.shared
        registry.register(HotkeyConfig.parse("alt+q")!, owner: .persona(id: "other"), purpose: "Persona: Other")
        defer { registry.unregister(owner: .persona(id: "other")) }
        let store = HotkeySettingsStore(defaults: makeDefaults(), personasProvider: { [] })
        let msg = store.validationMessage(for: HotkeyConfig.parse("alt+q")!, owner: .persona("p1"))
        assert(msg == nil, "persona-persona conflicts resolve by kick-out, not blocked")
    }
}
