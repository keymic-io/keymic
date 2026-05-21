import Foundation

@main
struct PersonaInjectionStrategyTestRunner {
    static func main() {
        testCodableRoundTripAllCases()
        testDecodeMissingFieldDefaults()
        testBuiltInSeedsAllReplaceFocusedText()
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

    static func testDecodeMissingFieldDefaults() {
        // Persona JSON without injectionStrategy — emulates pre-LOR-15 personas.json on disk.
        let json = """
        {
          "id":"u1","name":"Test","icon":"sparkles","stylePrompt":"x",
          "temperature":0.5,"hotkey":null,"contextMode":"none","builtIn":false,
          "createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dec.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            return formatter.date(from: try c.decode(String.self))!
        }
        let p = try! dec.decode(Persona.self, from: json)
        expect(p.injectionStrategy == .replaceFocusedText,
               "missing field should default to .replaceFocusedText, got \(p.injectionStrategy)")
    }

    static func testBuiltInSeedsAllReplaceFocusedText() {
        for seed in Persona.builtInSeeds() {
            expect(seed.injectionStrategy == .replaceFocusedText,
                   "P1 built-in \(seed.id) should be .replaceFocusedText, got \(seed.injectionStrategy)")
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
