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
                contextMode: .none,
                builtIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        ])

        assert(store.rawHotkey(for: .voiceTrigger) == "fn", "voice default should be fn")
        assert(store.rawHotkey(for: .clipboardPanel) == "alt+v", "clipboard default should be alt+v")
        assert(store.rawHotkey(for: .vaultPanel) == "alt+b", "vault default should be alt+b")
        assert(store.rawHotkey(for: .settingsWindow) == "cmd+shift+comma", "settings default should be cmd+shift+comma")
        assert(store.rawHotkey(for: .screenshot) == "cmd+shift+a", "screenshot default should be cmd+shift+a")
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
        assert(store.rawHotkey(for: .screenshot) == "cmd+shift+a", "invalid feature hotkey should fall back to default")
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
}
