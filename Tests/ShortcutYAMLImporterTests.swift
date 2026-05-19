import Foundation

@main
struct ShortcutYAMLImporterTestRunner {
    static func main() throws {
        // Tmp dir for audit-log files; cleaned up at end.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-importer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try testHappyPathInsertsBindingAndWritesAudit(tmp: tmp)

        // P-04: safety-gate stack — pure-modifier / system-reserved / macos-reserved / registry.
        try testPureModifierClearsTrigger(tmp: tmp)
        try testSystemReservedClearsTrigger(tmp: tmp)
        try testMacOSReservedClearsTrigger(tmp: tmp)
        try testRegistryConflictClearsTrigger(tmp: tmp)

        // P-05 / P-06 will append additional try testX(tmp:) calls here.

        print("ShortcutYAMLImporterTests passed")
    }

    // MARK: - Fixture loader

    /// Locates `Tests/Fixtures/shortcut-yaml/` via `#filePath`. Mirror of
    /// `ShortcutYAMLParserTests.FixtureLoader` — standalone swiftc has no
    /// `Bundle.module`, so #filePath is the only stable anchor.
    private enum FixtureLoader {
        static let dir: URL = {
            if let env = ProcessInfo.processInfo.environment["SHORTCUT_YAML_FIXTURES_DIR"], !env.isEmpty {
                return URL(fileURLWithPath: env)
            }
            let testFile = URL(fileURLWithPath: #filePath)
            return testFile.deletingLastPathComponent().appendingPathComponent("Fixtures/shortcut-yaml")
        }()

        static func read(_ name: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    // MARK: - Tests

    /// P-03 happy path: parse → insert → set lastImportedBindingId → audit-write
    /// → post .shortcutImportDidComplete. Asserts on outcome shape, store state,
    /// and the on-disk audit-log JSON (including field-order per Pitfall §6).
    /// Notification delivery is asserted by P-06 (cross-restart sweep).
    private static func testHappyPathInsertsBindingAndWritesAudit(tmp: URL) throws {
        // 1. Isolated UserDefaults suite.
        let suiteName = "test.ShortcutYAMLImporter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 2. Audit URL inside tmp dir.
        let auditURL = tmp.appendingPathComponent("audit.log")

        // 3. Dependencies — fresh injection (NOT .shared).
        let auditLog = ShortcutAuditLog(logURL: auditURL, maxBytes: 5 * 1024 * 1024)
        let store = HotkeyBindingsStore(defaults: defaults)
        let importer = ShortcutYAMLImporter(
            store: store,
            registry: HotkeyRegistry.shared,  // shared registry; this test doesn't register anything
            auditLog: auditLog,
            userDefaults: defaults
        )

        // 4. Inline happy-path YAML.
        let yaml = """
        version: 1
        shortcut: "alt+g"
        label: "Open Chrome"
        actions:
          - text: "hello"
        """
        let transcript = "按 alt+g 打开 chrome"

        // 5. Pre-flight: store empty.
        expect(store.bindings.isEmpty, "store should be empty pre-import")

        // 6. Run import.
        let outcome = importer.importYAML(yaml, transcript: transcript)

        // 7. Drain audit queue so disk read below is deterministic.
        auditLog.flushForTesting()

        // 8. Outcome shape (D-E-1, 6 fields).
        expect(outcome.bindingId != nil, "happy path must return non-nil bindingId")
        expect(outcome.parseError == nil, "happy path must have parseError == nil")
        expect(outcome.conflictCleared == false, "no conflict expected")
        expect(outcome.conflictSource == nil, "no conflict source expected")
        expect(outcome.shellStripped == false, "no shell stripping expected")
        expect(outcome.droppedBundleIDs.isEmpty, "no dropped bundle ids expected")

        // 9. Store state.
        expect(store.bindings.count == 1, "exactly one binding inserted")
        expect(store.bindings[0].id == outcome.bindingId!, "binding id matches outcome")
        expect(store.bindings[0].createdBy == "voice", "createdBy == voice")
        expect(store.bindings[0].label == "Open Chrome", "label persisted (got \(String(describing: store.bindings[0].label)))")
        expect(!store.bindings[0].trigger.isEmpty, "trigger non-empty in happy path (got '\(store.bindings[0].trigger)')")

        // 10. Audit log file: exactly one line, parses as JSON, expected fields.
        let content = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        expect(lines.count == 1, "exactly one audit line written (got \(lines.count))")
        guard let lineData = lines[0].data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: lineData, options: []),
              let dict = any as? [String: Any]
        else {
            fail("audit line did not parse as JSON object: \(lines[0])")
        }
        expect(dict["action"] as? String == "import",
               "action == 'import' (got \(String(describing: dict["action"])))")
        expect(dict["bindingId"] as? String == outcome.bindingId?.uuidString,
               "bindingId matches outcome (got \(String(describing: dict["bindingId"])))")
        expect(dict["conflictCleared"] as? Bool == false,
               "conflictCleared == false (got \(String(describing: dict["conflictCleared"])))")
        // parseError is nil on happy path → encoded as JSON null → NSNull on parse.
        let parseErrorVal = dict["parseError"]
        let isParseErrorNullOrMissing = parseErrorVal == nil || parseErrorVal is NSNull
        expect(isParseErrorNullOrMissing,
               "parseError must be null/missing on happy path (got \(String(describing: parseErrorVal)))")
        expect(dict["transcript"] as? String == transcript,
               "transcript round-trips (got \(String(describing: dict["transcript"])))")
        let ts = dict["timestamp"] as? String ?? ""
        expect(ts.contains("T") && ts.hasSuffix("Z"),
               "timestamp looks like ISO-8601 (got '\(ts)')")
        expect(dict["shellStripped"] as? Bool == false,
               "shellStripped == false on happy path")
        if let arr = dict["droppedBundleIDs"] as? [Any] {
            expect(arr.isEmpty, "droppedBundleIDs is empty on happy path")
        } else {
            fail("droppedBundleIDs must be an array (got \(String(describing: dict["droppedBundleIDs"])))")
        }

        // 11. Field-order assertion per RESEARCH Pitfall §6 — JSON key order is
        // load-bearing for jq-friendly diffs + EVAL-01 v2 pipeline.
        // CodingKeys order: timestamp, transcript, yaml, bindingId, conflictCleared,
        // conflictSource, parseError, shellStripped, droppedBundleIDs, action.
        let rawLine = String(lines[0])
        let orderedKeys: [String] = [
            "timestamp", "transcript", "yaml", "bindingId", "conflictCleared",
            "conflictSource", "parseError", "shellStripped", "droppedBundleIDs", "action",
        ]
        var lastIndex: String.Index = rawLine.startIndex
        var lastKey = "<start>"
        for key in orderedKeys {
            let needle = "\"\(key)\":"
            guard let r = rawLine.range(of: needle, range: lastIndex..<rawLine.endIndex) else {
                fail("audit line missing key '\(key)' after '\(lastKey)' in: \(rawLine)")
            }
            lastIndex = r.upperBound
            lastKey = key
        }

        print("testHappyPathInsertsBindingAndWritesAudit: ok")
    }

    // MARK: - P-04 safety-gate tests
    //
    // Contract (IMP-04): on any matching gate, the binding is STILL inserted
    // but with `trigger = ""`, `enabled = false`, `conflictCleared = true`,
    // and `conflictSource` set to the gate-specific tag. Audit record mirrors.

    /// Gate 1: pure-modifier trigger (e.g. `fn`).
    private static func testPureModifierClearsTrigger(tmp: URL) throws {
        try runGateTest(
            tmp: tmp,
            fixture: "importer-conflict-pure-modifier.yaml",
            expectedSource: "pure-modifier",
            preImport: nil,
            testName: "testPureModifierClearsTrigger"
        )
    }

    /// Gate 2: system-reserved trigger (e.g. `cmd+q` — already in
    /// `HotkeyConfig.reservedShortcuts`).
    private static func testSystemReservedClearsTrigger(tmp: URL) throws {
        try runGateTest(
            tmp: tmp,
            fixture: "importer-conflict-cmd-q.yaml",
            expectedSource: "system-reserved",
            preImport: nil,
            testName: "testSystemReservedClearsTrigger"
        )
    }

    /// Gate 3: macOS-reserved safe-set trigger (e.g. `cmd+shift+tab` — only
    /// in `MACOS_RESERVED_SHORTCUTS`, NOT in `HotkeyConfig.reservedShortcuts`).
    private static func testMacOSReservedClearsTrigger(tmp: URL) throws {
        try runGateTest(
            tmp: tmp,
            fixture: "importer-conflict-cmd-shift-tab.yaml",
            expectedSource: "macos",
            preImport: nil,
            testName: "testMacOSReservedClearsTrigger"
        )
    }

    /// Gate 4: registry collision — a `feature`-owner (e.g. `.clipboardPanel`)
    /// is pre-registered with the same config; the importer must see the
    /// collision and tag `conflictSource = "feature"`.
    private static func testRegistryConflictClearsTrigger(tmp: URL) throws {
        // Pre-register a fake feature on `alt+f7`. Must unregister via
        // `defer` to avoid bleed into later tests (T-03-04-06 mitigation).
        guard let cfg = HotkeyConfig.parse("alt+f7") else {
            fail("alt+f7 should be a valid HotkeyConfig — check tokenToKeyCode table")
        }
        // Sanity: ensure gates 1-3 do NOT fire so the test isolates gate 4.
        expect(!cfg.isPureModifier, "alt+f7 must not be pure-modifier (gate-4 isolation)")
        expect(!cfg.isSystemReserved, "alt+f7 must not be system-reserved (gate-4 isolation)")

        let beforeCount = HotkeyRegistry.shared.all().count
        HotkeyRegistry.shared.register(cfg, owner: .clipboardPanel, purpose: "test gate 4 fixture")
        defer {
            HotkeyRegistry.shared.unregister(owner: .clipboardPanel)
            // Sanity: registry should be back to its pre-test population.
            expect(HotkeyRegistry.shared.all().count == beforeCount,
                   "registry must be clean post-test (got \(HotkeyRegistry.shared.all().count), expected \(beforeCount))")
        }

        try runGateTest(
            tmp: tmp,
            fixture: "importer-conflict-registered.yaml",
            expectedSource: "feature",
            preImport: nil,
            testName: "testRegistryConflictClearsTrigger"
        )
    }

    /// Shared gate-test scaffold. Loads the fixture, runs the import with
    /// fresh deps, asserts the IMP-04 contract on Outcome / store / audit.
    private static func runGateTest(
        tmp: URL,
        fixture: String,
        expectedSource: String,
        preImport: ((HotkeyRegistry) -> Void)?,
        testName: String
    ) throws {
        // 1. Isolated UserDefaults suite.
        let suiteName = "test.ShortcutYAMLImporter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 2. Audit URL inside tmp dir (unique per test to avoid cross-test bleed).
        let auditURL = tmp.appendingPathComponent("audit-\(testName).log")

        // 3. Dependencies — fresh injection. Use the shared registry so the
        //    gate-4 preregister-in-caller pattern works; happy path doesn't
        //    add anything to it. Tests that mutate must `defer` cleanup.
        let auditLog = ShortcutAuditLog(logURL: auditURL, maxBytes: 5 * 1024 * 1024)
        let store = HotkeyBindingsStore(defaults: defaults)
        let importer = ShortcutYAMLImporter(
            store: store,
            registry: HotkeyRegistry.shared,
            auditLog: auditLog,
            userDefaults: defaults
        )

        preImport?(HotkeyRegistry.shared)

        // 4. Load fixture + transcript.
        let yaml = try FixtureLoader.read(fixture)
        let transcript = "test transcript for \(testName)"

        // 5. Pre-flight.
        expect(store.bindings.isEmpty, "[\(testName)] store should be empty pre-import")

        // 6. Run import.
        let outcome = importer.importYAML(yaml, transcript: transcript)

        // 7. Drain audit queue.
        auditLog.flushForTesting()

        // 8. Outcome shape — IMP-04 contract: binding inserted, trigger cleared.
        expect(outcome.bindingId != nil,
               "[\(testName)] binding still inserted on cleared conflict (IMP-04)")
        expect(outcome.parseError == nil,
               "[\(testName)] no parse error on conflict path")
        expect(outcome.conflictCleared == true,
               "[\(testName)] conflictCleared must be true")
        expect(outcome.conflictSource == expectedSource,
               "[\(testName)] conflictSource == \"\(expectedSource)\" (got \(String(describing: outcome.conflictSource)))")

        // 9. Store state — IMP-04: binding inserted with cleared trigger.
        expect(store.bindings.count == 1, "[\(testName)] exactly one binding inserted")
        let inserted = store.bindings[0]
        expect(inserted.id == outcome.bindingId!,
               "[\(testName)] binding id matches outcome")
        expect(inserted.trigger == "",
               "[\(testName)] trigger cleared (got '\(inserted.trigger)')")
        expect(inserted.enabled == false,
               "[\(testName)] enabled forced to false on cleared conflict")
        expect(inserted.createdBy == "voice",
               "[\(testName)] createdBy still 'voice'")

        // 10. Audit log JSON.
        let content = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        expect(lines.count == 1, "[\(testName)] exactly one audit line (got \(lines.count))")
        guard let lineData = lines[0].data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: lineData, options: []),
              let dict = any as? [String: Any]
        else {
            fail("[\(testName)] audit line did not parse as JSON: \(lines[0])")
        }
        expect(dict["action"] as? String == "import",
               "[\(testName)] action == 'import'")
        expect(dict["conflictCleared"] as? Bool == true,
               "[\(testName)] audit conflictCleared == true")
        expect(dict["conflictSource"] as? String == expectedSource,
               "[\(testName)] audit conflictSource == \"\(expectedSource)\" (got \(String(describing: dict["conflictSource"])))")
        expect(dict["bindingId"] as? String == outcome.bindingId?.uuidString,
               "[\(testName)] audit bindingId matches outcome")
        // parseError must be null on conflict path.
        let parseErrorVal = dict["parseError"]
        let isParseErrorNull = parseErrorVal == nil || parseErrorVal is NSNull
        expect(isParseErrorNull,
               "[\(testName)] audit parseError null on conflict path")
        expect(dict["transcript"] as? String == transcript,
               "[\(testName)] audit transcript round-trips")

        print("\(testName): ok")
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
