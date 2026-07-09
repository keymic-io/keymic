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
        testBlobRoundTrip(env)
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

    static func testBlobRoundTrip(_ env: SyncEnvironment) {
        // hotkeySettings.v1 is stored as JSON-encoded Data. It must sync as a
        // readable subtree and re-materialize byte-equivalent.
        let snapshot: [String: Any] = [
            "version": 1,
            "featureHotkeys": ["voiceTrigger": "fn", "clipboardPanel": "alt+v"],
            "personaHotkeys": [:] as [String: String],
        ]
        let blob = try! JSONSerialization.data(withJSONObject: snapshot)
        env.defaults.set(blob, forKey: "hotkeySettings.v1")
        env.defaults.set(true, forKey: "hotkeysEnabled")

        let data = SyncSection.hotkeys.collectData(env: env)
        env.defaults.removeObject(forKey: "hotkeySettings.v1")
        SyncSection.hotkeys.applyData(data, env: env)

        guard let restored = env.defaults.data(forKey: "hotkeySettings.v1"),
              let obj = try? JSONSerialization.jsonObject(with: restored) as? [String: Any] else {
            fatalError("FAILED: hotkey blob not restored as Data")
        }
        expect(obj["version"] as? Int == 1, "blob version restored")
        let feats = obj["featureHotkeys"] as? [String: String]
        expect(feats?["voiceTrigger"] == "fn", "blob nested value restored")
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
