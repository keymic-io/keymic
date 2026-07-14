import Foundation

// Standalone test runner (swiftc @main), not XCTest. Prints "… passed" on success.

@main
struct SyncSectionTests {
    static func main() {
        let suiteName = "io.keymic.app.tests.sync.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create test UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-sync-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let personasURL = tmpDir.appendingPathComponent("personas.json")
        let env = SyncEnvironment(defaults: defaults, personasFileURL: personasURL)

        testScalarRoundTrip(env)
        testHotkeyKeysLiveInModuleSections()
        testHotkeyAbsentEqualsDefaultRoundTrip(env)
        testUnknownFieldPreserved(env)
        testLLMNeverCollectsAPIKey(env)
        testApplyClearsAbsentKeys(env)
        testPersonasFileRoundTrip(env)
        testUnownedKeysIgnoredOnApply(env)

        print("SyncSectionTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { fatalError("FAILED: \(msg)") }
    }

    static func testScalarRoundTrip(_ env: SyncEnvironment) {
        env.defaults.set(true, forKey: "voiceEnabled")
        env.defaults.set("en-US", forKey: "selectedLocaleCode")
        env.defaults.set("apple", forKey: "voiceModel")
        env.defaults.set(false, forKey: "enableSelectionCopyFallback")

        let data = SyncSection.voice.collectData(env: env)
        expect(data["voiceEnabled"] == .bool(true), "voiceEnabled collected as bool")
        expect(data["selectedLocaleCode"] == .string("en-US"), "locale collected")

        // Wipe, then apply back — values must restore.
        for k in SyncSection.voice.userDefaultsKeys { env.defaults.removeObject(forKey: k) }
        SyncSection.voice.applyData(data, env: env)
        expect(env.defaults.bool(forKey: "voiceEnabled") == true, "voiceEnabled restored")
        expect(env.defaults.string(forKey: "selectedLocaleCode") == "en-US", "locale restored")
        expect(env.defaults.string(forKey: "voiceModel") == "apple", "voiceModel restored")
        expect(env.defaults.bool(forKey: "enableSelectionCopyFallback") == false, "fallback restored")
    }

    // Feature hotkeys sync inside their module's section, as plain strings.
    static func testHotkeyKeysLiveInModuleSections() {
        expect(SyncSection.general.userDefaultsKeys.contains("settingsWindowHotkey"), "general owns settingsWindowHotkey")
        expect(SyncSection.voice.userDefaultsKeys.contains("voiceTriggerHotkey"), "voice owns voiceTriggerHotkey")
        expect(SyncSection.clipboard.userDefaultsKeys.contains("clipboardPanelHotkey"), "clipboard owns clipboardPanelHotkey")
        expect(SyncSection.clipboard.userDefaultsKeys.contains("vaultPanelHotkey"), "clipboard owns vaultPanelHotkey")
        expect(SyncSection.screenshot.userDefaultsKeys.contains("screenshotHotkey"), "screenshot owns screenshotHotkey")
        expect(SyncSection.hotkeys.userDefaultsKeys == ["hotkeysEnabled", "hotkeyBindings"], "hotkeys section reduced to enabled + bindings")
    }

    // Absent = default: an unset hotkey key must not appear in the payload,
    // and applying a payload without it must clear a local customization.
    static func testHotkeyAbsentEqualsDefaultRoundTrip(_ env: SyncEnvironment) {
        env.defaults.set("alt+c", forKey: "clipboardPanelHotkey")
        var data = SyncSection.clipboard.collectData(env: env)
        expect(data["clipboardPanelHotkey"] == .string("alt+c"), "customization collected")

        data.removeValue(forKey: "clipboardPanelHotkey")
        SyncSection.clipboard.applyData(data, env: env)
        expect(env.defaults.string(forKey: "clipboardPanelHotkey") == nil,
               "absent key clears local customization (revert to default)")
    }

    static func testUnknownFieldPreserved(_ env: SyncEnvironment) {
        // A newer app version uploaded a key this build doesn't know. It must
        // survive our collect→upload cycle.
        env.defaults.set("gpt-4o-mini", forKey: "llmModel")
        env.defaults.set("https://api.openai.com/v1", forKey: "llmAPIBaseURL")
        let base: [String: JSONValue] = ["llmFutureFlag": .bool(true), "llmModel": .string("stale")]
        let data = SyncSection.llm.collectData(base: base, env: env)
        expect(data["llmFutureFlag"] == .bool(true), "unknown key preserved")
        expect(data["llmModel"] == .string("gpt-4o-mini"), "known key overwrote stale base value")
    }

    static func testLLMNeverCollectsAPIKey(_ env: SyncEnvironment) {
        env.defaults.set("sk-super-secret", forKey: "llmAPIKey")
        let data = SyncSection.llm.collectData(env: env)
        expect(data["llmAPIKey"] == nil, "llm payload must never contain llmAPIKey")
        expect(!SyncSection.llm.userDefaultsKeys.contains("llmAPIKey"), "llmAPIKey not an owned key")
    }

    static func testApplyClearsAbsentKeys(_ env: SyncEnvironment) {
        env.defaults.set(999, forKey: "clipboardMaxHistory")
        // Downloaded payload omits clipboardMaxHistory → should revert to default (removed).
        SyncSection.clipboard.applyData(["clipboardEnabled": .bool(true)], env: env)
        expect(env.defaults.object(forKey: "clipboardMaxHistory") == nil, "absent key cleared on apply")
        expect(env.defaults.bool(forKey: "clipboardEnabled") == true, "present key applied")
    }

    static func testPersonasFileRoundTrip(_ env: SyncEnvironment) {
        let envelope: [String: Any] = [
            "version": 1,
            "personas": [["id": "p1", "name": "Editor"]],
            "activePersonaId": "p1",
        ]
        let blob = try! JSONSerialization.data(withJSONObject: envelope)
        try! blob.write(to: env.personasFileURL)

        let data = SyncSection.personas.collectData(env: env)
        expect(data["envelope"] != nil, "personas envelope collected")

        try? FileManager.default.removeItem(at: env.personasFileURL)
        SyncSection.personas.applyData(data, env: env)
        guard let restored = try? Data(contentsOf: env.personasFileURL),
              let obj = try? JSONSerialization.jsonObject(with: restored) as? [String: Any] else {
            fatalError("FAILED: personas file not restored")
        }
        expect(obj["activePersonaId"] as? String == "p1", "personas content restored")
    }

    static func testUnownedKeysIgnoredOnApply(_ env: SyncEnvironment) {
        env.defaults.removeObject(forKey: "someRandomKey")
        SyncSection.voice.applyData(["voiceEnabled": .bool(true), "someRandomKey": .string("x")], env: env)
        expect(env.defaults.object(forKey: "someRandomKey") == nil, "unowned key never written")
    }
}
