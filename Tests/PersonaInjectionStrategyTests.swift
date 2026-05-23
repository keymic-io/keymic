import Foundation

@main
struct PersonaInjectionStrategyTestRunner {
    static func main() {
        testCodableRoundTripAllCases()
        testMissingInjectionStrategyDefaults()
        testLegacyDecodeSelectionAndClipboardContextModeMaps()
        testLegacyDecodeNoneContextModeMaps()
        testNewFieldWinsOverLegacyContextMode()
        testBuiltInSeedsHaveCanonicalStrategy()
        testOpenURLTemplatePreserved()
        print("✅ PersonaInjectionStrategyTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }

    static func testCodableRoundTripAllCases() {
        let cases: [InjectionStrategy] = [
            .replaceFocusedText,
            .replaceSelection,
            .clipboard,
            .openURL(template: "https://example.com?q={query}"),
            .runShell(commandTemplate: "echo {query}"),
            .writeToITermPane(paneIndex: 0),
        ]
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        for c in cases {
            let data = try! enc.encode(c)
            let round = try! dec.decode(InjectionStrategy.self, from: data)
            expect(round == c, "round-trip failed for \(c)")
        }
    }

    static func testMissingInjectionStrategyDefaults() {
        // Legacy pre-LOR-15 JSON: no injectionStrategy field should default to .replaceFocusedText.
        let json = """
          {
          "id":"i","name":"I","icon":"star","stylePrompt":"sp",
          "temperature":0.5,"hotkey":null,
          "contextMode":"none","contextSources":[],
          "builtIn":false,"createdAt":0.0,"updatedAt":0.0
          }
          """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let d = try c.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: d)
        }
        let p = try! dec.decode(Persona.self, from: json)
        expect(p.injectionStrategy == .replaceFocusedText,
               "missing injectionStrategy field should default to .replaceFocusedText, got \(p.injectionStrategy)")
    }

    static func testLegacyDecodeSelectionAndClipboardContextModeMaps() {
        // Legacy pre-LOR-18 JSON: contextMode="selectionAndClipboard" with no contextSources
        // should migrate to [.selection, .clipboardTop].
        let json = """
          {
          "id":"x","name":"X","icon":"star","stylePrompt":"sp",
          "temperature":0.5,"hotkey":null,"contextMode":"selectionAndClipboard","builtIn":false,
          "createdAt":0.0,"updatedAt":0.0
          }
          """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let d = try c.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: d)
        }
        let p = try! dec.decode(Persona.self, from: json)
        expect(p.contextSources == [.selection, .clipboardTop],
               "legacy contextMode=selectionAndClipboard should migrate to [.selection, .clipboardTop], got \(p.contextSources)")
    }

    static func testLegacyDecodeNoneContextModeMaps() {
        let json = """
          {
          "id":"y","name":"Y","icon":"star","stylePrompt":"sp",
          "temperature":0.5,"hotkey":null,"contextMode":"none","builtIn":false,
          "createdAt":0.0,"updatedAt":0.0
          }
          """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let d = try c.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: d)
        }
        let p = try! dec.decode(Persona.self, from: json)
        expect(p.contextSources == [], "legacy contextMode=none should migrate to empty set, got \(p.contextSources)")
    }

    static func testNewFieldWinsOverLegacyContextMode() {
        // When BOTH fields are present in JSON, contextSources is canonical and wins
        // over the legacy contextMode-derived default. Locks in Persona.init(from:)'s
        // decodeIfPresent precedence.
        let json = """
          {
          "id":"z","name":"Z","icon":"star","stylePrompt":"sp",
          "temperature":0.5,"hotkey":null,
          "contextMode":"none","contextSources":["selection","clipboardTop"],
          "builtIn":false,"createdAt":0.0,"updatedAt":0.0
          }
          """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let d = try c.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: d)
        }
        let p = try! dec.decode(Persona.self, from: json)
        expect(p.contextSources == [.selection, .clipboardTop],
               "contextSources should win over contextMode default; got \(p.contextSources)")
    }

    static func testBuiltInSeedsHaveCanonicalStrategy() {
        // Voice-pipeline built-ins default to replaceFocusedText (current paste behavior).
        // The General Editor seed drives the LOR-16 in-place edit flow → replaceSelection.
        let expected: [String: InjectionStrategy] = [
            "builtin-default": .replaceFocusedText,
            "builtin-translate": .replaceFocusedText,
            "builtin-cli": .replaceFocusedText,
            "builtin-context": .replaceFocusedText,
            "builtin-general-editor": .replaceSelection,
            "builtin-clipboard-transformer": .clipboard,
        ]
        for seed in Persona.builtInSeeds() {
            guard let want = expected[seed.id] else {
                expect(false, "unexpected built-in seed id: \(seed.id)")
                continue
            }
            expect(seed.injectionStrategy == want,
                   "built-in \(seed.id) should be \(want), got \(seed.injectionStrategy)")
        }
    }

    static func testOpenURLTemplatePreserved() {
        let s = InjectionStrategy.openURL(template: "https://google.com/search?q={query}")
        let data = try! JSONEncoder().encode(s)
        let round = try! JSONDecoder().decode(InjectionStrategy.self, from: data)
        if case .openURL(let t) = round {
            expect(t == "https://google.com/search?q={query}", "template lost")
        } else {
            expect(false, "decoded as wrong case: \(round)")
        }
    }
}
