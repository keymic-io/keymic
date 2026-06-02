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
        try testPersistsPersonaHotkey()
        try testIgnoresInvalidPersonaHotkey()
        try testFeatureFallbackForInvalidStoredValue()
        try testRejectsDuplicateAcrossFeatures()
        try testRejectsDuplicateAcrossPersona()
        try testPersonaRecordingKicksOutOtherPersona()
        try testPersonaRecordingThrowsOnFeatureConflict()
        try testValidationMessageSkipsPersonaConflictForPersonaOwner()
        try testRejectsNonModifierVoiceTrigger()
        try testRejectsPureModifierFeatureHotkey()
        try testRejectsSingleKeyFeatureHotkey()
        try testRejectsPureModifierPersonaHotkey()
        try testRejectsSingleKeyPersonaHotkey()
        try testSanitizesInvalidStoredFeatureShape()
        try testSanitizesInvalidStoredPersonaShape()
        try testResetHotkeyPersistsDefault()
        try testResetHotkeyRejectsConflictingDefault()
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
        assert(store.rawPersonaHotkey(personaId: "p1") == "cmd+alt+1", "initial persona hotkey should be captured")
    }

    private static func testPersistsFeatureHotkey() throws {
        let defaults = makeDefaults()
        var store = makeStore(defaults: defaults)
        try store.setHotkey(HotkeyConfig(modifiers: [.maskCommand, .maskShift], keyCode: 0x0B), for: .screenshot)

        store = makeStore(defaults: defaults)
        assert(store.rawHotkey(for: .screenshot) == "shift+cmd+b", "feature hotkey should persist")
    }

    private static func testPersistsPersonaHotkey() throws {
        let defaults = makeDefaults()
        var store = makeStore(defaults: defaults)
        try store.setPersonaHotkey(HotkeyConfig(modifiers: [.maskCommand, .maskAlternate], keyCode: 0x0C), personaId: "p1")

        store = makeStore(defaults: defaults)
        assert(store.rawPersonaHotkey(personaId: "p1") == "alt+cmd+q", "persona hotkey should persist")
    }

    private static func testIgnoresInvalidPersonaHotkey() throws {
        let defaults = makeDefaults()
        let snapshot = HotkeySettingsSnapshot(
            version: 1,
            featureHotkeys: HotkeyFeature.defaults,
            personaHotkeys: ["p1": "not-a-hotkey"]
        )
        defaults.set(try JSONEncoder().encode(snapshot), forKey: HotkeySettingsStore.userDefaultsKey)

        let store = makeStore(defaults: defaults)
        assert(store.rawPersonaHotkey(personaId: "p1") == nil, "invalid persona hotkey should be ignored")
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
        let store = makeStore()
        do {
            try store.setHotkey(HotkeyConfig.parse("alt+v")!, for: .vaultPanel)
            assert(false, "duplicate feature hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message.contains("Clipboard"), "duplicate error should mention Clipboard")
        }
    }

    private static func testRejectsDuplicateAcrossPersona() throws {
        let store = makeStore()
        try store.setPersonaHotkey(HotkeyConfig.parse("cmd+alt+q")!, personaId: "p1")
        do {
            try store.setHotkey(HotkeyConfig.parse("cmd+alt+q")!, for: .screenshot)
            assert(false, "duplicate persona hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message.contains("Persona"), "duplicate error should mention Persona")
        }
    }

    private static func testPersonaRecordingKicksOutOtherPersona() throws {
        let store = makeStore()
        try store.setPersonaHotkey(HotkeyConfig.parse("cmd+alt+q")!, personaId: "p1")
        assert(store.rawPersonaHotkey(personaId: "p1") == "alt+cmd+q", "p1 should hold the original hotkey")

        try store.setPersonaHotkey(HotkeyConfig.parse("cmd+alt+q")!, personaId: "p2")

        assert(store.rawPersonaHotkey(personaId: "p1") == nil, "p1 binding should be cleared after p2 takes the same hotkey")
        assert(store.rawPersonaHotkey(personaId: "p2") == "alt+cmd+q", "p2 should now hold the hotkey")
    }

    private static func testPersonaRecordingThrowsOnFeatureConflict() throws {
        let store = makeStore()
        try store.setPersonaHotkey(HotkeyConfig.parse("cmd+alt+q")!, personaId: "p1")

        do {
            try store.setPersonaHotkey(HotkeyConfig.parse("alt+v")!, personaId: "p1")
            assert(false, "persona hotkey conflicting with feature should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message.contains("Clipboard"), "feature conflict error should mention Clipboard")
        }

        assert(store.rawPersonaHotkey(personaId: "p1") == "alt+cmd+q", "p1 binding should remain unchanged after feature conflict")
    }

    private static func testValidationMessageSkipsPersonaConflictForPersonaOwner() throws {
        let store = makeStore()
        try store.setPersonaHotkey(HotkeyConfig.parse("cmd+alt+q")!, personaId: "p1")

        let cfg = HotkeyConfig.parse("cmd+alt+q")!
        assert(
            store.validationMessage(for: cfg, owner: .persona("p2")) == nil,
            "validationMessage for persona owner should ignore persona-to-persona conflicts (kick-out policy)"
        )

        let featureConfig = HotkeyConfig.parse("alt+v")!
        let msg = store.validationMessage(for: featureConfig, owner: .persona("p2"))
        assert(msg != nil && msg!.contains("Clipboard"), "validationMessage for persona owner should still report feature conflict; got \(msg ?? "nil")")
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

    private static func testRejectsPureModifierPersonaHotkey() throws {
        let store = makeStore()
        do {
            try store.setPersonaHotkey(HotkeyConfig.parse("rightalt")!, personaId: "p1")
            assert(false, "pure modifier persona hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message == "Need a key, not just modifiers", "persona pure modifier error should match UI wording")
        }
    }

    private static func testRejectsSingleKeyPersonaHotkey() throws {
        let store = makeStore()
        do {
            try store.setPersonaHotkey(HotkeyConfig.parse("q")!, personaId: "p1")
            assert(false, "single-key persona hotkey should throw")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message == "Need at least one modifier", "persona single-key error should match UI wording")
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

    private static func testSanitizesInvalidStoredPersonaShape() throws {
        let defaults = makeDefaults()
        let snapshot = HotkeySettingsSnapshot(
            version: 1,
            featureHotkeys: HotkeyFeature.defaults,
            personaHotkeys: ["p1": "fn", "p2": "q", "p3": "cmd+alt+q"]
        )
        defaults.set(try JSONEncoder().encode(snapshot), forKey: HotkeySettingsStore.userDefaultsKey)

        let store = makeStore(defaults: defaults)
        assert(store.rawPersonaHotkey(personaId: "p1") == nil, "stored pure-modifier persona hotkey should be ignored")
        assert(store.rawPersonaHotkey(personaId: "p2") == nil, "stored single-key persona hotkey should be ignored")
        assert(store.rawPersonaHotkey(personaId: "p3") == "cmd+alt+q", "stored valid persona hotkey should remain")
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
        let store = makeStore()
        try store.setHotkey(HotkeyConfig.parse("ctrl+shift+a")!, for: .screenshot)
        try store.setPersonaHotkey(HotkeyConfig.parse("ctrl+alt+a")!, personaId: "p1")

        do {
            try store.resetHotkey(for: .screenshot)
            assert(false, "reset should reject a default hotkey already used by another owner")
        } catch let error as HotkeySettingsStore.ValidationError {
            assert(error.message.contains("Persona"), "reset conflict should mention the conflicting owner")
        }
        assert(store.rawHotkey(for: .screenshot) == "ctrl+shift+a", "failed reset should leave existing feature hotkey unchanged")
    }
}
