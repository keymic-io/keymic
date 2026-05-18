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

        // WR-01: explicit hidden=true round-trip. The default round-trip above
        // exercises hidden=false (memberwise default); this case exercises the
        // encode/decode of hidden=true to lock in that the bit survives.
        let hiddenPersona = Persona(
            id: "test-hidden", name: "Hidden", icon: "eye.slash",
            stylePrompt: "x", temperature: 0.0, hotkey: nil,
            contextMode: .none, builtIn: true, hidden: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let hiddenData = try! JSONEncoder().encode(hiddenPersona)
        let hiddenDecoded = try! JSONDecoder().decode(Persona.self, from: hiddenData)
        expect(hiddenDecoded.hidden == true, "hidden=true round-trips through Codable")
        expect(hiddenDecoded == hiddenPersona, "full equality preserved for hidden persona")

        // Built-in seeds: exactly 5, ids stable (four originals + hidden shortcut-config)
        let seeds = Persona.builtInSeeds()
        expect(seeds.count == 5, "exactly 5 built-in seeds")
        let ids = seeds.map(\.id)
        expect(ids == ["builtin-default", "builtin-translate", "builtin-cli", "builtin-context", "builtin-shortcut-config"],
               "built-in ids in canonical order")
        expect(seeds.allSatisfy { $0.builtIn }, "all seeds marked builtIn")
        expect(seeds[3].contextMode == .selectionAndClipboard, "上下文 persona uses selectionAndClipboard")
        expect(seeds[0].contextMode == .none, "default persona uses .none")

        // Built-in default 沿用 KeyMic 现有的纠错 prompt 文案(关键词)
        expect(seeds[0].stylePrompt.contains("transcription mistakes")
               || seeds[0].stylePrompt.contains("recognition error"),
               "default prompt preserves KeyMic conservative-correction wording")

        print("✅ PersonaTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }
}
