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

        // P-05: IMP-05 / IMP-07 / IMP-08 / IMP-09.
        try testParseErrorWritesAuditOnly(tmp: tmp)
        try testShellStrippedWhenGateOff(tmp: tmp)
        try testInvalidBundleIDSoftDropped(tmp: tmp)
        try testSelfTriggerRejectsWithoutInsert(tmp: tmp)

        // P-06: IMP-11 (undo) + AUD-05 (rotation) + AUD-06 (terminate) + TEST-06 sweep.
        try testRemoveLastImportUndoes(tmp: tmp)

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

    // MARK: - P-05 tests (IMP-05 / IMP-07 / IMP-08 / IMP-09)

    /// IMP-07: a YAML that fails ShortcutYAMLParser.parse(_:) writes ONE audit
    /// line with `parseError: { kind: <canonical>, ... }`, returns
    /// Outcome(bindingId: nil, parseError: <kind>), and performs NO store
    /// mutation. The fixture omits the required `shortcut:` field, which
    /// triggers `ShortcutYAMLError.missingShortcut` → kind == "missingShortcut".
    private static func testParseErrorWritesAuditOnly(tmp: URL) throws {
        let suiteName = "test.ShortcutYAMLImporter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let auditURL = tmp.appendingPathComponent("audit-parse-error.log")
        let auditLog = ShortcutAuditLog(logURL: auditURL, maxBytes: 5 * 1024 * 1024)
        let store = HotkeyBindingsStore(defaults: defaults)
        let importer = ShortcutYAMLImporter(
            store: store,
            registry: HotkeyRegistry.shared,
            auditLog: auditLog,
            userDefaults: defaults
        )

        let yaml = try FixtureLoader.read("importer-parse-error.yaml")
        let transcript = "parse-error test transcript"

        expect(store.bindings.isEmpty, "store should be empty pre-import")

        let outcome = importer.importYAML(yaml, transcript: transcript)
        auditLog.flushForTesting()

        // Outcome: parseError set, bindingId nil, no insert.
        expect(outcome.bindingId == nil, "parse error must not return a bindingId")
        expect(outcome.parseError == "missingShortcut",
               "parseError kind == 'missingShortcut' (got \(String(describing: outcome.parseError)))")
        expect(outcome.conflictCleared == false, "no conflict on parse-error path")
        expect(outcome.shellStripped == false, "no shell-strip on parse-error path")
        expect(outcome.droppedBundleIDs.isEmpty, "no bundle drops on parse-error path")

        // Store: NO mutation.
        expect(store.bindings.isEmpty, "no store mutation on parse error")

        // Audit log: ONE line; parseError is a JSON sub-object with the same kind.
        let content = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        expect(lines.count == 1, "exactly one audit line on parse-error path (got \(lines.count))")
        guard let lineData = lines[0].data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: lineData, options: []),
              let dict = any as? [String: Any]
        else {
            fail("audit line did not parse as JSON: \(lines[0])")
        }
        expect(dict["action"] as? String == "import", "action == 'import'")
        let parseErrorVal = dict["parseError"]
        guard let parseErrorDict = parseErrorVal as? [String: Any] else {
            fail("parseError must be a JSON object (got \(String(describing: parseErrorVal)))")
        }
        expect(parseErrorDict["kind"] as? String == "missingShortcut",
               "audit parseError.kind == 'missingShortcut' (got \(String(describing: parseErrorDict["kind"])))")
        let bindingIdVal = dict["bindingId"]
        let isBindingIdNull = bindingIdVal == nil || bindingIdVal is NSNull
        expect(isBindingIdNull, "audit bindingId is null on parse error")
        expect(dict["transcript"] as? String == transcript, "audit transcript round-trips")

        print("testParseErrorWritesAuditOnly: ok")
    }

    /// IMP-08: a YAML containing a `.shell` action is stripped + binding
    /// inserted with `enabled = false` when the toggle is OFF (default).
    /// Toggled ON, the same YAML preserves the shell action and respects
    /// the YAML's enabled value. This test exercises BOTH states by flipping
    /// the UserDefaults key mid-test.
    private static func testShellStrippedWhenGateOff(tmp: URL) throws {
        let suiteName = "test.ShortcutYAMLImporter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let auditURL = tmp.appendingPathComponent("audit-shell.log")
        let auditLog = ShortcutAuditLog(logURL: auditURL, maxBytes: 5 * 1024 * 1024)
        let store = HotkeyBindingsStore(defaults: defaults)
        let importer = ShortcutYAMLImporter(
            store: store,
            registry: HotkeyRegistry.shared,
            auditLog: auditLog,
            userDefaults: defaults
        )

        let yaml = try FixtureLoader.read("importer-shell-action.yaml")
        let transcript = "shell action test transcript"

        // PASS 1: gate OFF (default — key not set, bool(forKey:) returns false).
        let outcome1 = importer.importYAML(yaml, transcript: transcript)
        auditLog.flushForTesting()

        expect(outcome1.bindingId != nil, "[gate-off] binding still inserted with shell stripped")
        expect(outcome1.shellStripped == true,
               "[gate-off] shellStripped == true (got \(outcome1.shellStripped))")
        expect(outcome1.parseError == nil, "[gate-off] no parse error")
        expect(store.bindings.count == 1, "[gate-off] one binding inserted")
        let inserted1 = store.bindings[0]
        expect(inserted1.enabled == false,
               "[gate-off] stripped binding inserted disabled (got enabled=\(inserted1.enabled))")
        let hasShell1 = inserted1.actions.contains { action in
            if case .shell = action { return true }
            return false
        }
        expect(!hasShell1, "[gate-off] no .shell actions remain (got actions: \(inserted1.actions))")

        // Audit-line check for pass 1: shellStripped == true.
        let content1 = try String(contentsOf: auditURL, encoding: .utf8)
        let lines1 = content1.split(separator: "\n", omittingEmptySubsequences: true)
        expect(lines1.count == 1, "[gate-off] exactly one audit line (got \(lines1.count))")
        if let lineData = lines1[0].data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: lineData, options: []),
           let dict = any as? [String: Any] {
            expect(dict["shellStripped"] as? Bool == true,
                   "[gate-off] audit shellStripped == true")
        } else {
            fail("[gate-off] audit line did not parse as JSON: \(lines1[0])")
        }

        // PASS 2: flip the gate ON; re-import the same YAML.
        defaults.set(true, forKey: ShortcutYAMLImporter.userDefaultsKeyShellEnabled)

        // Use a fresh audit log + fresh store to isolate pass 2's assertions
        // from pass 1's state without resetting the suite (which would also
        // discard the gate-toggle we just set).
        let auditURL2 = tmp.appendingPathComponent("audit-shell-on.log")
        let auditLog2 = ShortcutAuditLog(logURL: auditURL2, maxBytes: 5 * 1024 * 1024)
        let store2 = HotkeyBindingsStore(defaults: defaults)
        let importer2 = ShortcutYAMLImporter(
            store: store2,
            registry: HotkeyRegistry.shared,
            auditLog: auditLog2,
            userDefaults: defaults
        )
        // store2 may have observed the pass-1 binding via the shared
        // suite's userDefaults; drop it explicitly so this pass starts fresh.
        store2.bindings.removeAll()

        let outcome2 = importer2.importYAML(yaml, transcript: transcript)
        auditLog2.flushForTesting()

        expect(outcome2.bindingId != nil, "[gate-on] binding inserted")
        expect(outcome2.shellStripped == false,
               "[gate-on] shellStripped == false (got \(outcome2.shellStripped))")
        expect(store2.bindings.count == 1, "[gate-on] one binding inserted")
        let inserted2 = store2.bindings[0]
        // Fixture has enabled: <implicit true>; gate ON means YAML wins.
        expect(inserted2.enabled == true,
               "[gate-on] enabled follows YAML (got \(inserted2.enabled))")
        let hasShell2 = inserted2.actions.contains { action in
            if case .shell = action { return true }
            return false
        }
        expect(hasShell2, "[gate-on] .shell action retained (got actions: \(inserted2.actions))")

        print("testShellStrippedWhenGateOff: ok")
    }

    /// IMP-09: bundle IDs that fail `NSWorkspace.urlForApplication` are
    /// soft-dropped from `binding.appBundleIDs` and surfaced in
    /// `Outcome.droppedBundleIDs` + audit `droppedBundleIDs`. The binding is
    /// STILL inserted (this is content-shaping, not a reject gate).
    private static func testInvalidBundleIDSoftDropped(tmp: URL) throws {
        let suiteName = "test.ShortcutYAMLImporter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let auditURL = tmp.appendingPathComponent("audit-bad-bundle.log")
        let auditLog = ShortcutAuditLog(logURL: auditURL, maxBytes: 5 * 1024 * 1024)
        let store = HotkeyBindingsStore(defaults: defaults)
        let importer = ShortcutYAMLImporter(
            store: store,
            registry: HotkeyRegistry.shared,
            auditLog: auditLog,
            userDefaults: defaults
        )

        let yaml = try FixtureLoader.read("importer-bad-bundle.yaml")
        let transcript = "bad bundle test transcript"
        let fakeBundle = "com.nonexistent.fake-app-12345"

        let outcome = importer.importYAML(yaml, transcript: transcript)
        auditLog.flushForTesting()

        expect(outcome.bindingId != nil, "binding inserted with bundle dropped")
        expect(outcome.droppedBundleIDs.contains(fakeBundle),
               "fake bundle in Outcome.droppedBundleIDs (got \(outcome.droppedBundleIDs))")
        expect(outcome.parseError == nil, "no parse error on bundle-soft-drop path")
        expect(outcome.conflictCleared == false, "no conflict for alt+b trigger")

        // Store: binding inserted; appBundleIDs filtered to surviving ids
        // (the fixture has only the fake id, so appBundleIDs should be empty).
        expect(store.bindings.count == 1, "one binding inserted")
        let inserted = store.bindings[0]
        expect(!inserted.appBundleIDs.contains(fakeBundle),
               "fake bundle stripped from binding.appBundleIDs (got \(inserted.appBundleIDs))")

        // Audit log: droppedBundleIDs is a JSON array containing the fake.
        let content = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        expect(lines.count == 1, "exactly one audit line (got \(lines.count))")
        guard let lineData = lines[0].data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: lineData, options: []),
              let dict = any as? [String: Any]
        else {
            fail("audit line did not parse as JSON: \(lines[0])")
        }
        guard let arr = dict["droppedBundleIDs"] as? [Any] else {
            fail("audit droppedBundleIDs must be an array (got \(String(describing: dict["droppedBundleIDs"])))")
        }
        let arrStrings = arr.compactMap { $0 as? String }
        expect(arrStrings.contains(fakeBundle),
               "audit droppedBundleIDs contains fake bundle (got \(arrStrings))")

        print("testInvalidBundleIDSoftDropped: ok")
    }

    /// IMP-05: a `.keyPress` action matching a registered owner's config
    /// REJECTS the import — no store mutation; audit-only with
    /// `parseError: { kind: "actionTriggersVoiceKey", ... }`.
    ///
    /// Pre-registers `.vaultPanel` with `alt+f8` (the fixture's action) so
    /// the `registry.all()` branch fires. Uses `defer { unregister }` +
    /// post-defer count sanity-check to prevent registry bleed
    /// (T-03-04-06 mitigation pattern from P-04).
    private static func testSelfTriggerRejectsWithoutInsert(tmp: URL) throws {
        let suiteName = "test.ShortcutYAMLImporter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Pre-register `alt+f8` so the inner key:alt+f8 action collides.
        guard let cfg = HotkeyConfig.parse("alt+f8") else {
            fail("alt+f8 must parse via HotkeyConfig — check tokenToKeyCode table")
        }
        let beforeCount = HotkeyRegistry.shared.all().count
        HotkeyRegistry.shared.register(cfg, owner: .vaultPanel, purpose: "IMP-05 test fixture")
        defer {
            HotkeyRegistry.shared.unregister(owner: .vaultPanel)
            expect(HotkeyRegistry.shared.all().count == beforeCount,
                   "registry must be clean post-test (got \(HotkeyRegistry.shared.all().count), expected \(beforeCount))")
        }

        let auditURL = tmp.appendingPathComponent("audit-self-trigger.log")
        let auditLog = ShortcutAuditLog(logURL: auditURL, maxBytes: 5 * 1024 * 1024)
        let store = HotkeyBindingsStore(defaults: defaults)
        let importer = ShortcutYAMLImporter(
            store: store,
            registry: HotkeyRegistry.shared,
            auditLog: auditLog,
            userDefaults: defaults
        )

        let yaml = try FixtureLoader.read("importer-self-trigger.yaml")
        let transcript = "self-trigger test transcript"

        expect(store.bindings.isEmpty, "store should be empty pre-import")

        let outcome = importer.importYAML(yaml, transcript: transcript)
        auditLog.flushForTesting()

        // Outcome: reject — no binding, parseError set.
        expect(outcome.bindingId == nil, "self-trigger MUST reject without insert")
        expect(outcome.parseError == "actionTriggersVoiceKey",
               "parseError kind == 'actionTriggersVoiceKey' (got \(String(describing: outcome.parseError)))")
        expect(outcome.conflictCleared == false, "self-trigger is a reject gate, not a clear gate")

        // Store: NO mutation.
        expect(store.bindings.isEmpty, "no store mutation on self-trigger reject")

        // Audit log: ONE line with parseError sub-object kind = actionTriggersVoiceKey.
        let content = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        expect(lines.count == 1, "exactly one audit line on self-trigger path (got \(lines.count))")
        guard let lineData = lines[0].data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: lineData, options: []),
              let dict = any as? [String: Any]
        else {
            fail("audit line did not parse as JSON: \(lines[0])")
        }
        guard let parseErrorDict = dict["parseError"] as? [String: Any] else {
            fail("audit parseError must be a JSON object (got \(String(describing: dict["parseError"])))")
        }
        expect(parseErrorDict["kind"] as? String == "actionTriggersVoiceKey",
               "audit parseError.kind == 'actionTriggersVoiceKey' (got \(String(describing: parseErrorDict["kind"])))")
        let bindingIdVal = dict["bindingId"]
        let isBindingIdNull = bindingIdVal == nil || bindingIdVal is NSNull
        expect(isBindingIdNull, "audit bindingId is null on self-trigger reject")

        print("testSelfTriggerRejectsWithoutInsert: ok")
    }

    // MARK: - P-06 tests (IMP-11 undo + AUD-05 rotation + AUD-06 terminate + TEST-06 sweep)

    /// IMP-11: `removeLastImport(id:)` undoes the most recent voice-imported
    /// binding via defensive id-match.
    /// - Happy path: `id == lastImportedBindingId` → remove from store,
    ///   set `lastImportedBindingId = nil`, write a follow-up audit line
    ///   with `action: "undo"`, `bindingId: <original uuid>`, all other
    ///   AUD-03 fields at their defaults (empty transcript/yaml, all bools
    ///   false, all optionals nil, empty arrays).
    /// - Post-conditions asserted on this RED test:
    ///   - `store.bindings.isEmpty` after undo
    ///   - exactly 2 audit lines total (import then undo)
    ///   - second line's `action == "undo"`, `bindingId == <captured uuid>`,
    ///     `transcript == ""`, `yaml == ""`, `conflictCleared == false`,
    ///     `parseError == nil`, `shellStripped == false`,
    ///     `droppedBundleIDs == []`.
    private static func testRemoveLastImportUndoes(tmp: URL) throws {
        let suiteName = "test.ShortcutYAMLImporter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let auditURL = tmp.appendingPathComponent("audit-undo.log")
        let auditLog = ShortcutAuditLog(logURL: auditURL, maxBytes: 5 * 1024 * 1024)
        let store = HotkeyBindingsStore(defaults: defaults)
        let importer = ShortcutYAMLImporter(
            store: store,
            registry: HotkeyRegistry.shared,
            auditLog: auditLog,
            userDefaults: defaults
        )

        let yaml = """
        version: 1
        shortcut: "alt+g"
        label: "Open Chrome"
        actions:
          - text: "hello"
        """
        let transcript = "按 alt+g 打开 chrome"

        // 1. Happy-path import to seed undo state.
        let outcome = importer.importYAML(yaml, transcript: transcript)
        auditLog.flushForTesting()
        expect(outcome.bindingId != nil, "happy import must return non-nil bindingId")
        let bindingId = outcome.bindingId!
        expect(store.bindings.count == 1, "one binding inserted pre-undo")

        // 2. Undo with the captured id.
        importer.removeLastImport(id: bindingId)
        auditLog.flushForTesting()

        // 3. Store: binding removed.
        expect(store.bindings.isEmpty,
               "store must be empty after undo (got \(store.bindings.count) bindings)")

        // 4. Audit log: exactly 2 lines (import + undo).
        let content = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        expect(lines.count == 2,
               "exactly 2 audit lines after undo (got \(lines.count))")

        // 5. Parse line 2; assert undo shape.
        guard let line2Data = lines[1].data(using: .utf8),
              let any2 = try? JSONSerialization.jsonObject(with: line2Data, options: []),
              let dict2 = any2 as? [String: Any]
        else {
            fail("undo audit line did not parse as JSON: \(lines[1])")
        }
        expect(dict2["action"] as? String == "undo",
               "undo audit line action == 'undo' (got \(String(describing: dict2["action"])))")
        expect(dict2["bindingId"] as? String == bindingId.uuidString,
               "undo audit line bindingId matches original (got \(String(describing: dict2["bindingId"])))")
        expect(dict2["transcript"] as? String == "",
               "undo line has empty transcript (got \(String(describing: dict2["transcript"])))")
        expect(dict2["yaml"] as? String == "",
               "undo line has empty yaml (got \(String(describing: dict2["yaml"])))")
        expect(dict2["conflictCleared"] as? Bool == false,
               "undo line conflictCleared == false")
        let parseErrorVal2 = dict2["parseError"]
        let isParseErrorNull2 = parseErrorVal2 == nil || parseErrorVal2 is NSNull
        expect(isParseErrorNull2,
               "undo line parseError is null (got \(String(describing: parseErrorVal2)))")
        expect(dict2["shellStripped"] as? Bool == false,
               "undo line shellStripped == false")
        if let arr = dict2["droppedBundleIDs"] as? [Any] {
            expect(arr.isEmpty, "undo line droppedBundleIDs is empty (got \(arr))")
        } else {
            fail("undo line droppedBundleIDs must be an array (got \(String(describing: dict2["droppedBundleIDs"])))")
        }

        // 6. Idempotency: calling removeLastImport again with the same id is
        //    a silent no-op because lastImportedBindingId == nil after step 2.
        importer.removeLastImport(id: bindingId)
        auditLog.flushForTesting()
        let contentAfterIdempotent = try String(contentsOf: auditURL, encoding: .utf8)
        let linesAfterIdempotent = contentAfterIdempotent.split(separator: "\n",
                                                                omittingEmptySubsequences: true)
        expect(linesAfterIdempotent.count == 2,
               "idempotent undo MUST NOT write a third audit line (got \(linesAfterIdempotent.count))")

        // 7. AUD-06: importer.terminate() drains the audit queue; safe to call
        //    multiple times. The underlying writer uses open-fresh-per-write,
        //    so this is a flush-only operation.
        importer.terminate()
        importer.terminate()  // idempotency check

        print("testRemoveLastImportUndoes: ok")
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
