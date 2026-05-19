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

    // P-04: preprocessing-edge fixtures (fences, <think>, BOM, CRLF, smart
    // quotes, tabs, 4-space indent) + inline YAML-11 cases + LineOffsetMap
    // original-coord traceability check.
    private static func runEdgeFixtures() throws {
        // 12 fixture pairs from CONTEXT.md D-A-1 + D-A-2 + D-B-1 + YAML-06.
        // All 12 cleanly preprocess to the SAME canonical ParsedShortcut shape
        // (alt+g, one key:cmd+space, one text:chrome, label:"edge",
        // appBundleIDs empty) — isolating the preprocessing variable.
        let fixtureNames = [
            "edge-01-fence-yaml",
            "edge-02-fence-bare",
            "edge-03-think-block",
            "edge-04-thinking-tag",
            "edge-05-reasoning-tag",
            "edge-06-fence-then-think",
            "edge-07-prose-leading",
            "edge-08-bom",
            "edge-09-crlf",
            "edge-10-smart-quotes",
            "edge-11-tabs-to-spaces",
            "edge-12-indent-4-space",
        ]
        for name in fixtureNames {
            let raw = try FixtureLoader.read("\(name).yaml")
            let parsed: ParsedShortcut
            do {
                parsed = try ShortcutYAMLParser.parse(raw)
            } catch {
                fail("\(name): preprocessing/parse failed unexpectedly: \(error)")
            }

            // Cross-check against the .expected.json projection. Eleven of
            // twelve share the same canonical shape; edge-10 differs only in
            // that label was normalized from curly to ASCII quotes (which is
            // recorded in its expected.json as ASCII).
            let expectedJSON = try FixtureLoader.read("\(name).expected.json")
            let expectedData = expectedJSON.data(using: .utf8)!
            let any = try JSONSerialization.jsonObject(with: expectedData, options: [])
            guard let dict = any as? [String: Any],
                  let bindingDict = dict["binding"] as? [String: Any],
                  let actionsArr = bindingDict["actions"] as? [[String: Any]],
                  let trigger = bindingDict["trigger"] as? String,
                  let enabled = bindingDict["enabled"] as? Bool
            else {
                fail("\(name): expected.json shape invalid")
            }
            // Top-level field equality
            expect(parsed.binding.trigger == trigger,
                   "\(name): trigger mismatch — expected=\(trigger), got=\(parsed.binding.trigger)")
            expect(parsed.binding.enabled == enabled,
                   "\(name): enabled mismatch — expected=\(enabled), got=\(parsed.binding.enabled)")
            // Label may be a String OR omitted (we always set it in fixtures).
            if let expLabel = dict["label"] as? String {
                expect(parsed.label == expLabel,
                       "\(name): label mismatch — expected=\(expLabel.debugDescription), got=\(String(describing: parsed.label).debugDescription)")
            }
            // appBundleIDs — list of strings (default empty if not declared)
            let expBundles = (bindingDict["appBundleIDs"] as? [String]) ?? []
            expect(parsed.binding.appBundleIDs == expBundles,
                   "\(name): appBundleIDs mismatch — expected=\(expBundles), got=\(parsed.binding.appBundleIDs)")
            // Actions list length first
            expect(parsed.binding.actions.count == actionsArr.count,
                   "\(name): actions count mismatch — expected=\(actionsArr.count), got=\(parsed.binding.actions.count)")
            // Per-action: we only need to cover keyPress + typeText in this
            // P-04 fixture set (all 12 use the same 2-action shape).
            for (i, exp) in actionsArr.enumerated() where i < parsed.binding.actions.count {
                guard let type = exp["type"] as? String else {
                    fail("\(name): actions[\(i)] missing 'type' in expected.json")
                }
                switch (type, parsed.binding.actions[i]) {
                case ("keyPress", .keyPress(let kc, let mods)):
                    guard let expKc = exp["keyCode"] as? NSNumber,
                          let expMods = exp["modifiers"] as? NSNumber
                    else {
                        fail("\(name): actions[\(i)] keyPress missing keyCode/modifiers")
                    }
                    expect(UInt16(truncating: expKc) == kc,
                           "\(name): actions[\(i)] keyCode mismatch — expected=\(expKc), got=\(kc)")
                    expect(UInt64(truncating: expMods) == mods,
                           "\(name): actions[\(i)] modifiers mismatch — expected=\(expMods), got=\(mods)")
                case ("typeText", .typeText(let s)):
                    guard let expText = exp["text"] as? String else {
                        fail("\(name): actions[\(i)] typeText missing 'text' field")
                    }
                    expect(expText == s,
                           "\(name): actions[\(i)] text mismatch — expected=\(expText.debugDescription), got=\(s.debugDescription)")
                default:
                    fail("\(name): actions[\(i)] type mismatch — expected=\(type), got=\(parsed.binding.actions[i])")
                }
            }
        }

        // YAML-11 inline assertions (D-A-1 + D-A-2 corollaries).

        // 1) Empty input → .empty.
        do {
            _ = try ShortcutYAMLParser.parse("")
            fail("YAML-11: empty string should throw .empty but parse succeeded")
        } catch let err as ShortcutYAMLError {
            switch err {
            case .empty: break // pass
            default: fail("YAML-11: empty string threw wrong variant: \(err)")
            }
        } catch {
            fail("YAML-11: empty string threw non-ShortcutYAMLError: \(error)")
        }

        // 2) Only-think input → .empty (preprocessing strips everything).
        do {
            _ = try ShortcutYAMLParser.parse("<think>just thoughts</think>")
            fail("YAML-11: only-think input should throw .empty but parse succeeded")
        } catch let err as ShortcutYAMLError {
            switch err {
            case .empty: break // pass
            default: fail("YAML-11: only-think threw wrong variant: \(err)")
            }
        } catch {
            fail("YAML-11: only-think threw non-ShortcutYAMLError: \(error)")
        }

        // 3) version + label but no shortcut: → .missingShortcut.
        do {
            _ = try ShortcutYAMLParser.parse("version: 1\nlabel: \"foo\"")
            fail("YAML-11: missing shortcut should throw .missingShortcut but parse succeeded")
        } catch let err as ShortcutYAMLError {
            switch err {
            case .missingShortcut: break // pass
            default: fail("YAML-11: no-shortcut threw wrong variant: \(err)")
            }
        } catch {
            fail("YAML-11: no-shortcut threw non-ShortcutYAMLError: \(error)")
        }

        // 4) D-A-2: unclosed reasoning tag → .unclosedThinkBlock(tag:, line:)
        //    Opener at original line 1.
        do {
            _ = try ShortcutYAMLParser.parse("<think>truncated yaml here")
            fail("D-A-2: unclosed <think> should throw .unclosedThinkBlock but parse succeeded")
        } catch let err as ShortcutYAMLError {
            switch err {
            case .unclosedThinkBlock(let tag, let line):
                expect(tag == "think",
                       "D-A-2: unclosed-think tag mismatch — expected 'think', got '\(tag)'")
                expect(line == 1,
                       "D-A-2: unclosed-think line mismatch — expected 1, got \(line)")
            default:
                fail("D-A-2: unclosed-think threw wrong variant: \(err)")
            }
        } catch {
            fail("D-A-2: unclosed-think threw non-ShortcutYAMLError: \(error)")
        }

        // 5) D-B-1 original-coord traceability check.
        //    The yaml body's `shortcut:` line is line 7 in the ORIGINAL raw
        //    input (after a 5-line <think> preamble + a `version: 1` line).
        //    After preprocessing strips the 5-line preamble, the line is at
        //    processed-line 2. The thrown .invalidValue MUST carry line=7,
        //    proving LineOffsetMap maps cleaned→original.
        let traceabilityInput = """
            <think>
            line 2 of think
            line 3 of think
            line 4 of think
            </think>
            version: 1
            shortcut: "not-a-real-key"
            """
        do {
            _ = try ShortcutYAMLParser.parse(traceabilityInput)
            fail("D-B-1: bad shortcut should throw .invalidValue but parse succeeded")
        } catch let err as ShortcutYAMLError {
            switch err {
            case .invalidValue(let field, let line, _):
                expect(field == "shortcut",
                       "D-B-1: traceability field mismatch — expected 'shortcut', got '\(field)'")
                expect(line == 7,
                       "D-B-1: traceability line mismatch — expected 7 (original), got \(line). LineOffsetMap regression?")
            default:
                fail("D-B-1: traceability threw wrong variant: \(err)")
            }
        } catch {
            fail("D-B-1: traceability threw non-ShortcutYAMLError: \(error)")
        }
    }

    // P-05: per-ShortcutYAMLError-variant error fixtures.
    //
    // Each fixture pair (`error-NN-*.yaml` + `error-NN-*.expected-error.json`)
    // asserts the exact (kind, field, line, token) shape per CONTEXT.md D-B-2.
    // `.empty` and `.missingShortcut` are covered inline by runEdgeFixtures
    // (P-04 / YAML-11) — these 11 fixtures cover the remaining 7 unique enum
    // kinds (`.invalidValue` repeats across multiple fixtures by design).
    //
    // The matcher's switch over ShortcutYAMLError is **exhaustive** — no
    // `default:` arm. If a 10th variant is added without test coverage, Swift
    // will fail compile of this file (T-02-05-02).
    private static func runErrorFixtures() throws {
        let errorFixtures = [
            "error-01-malformed-action",
            "error-02-unknown-action-key",
            "error-03-invalid-key-value",
            "error-04-invalid-shortcut-value",
            "error-05-text-too-long",
            "error-06-invalid-wait",
            "error-07-invalid-enabled",
            "error-08-invalid-indent-mixed",
            "error-09-unclosed-think",
            "error-10-unclosed-string",
            "error-11-duplicate-field",
            "error-12-wait-nan",
            "error-13-trailing-after-quote",
            "error-14-trailing-after-single-quote",
        ]
        for name in errorFixtures {
            let raw = try FixtureLoader.read("\(name).yaml")
            let expectedJSON = try FixtureLoader.read("\(name).expected-error.json")
            let expectedData = expectedJSON.data(using: .utf8)!
            guard let expectedDict = try JSONSerialization.jsonObject(with: expectedData, options: []) as? [String: Any] else {
                fail("\(name): expected-error.json is not a JSON object")
            }
            do {
                _ = try ShortcutYAMLParser.parse(raw)
                fail("\(name): expected throw but parse succeeded")
            } catch let err as ShortcutYAMLError {
                let result = matches(err, expectedDict)
                if !result.ok {
                    fail("\(name): \(result.detail)")
                }
            } catch {
                fail("\(name): unexpected non-ShortcutYAMLError thrown: \(error)")
            }
        }
        print("runErrorFixtures: \(errorFixtures.count) fixtures verified")

        // CR-01 regression: `wait:` parser MUST reject every non-finite,
        // negative, and absurd-magnitude Double-parseable token without
        // trapping on the downstream Int(*) conversion. `Double("inf")`,
        // `Double("nan")`, and `Double("1e30")` all succeed; the parser-side
        // guard is the only thing standing between attacker input and a
        // process crash.
        for badWait in ["inf", "-inf", "1e30", "-1.0"] {
            let yaml = """
                version: 1
                shortcut: "alt+g"
                actions:
                  - wait: \(badWait)
                """
            do {
                _ = try ShortcutYAMLParser.parse(yaml)
                fail("CR-01: wait: \(badWait) should throw .invalidValue but parse succeeded")
            } catch let err as ShortcutYAMLError {
                switch err {
                case .invalidValue(let field, _, _):
                    expect(field == "wait",
                           "CR-01: wait: \(badWait) threw .invalidValue with wrong field — expected 'wait', got '\(field)'")
                default:
                    fail("CR-01: wait: \(badWait) threw wrong variant: \(err)")
                }
            } catch {
                fail("CR-01: wait: \(badWait) threw non-ShortcutYAMLError: \(error)")
            }
        }

        // WR-02 regression: a lone trailing `\` inside an unterminated
        // double-quoted string must throw `.invalidValue(field:, token:"\\")`
        // BEFORE the loop falls through to `.unclosedString`. Without the
        // explicit guard, the parser silently appended `\` to the output
        // buffer and then masked the issue by throwing `.unclosedString` —
        // a defense-in-depth violation against D-B-1.
        do {
            // Input: `text: "abc\` — opening quote, three chars, lone backslash, EOF.
            // The unquote(...) call here receives `"abc\` (after trimming).
            let yaml = "version: 1\nshortcut: \"alt+g\"\nactions:\n  - text: \"abc\\"
            _ = try ShortcutYAMLParser.parse(yaml)
            fail("WR-02: lone trailing backslash should throw .invalidValue but parse succeeded")
        } catch let err as ShortcutYAMLError {
            switch err {
            case .invalidValue(let field, _, let token):
                expect(field == "text",
                       "WR-02: trailing-\\ threw .invalidValue with wrong field — expected 'text', got '\(field)'")
                expect(token == "\\",
                       "WR-02: trailing-\\ threw .invalidValue with wrong token — expected '\\', got '\(String(describing: token))'")
            default:
                fail("WR-02: trailing-\\ threw wrong variant: \(err) — fix-order regression?")
            }
        } catch {
            fail("WR-02: trailing-\\ threw non-ShortcutYAMLError: \(error)")
        }
    }

    /// Exhaustive matcher for `ShortcutYAMLError` vs the JSON shape in
    /// `.expected-error.json`. Returns `(ok: Bool, detail: String)` so the
    /// failure message can identify both expected and actual values.
    ///
    /// **No `default:` arm** — adding a 10th case to `ShortcutYAMLError` MUST
    /// force this switch to update at compile time (T-02-05-02).
    private static func matches(
        _ err: ShortcutYAMLError,
        _ expected: [String: Any]
    ) -> (ok: Bool, detail: String) {
        let expKind = (expected["kind"] as? String) ?? ""
        switch err {
        case .empty:
            if expKind != "empty" {
                return (false, "expected kind=\(expKind), got .empty")
            }
            return (true, "")

        case .missingShortcut:
            if expKind != "missingShortcut" {
                return (false, "expected kind=\(expKind), got .missingShortcut")
            }
            return (true, "")

        case .malformedAction(let line):
            if expKind != "malformedAction" {
                return (false, "expected kind=\(expKind), got .malformedAction(line:\(line))")
            }
            guard let expLine = (expected["line"] as? NSNumber).map({ $0.intValue }) else {
                return (false, ".malformedAction: expected.json missing 'line'")
            }
            if line != expLine {
                return (false, ".malformedAction: line mismatch — expected \(expLine), got \(line)")
            }
            return (true, "")

        case .unknownActionKey(let line, let key):
            if expKind != "unknownActionKey" {
                return (false, "expected kind=\(expKind), got .unknownActionKey(line:\(line), key:\(key))")
            }
            guard let expLine = (expected["line"] as? NSNumber).map({ $0.intValue }) else {
                return (false, ".unknownActionKey: expected.json missing 'line'")
            }
            if line != expLine {
                return (false, ".unknownActionKey: line mismatch — expected \(expLine), got \(line)")
            }
            guard let expKey = expected["key"] as? String else {
                return (false, ".unknownActionKey: expected.json missing 'key'")
            }
            if key != expKey {
                return (false, ".unknownActionKey: key mismatch — expected \(expKey), got \(key)")
            }
            return (true, "")

        case .invalidValue(let field, let line, let offendingToken):
            if expKind != "invalidValue" {
                return (false, "expected kind=\(expKind), got .invalidValue(field:\(field), line:\(line), token:\(String(describing: offendingToken)))")
            }
            guard let expField = expected["field"] as? String else {
                return (false, ".invalidValue: expected.json missing 'field'")
            }
            if field != expField {
                return (false, ".invalidValue: field mismatch — expected \(expField), got \(field)")
            }
            guard let expLine = (expected["line"] as? NSNumber).map({ $0.intValue }) else {
                return (false, ".invalidValue: expected.json missing 'line'")
            }
            if line != expLine {
                return (false, ".invalidValue: line mismatch — expected \(expLine), got \(line)")
            }
            // token is nil-tolerant: JSON null maps to NSNull, string to String.
            if let expTokenAny = expected["token"] {
                if expTokenAny is NSNull {
                    if offendingToken != nil {
                        return (false, ".invalidValue: token mismatch — expected null, got \(offendingToken!)")
                    }
                } else if let expToken = expTokenAny as? String {
                    if offendingToken != expToken {
                        return (false, ".invalidValue: token mismatch — expected \(expToken.debugDescription), got \(String(describing: offendingToken).debugDescription)")
                    }
                } else {
                    return (false, ".invalidValue: token field has wrong type in expected.json")
                }
            }
            return (true, "")

        case .invalidIndent(let line, let offendingIndent):
            if expKind != "invalidIndent" {
                return (false, "expected kind=\(expKind), got .invalidIndent(line:\(line), offendingIndent:\(String(describing: offendingIndent)))")
            }
            guard let expLine = (expected["line"] as? NSNumber).map({ $0.intValue }) else {
                return (false, ".invalidIndent: expected.json missing 'line'")
            }
            if line != expLine {
                return (false, ".invalidIndent: line mismatch — expected \(expLine), got \(line)")
            }
            if let expIndentAny = expected["offendingIndent"] {
                if expIndentAny is NSNull {
                    if offendingIndent != nil {
                        return (false, ".invalidIndent: offendingIndent mismatch — expected null, got \(offendingIndent!.debugDescription)")
                    }
                } else if let expIndent = expIndentAny as? String {
                    if offendingIndent != expIndent {
                        return (false, ".invalidIndent: offendingIndent mismatch — expected \(expIndent.debugDescription), got \(String(describing: offendingIndent).debugDescription)")
                    }
                } else {
                    return (false, ".invalidIndent: offendingIndent has wrong type in expected.json")
                }
            }
            return (true, "")

        case .unclosedThinkBlock(let tag, let line):
            if expKind != "unclosedThinkBlock" {
                return (false, "expected kind=\(expKind), got .unclosedThinkBlock(tag:\(tag), line:\(line))")
            }
            guard let expTag = expected["tag"] as? String else {
                return (false, ".unclosedThinkBlock: expected.json missing 'tag'")
            }
            if tag != expTag {
                return (false, ".unclosedThinkBlock: tag mismatch — expected \(expTag), got \(tag)")
            }
            guard let expLine = (expected["line"] as? NSNumber).map({ $0.intValue }) else {
                return (false, ".unclosedThinkBlock: expected.json missing 'line'")
            }
            if line != expLine {
                return (false, ".unclosedThinkBlock: line mismatch — expected \(expLine), got \(line)")
            }
            return (true, "")

        case .unclosedString(let line):
            if expKind != "unclosedString" {
                return (false, "expected kind=\(expKind), got .unclosedString(line:\(line))")
            }
            guard let expLine = (expected["line"] as? NSNumber).map({ $0.intValue }) else {
                return (false, ".unclosedString: expected.json missing 'line'")
            }
            if line != expLine {
                return (false, ".unclosedString: line mismatch — expected \(expLine), got \(line)")
            }
            return (true, "")

        case .duplicateField(let field, let firstLine, let secondLine):
            if expKind != "duplicateField" {
                return (false, "expected kind=\(expKind), got .duplicateField(field:\(field), firstLine:\(firstLine), secondLine:\(secondLine))")
            }
            guard let expField = expected["field"] as? String else {
                return (false, ".duplicateField: expected.json missing 'field'")
            }
            if field != expField {
                return (false, ".duplicateField: field mismatch — expected \(expField), got \(field)")
            }
            guard let expFirst = (expected["firstLine"] as? NSNumber).map({ $0.intValue }) else {
                return (false, ".duplicateField: expected.json missing 'firstLine'")
            }
            if firstLine != expFirst {
                return (false, ".duplicateField: firstLine mismatch — expected \(expFirst), got \(firstLine)")
            }
            guard let expSecond = (expected["secondLine"] as? NSNumber).map({ $0.intValue }) else {
                return (false, ".duplicateField: expected.json missing 'secondLine'")
            }
            if secondLine != expSecond {
                return (false, ".duplicateField: secondLine mismatch — expected \(expSecond), got \(secondLine)")
            }
            return (true, "")
        }
    }

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
        //
        // WR-01 regression: the previous `%g` formatter rounded to 6 sig figs,
        // so ms = 1_234_567 encoded to "1234.57" and reparsed to 1234570 —
        // a silent data loss for any non-round ms value above ~10^6. Include
        // a 7-sig-digit value here to lock the round-trip invariant against
        // future formatter regressions. (Bounded below the CR-01 cap of
        // 86 400 s = 86_400_000 ms, which `buildAction` would reject.)
        let waitBinding = HotkeyBinding(
            trigger: "alt+g",
            actions: [
                .wait(ms: 1500),
                .wait(ms: 1000),
                .wait(ms: 250),
                .wait(ms: 1_234_567),   // WR-01: 7 sig digits
                .wait(ms: 86_399_999),  // CR-01 cap boundary: max ms below 86 400 s
            ],
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
