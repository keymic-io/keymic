import Foundation

@main
struct PersonaTestRunner {
    static func main() {
        // Codable round-trip preserves all fields including new ones.
        let p = Persona(
            id: "test",
            name: "Test",
            icon: "sparkles",
            stylePrompt: "do nothing",
            temperature: 0.5,
            hotkey: "alt+q",
            contextMode: .selectionAndClipboard,
            contextCount: 3,
            outputStrategy: .openURL(template: "https://example.com/?q={query}"),
            builtIn: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let data = try! JSONEncoder().encode(p)
        let decoded = try! JSONDecoder().decode(Persona.self, from: data)
        expect(decoded == p, "full round-trip")

        // OutputStrategy cases survive round-trip.
        for strat in allStrategies() {
            let pp = Persona(
                id: "s",
                name: "s",
                icon: "x",
                stylePrompt: "",
                temperature: 0.0,
                hotkey: nil,
                contextMode: .none,
                contextCount: 1,
                outputStrategy: strat,
                builtIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            let d = try! JSONEncoder().encode(pp)
            let r = try! JSONDecoder().decode(Persona.self, from: d)
            expect(r.outputStrategy == strat, "OutputStrategy round-trip: \(strat)")
        }

        // ContextMode case count.
        expect(ContextMode.allCases.count == 6, "ContextMode has 6 cases")

        // Built-in seeds default to .replaceFocusedText with contextCount 1.
        for seed in Persona.builtInSeeds() {
            expect(seed.outputStrategy == .replaceFocusedText,
                "built-in \(seed.id) defaults to .replaceFocusedText")
            expect(seed.contextCount == 1,
                "built-in \(seed.id) defaults to contextCount = 1")
        }

        print("PersonaTests passed")
    }

    static func allStrategies() -> [OutputStrategy] {
        [
            .replaceFocusedText,
            .replaceSelection,
            .clipboard,
            .openURL(template: "https://x.test/{query}"),
            .runShell(command: "echo", confirm: true),
            .iTermPane(confirm: true),
        ]
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
