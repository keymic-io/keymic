import Foundation

@main
struct ShortcutYAMLParserTestRunner {
    static func main() throws {
        // Sanity-check: the on-disk fixture directory must be reachable.
        // `#filePath`-resolved path is the default; `SHORTCUT_YAML_FIXTURES_DIR`
        // overrides for out-of-tree runs.
        guard FileManager.default.fileExists(atPath: FixtureLoader.dir.path) else {
            fail("fixtures dir not found at \(FixtureLoader.dir.path); set SHORTCUT_YAML_FIXTURES_DIR or run from repo root")
        }

        try runHappyFixtures()
        try runEdgeFixtures()
        try runErrorFixtures()
        try runRoundTrip()

        print("ShortcutYAMLParserTests passed")
    }

    // MARK: - Suites (only happy is populated in P-02; rest fill in P-03..P-05)

    private static func runHappyFixtures() throws {
        try runHappy01Minimal()
        try runHappy02QuotedForms()
    }

    private static func runHappy01Minimal() throws {
        let raw = try FixtureLoader.read("happy-01-minimal.yaml")
        let parsed = try ShortcutYAMLParser.parse(raw)

        // Top-level fields.
        expect(parsed.binding.trigger == "alt+g",
               "happy-01: trigger should be canonical 'alt+g', got '\(parsed.binding.trigger)'")
        expect(parsed.label == "Send hello",
               "happy-01: label should be 'Send hello', got \(String(describing: parsed.label))")
        expect(parsed.binding.enabled == true,
               "happy-01: enabled should be true")
        expect(parsed.binding.appBundleIDs == ["com.google.Chrome"],
               "happy-01: appBundleIDs should be [com.google.Chrome], got \(parsed.binding.appBundleIDs)")

        // Action list.
        expect(parsed.binding.actions.count == 3,
               "happy-01: expected 3 actions, got \(parsed.binding.actions.count)")

        // Cross-check the keyPress action against the canonical encoder so we
        // don't hard-code platform-dependent integers in two places.
        guard let cmdSpace = HotkeyConfig.parse("cmd+space") else {
            fail("happy-01: HotkeyConfig.parse(\"cmd+space\") returned nil — table changed?")
        }
        let expectedKeyPress: HotkeyAction = .keyPress(
            keyCode: UInt16(cmdSpace.keyCode),
            modifiers: cmdSpace.modifiers.rawValue
        )
        expect(parsed.binding.actions[0] == expectedKeyPress,
               "happy-01: actions[0] expected \(expectedKeyPress), got \(parsed.binding.actions[0])")
        expect(parsed.binding.actions[1] == .typeText("chrome"),
               "happy-01: actions[1] expected .typeText(chrome), got \(parsed.binding.actions[1])")
        expect(parsed.binding.actions[2] == .wait(ms: 500),
               "happy-01: actions[2] expected .wait(ms: 500), got \(parsed.binding.actions[2])")

        // Cross-check against the expected.json projection on disk.
        let expectedJSON = try FixtureLoader.read("happy-01-minimal.expected.json")
        let expectedData = expectedJSON.data(using: .utf8)!
        let any = try JSONSerialization.jsonObject(with: expectedData, options: [])
        guard let dict = any as? [String: Any],
              let bindingDict = dict["binding"] as? [String: Any],
              let actionsArr = bindingDict["actions"] as? [[String: Any]]
        else {
            fail("happy-01: expected.json shape invalid (top-level binding/actions)")
        }
        // First action: keyPress with keyCode + modifiers.
        guard let kp = actionsArr.first,
              let kc = kp["keyCode"] as? NSNumber,
              let mods = kp["modifiers"] as? NSNumber
        else {
            fail("happy-01: expected.json actions[0] missing keyCode/modifiers")
        }
        expect(UInt16(truncating: kc) == UInt16(cmdSpace.keyCode),
               "happy-01: expected.json keyCode mismatch — runner saw \(cmdSpace.keyCode), file saw \(kc)")
        expect(UInt64(truncating: mods) == cmdSpace.modifiers.rawValue,
               "happy-01: expected.json modifiers mismatch — runner saw \(cmdSpace.modifiers.rawValue), file saw \(mods)")
    }

    /// P-03: prove YAML-08 — all three string scalar forms parse identically
    /// for the parser-side string handling.
    ///
    /// Fixture mixes:
    ///   - double-quoted `label:` with `\"` + `\n` escapes (processed)
    ///   - single-quoted `text:` LITERAL (no escape processing — `\n` stays as
    ///     literal backslash-n)
    ///   - unquoted `key:` value (`cmd+space`, no quotes at all)
    private static func runHappy02QuotedForms() throws {
        let raw = try FixtureLoader.read("happy-02-quoted-forms.yaml")
        let parsed = try ShortcutYAMLParser.parse(raw)

        // Top-level
        expect(parsed.binding.trigger == "alt+g",
               "happy-02: trigger should be 'alt+g', got '\(parsed.binding.trigger)'")
        // Double-quoted label MUST have escapes processed.
        let expectedLabel = "She said \"hi\"\nthen left"
        expect(parsed.label == expectedLabel,
               "happy-02: label escape-processing failed — expected \(expectedLabel.debugDescription), got \(String(describing: parsed.label).debugDescription)")
        expect(parsed.binding.enabled == true, "happy-02: enabled should be true")
        expect(parsed.binding.appBundleIDs.isEmpty,
               "happy-02: appBundleIDs should be empty (omitted line), got \(parsed.binding.appBundleIDs)")

        // Actions: 2 entries
        expect(parsed.binding.actions.count == 2,
               "happy-02: expected 2 actions, got \(parsed.binding.actions.count)")

        // actions[0]: single-quoted text → LITERAL backslash-n (no escape processing).
        let expectedText = "literal\\nshown\\nas\\nbackslash-n"
        expect(parsed.binding.actions[0] == .typeText(expectedText),
               "happy-02: actions[0] expected .typeText(\(expectedText.debugDescription)) [single-quoted LITERAL], got \(parsed.binding.actions[0])")

        // actions[1]: unquoted `key: cmd+space` → .keyPress(cmd+space).
        guard let cmdSpace = HotkeyConfig.parse("cmd+space") else {
            fail("happy-02: HotkeyConfig.parse(\"cmd+space\") returned nil — table changed?")
        }
        let expectedKeyPress: HotkeyAction = .keyPress(
            keyCode: UInt16(cmdSpace.keyCode),
            modifiers: cmdSpace.modifiers.rawValue
        )
        expect(parsed.binding.actions[1] == expectedKeyPress,
               "happy-02: actions[1] (unquoted key) expected \(expectedKeyPress), got \(parsed.binding.actions[1])")

        // Cross-check against expected.json projection.
        let expectedJSON = try FixtureLoader.read("happy-02-quoted-forms.expected.json")
        let expectedData = expectedJSON.data(using: .utf8)!
        let any = try JSONSerialization.jsonObject(with: expectedData, options: [])
        guard let dict = any as? [String: Any],
              let bindingDict = dict["binding"] as? [String: Any],
              let actionsArr = bindingDict["actions"] as? [[String: Any]],
              let jsonLabel = dict["label"] as? String
        else {
            fail("happy-02: expected.json shape invalid")
        }
        expect(jsonLabel == expectedLabel,
               "happy-02: expected.json label mismatch — file=\(jsonLabel.debugDescription), runner=\(expectedLabel.debugDescription)")
        guard let firstAction = actionsArr.first,
              let typeStr = firstAction["type"] as? String,
              typeStr == "typeText",
              let textStr = firstAction["text"] as? String
        else {
            fail("happy-02: expected.json actions[0] missing typeText/text")
        }
        expect(textStr == expectedText,
               "happy-02: expected.json text mismatch — file=\(textStr.debugDescription), runner=\(expectedText.debugDescription)")

        // Inline 4096-cap assertion (YAML-09): text > 4096 chars throws .invalidValue.
        let longText = String(repeating: "a", count: 4097)
        let longYAML = """
            version: 1
            shortcut: "alt+g"
            actions:
              - text: "\(longText)"
            """
        do {
            _ = try ShortcutYAMLParser.parse(longYAML)
            fail("happy-02: 4097-char text should throw .invalidValue but parse succeeded")
        } catch let err as ShortcutYAMLError {
            switch err {
            case .invalidValue(let field, _, _):
                expect(field == "text",
                       "happy-02: 4096 cap threw .invalidValue with wrong field — expected 'text', got '\(field)'")
            default:
                fail("happy-02: 4096 cap threw wrong ShortcutYAMLError variant: \(err)")
            }
        } catch {
            fail("happy-02: 4096 cap threw unexpected error type: \(error)")
        }
        // Confirm 4096 chars exactly is still accepted.
        let okText = String(repeating: "a", count: 4096)
        let okYAML = """
            version: 1
            shortcut: "alt+g"
            actions:
              - text: "\(okText)"
            """
        do {
            let p = try ShortcutYAMLParser.parse(okYAML)
            expect(p.binding.actions.count == 1,
                   "happy-02: 4096-char text boundary should parse to 1 action")
        } catch {
            fail("happy-02: 4096 chars (boundary) should be accepted, got \(error)")
        }
    }

    // P-04 fills in preprocessing-edge fixtures (fences, <think>, BOM, CRLF, smart quotes, tabs).
    private static func runEdgeFixtures() throws {}

    // P-05 fills in per-ShortcutYAMLError-variant error fixtures.
    private static func runErrorFixtures() throws {}

    // P-03 fills in encoder→parser round-trip cases (YAML-10, "modulo id").
    //
    // Invariant: parse(encode(parsed)) == parsed modulo binding.id (the id is
    // regenerated on every parse via UUID() — comparing == on HotkeyBinding
    // would always fail, so equalIgnoringId compares every other field
    // explicitly).
    private static func runRoundTrip() throws {
        for name in ["roundtrip-01-canonical", "roundtrip-02-emoji-cjk"] {
            let raw = try FixtureLoader.read("\(name).yaml")
            let parsed = try ShortcutYAMLParser.parse(raw)
            let encoded = ShortcutYAMLEncoder.encode(parsed)
            let reparsed = try ShortcutYAMLParser.parse(encoded)
            expect(equalIgnoringId(reparsed, parsed),
                   "\(name): round-trip mismatch.\nORIG  binding=\(parsed.binding) label=\(String(describing: parsed.label))\nENCODED=\n\(encoded)\nREPARSED binding=\(reparsed.binding) label=\(String(describing: reparsed.label))")
        }

        // Round-trip identity for .wait(ms:) — the seconds-vs-ms boundary the
        // encoder has to round-trip cleanly. Per CONTEXT.md:
        //   `parse(encode(.wait(ms: 1500))).actions[i] == .wait(ms: 1500)`.
        let waitBinding = HotkeyBinding(
            trigger: "alt+g",
            actions: [.wait(ms: 1500), .wait(ms: 1000), .wait(ms: 250)],
            enabled: true,
            appBundleIDs: []
        )
        let encodedWait = ShortcutYAMLEncoder.encode(waitBinding, label: "wait-roundtrip")
        let reparsedWait = try ShortcutYAMLParser.parse(encodedWait)
        expect(reparsedWait.binding.actions == waitBinding.actions,
               "wait-roundtrip: actions mismatch.\nORIG=\(waitBinding.actions)\nENCODED=\n\(encodedWait)\nREPARSED=\(reparsedWait.binding.actions)")
    }

    /// Compare two ParsedShortcuts ignoring binding.id (regenerated on each
    /// parse via UUID()). Every other field of HotkeyBinding + label is
    /// compared explicitly so adding a new field to HotkeyBinding would
    /// require updating this helper (failure mode is caught at review time).
    private static func equalIgnoringId(_ a: ParsedShortcut, _ b: ParsedShortcut) -> Bool {
        guard a.label == b.label else { return false }
        guard a.binding.trigger == b.binding.trigger else { return false }
        guard a.binding.enabled == b.binding.enabled else { return false }
        guard a.binding.appBundleIDs == b.binding.appBundleIDs else { return false }
        guard a.binding.actions == b.binding.actions else { return false }
        return true
    }

    // MARK: - Fixture loader (no in-repo analog; pattern per RESEARCH.md Pattern 13)

    private enum FixtureLoader {
        static let dir: URL = {
            if let env = ProcessInfo.processInfo.environment["SHORTCUT_YAML_FIXTURES_DIR"], !env.isEmpty {
                return URL(fileURLWithPath: env)
            }
            // #filePath is the compile-time literal path to this test file.
            // Standalone swiftc has no Bundle.module — this is the only way
            // for a test binary to find on-disk fixtures relative to itself.
            let testFile = URL(fileURLWithPath: #filePath)
            return testFile.deletingLastPathComponent().appendingPathComponent("Fixtures/shortcut-yaml")
        }()

        static func read(_ name: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    // MARK: - Helpers (copied verbatim from project-wide test idiom)

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
