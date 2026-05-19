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

    // P-04 fills in preprocessing-edge fixtures (fences, <think>, BOM, CRLF, smart quotes, tabs).
    private static func runEdgeFixtures() throws {}

    // P-05 fills in per-ShortcutYAMLError-variant error fixtures.
    private static func runErrorFixtures() throws {}

    // P-03 fills in encoder→parser round-trip cases (YAML-10, "modulo id").
    private static func runRoundTrip() throws {}

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
