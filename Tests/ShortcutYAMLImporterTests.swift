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
        // P-04 / P-05 / P-06 will append additional try testX(tmp:) calls here.

        print("ShortcutYAMLImporterTests passed")
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
