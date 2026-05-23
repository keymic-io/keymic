import Foundation

@main
struct PersonaTestRunner {
    static func main() {
        // Codable round-trip preserves all fields
        let p = Persona(
            id: "test",
            name: "Test",
            icon: "sparkles",
            stylePrompt: "do nothing",
            temperature: 0.5,
            hotkey: "alt+q",
            contextMode: .selectionAndClipboard,
            builtIn: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let data = try! JSONEncoder().encode(p)
        let decoded = try! JSONDecoder().decode(Persona.self, from: data)
        expect(decoded == p, "Codable round-trip preserves equality")
        expect(decoded.contextMode == .selectionAndClipboard, "contextMode round-trips")

        // Built-in seeds: exactly 5, ids stable
        let seeds = Persona.builtInSeeds()
        expect(seeds.count == 5, "exactly 5 built-in seeds")
        let ids = seeds.map(\.id)
        expect(ids == [
            "builtin-default",
            "builtin-translate",
            "builtin-cli",
            "builtin-context",
            "builtin-general-editor",
        ], "built-in ids in canonical order")
        expect(seeds.allSatisfy { $0.builtIn }, "all seeds marked builtIn")
        expect(seeds[3].contextMode == .selectionAndClipboard, "上下文 persona uses selectionAndClipboard")
        expect(seeds[0].contextMode == .none, "default persona uses .none")
        expect(seeds[4].injectionStrategy == .replaceSelection,
               "general-editor persona uses replaceSelection strategy")

        // Built-in default 沿用 KeyMic 现有的纠错 prompt 文案(关键词)
        expect(seeds[0].stylePrompt.contains("transcription mistakes")
               || seeds[0].stylePrompt.contains("recognition error"),
               "default prompt preserves KeyMic conservative-correction wording")

        // LOR-18: contextSources derived from contextMode by default
        let seedsBuiltIn = Persona.builtInSeeds()
        expect(seedsBuiltIn[0].contextSources == [], "default persona contextSources should be empty")
        expect(seedsBuiltIn[1].contextSources == [], "translate persona contextSources should be empty")
        expect(seedsBuiltIn[2].contextSources == [], "cli persona contextSources should be empty")
        expect(seedsBuiltIn[3].contextSources == [.selection, .clipboardTop], "context persona contextSources should be [selection, clipboardTop]")
        expect(seedsBuiltIn[4].contextSources == [.selection], "general-editor persona contextSources should be [selection]")

        print("✅ PersonaTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }
}
