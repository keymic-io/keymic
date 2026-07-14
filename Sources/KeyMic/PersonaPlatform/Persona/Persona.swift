import Foundation

struct Persona: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String           // SF Symbol name
    var stylePrompt: String
    var temperature: Double    // 0.0 ... 2.0
    var hotkey: String?        // HotkeyConfig.encode() format, e.g. "alt+q"
    var contextSources: Set<ContextSource>
    var builtIn: Bool
    var createdAt: Date
    var updatedAt: Date
    var injectionStrategy: InjectionStrategy

    static let temperatureRange: ClosedRange<Double> = 0.0 ... 2.0

    init(id: String, name: String, icon: String, stylePrompt: String,
         temperature: Double, hotkey: String?,
         contextSources: Set<ContextSource>,
         builtIn: Bool, createdAt: Date, updatedAt: Date,
         injectionStrategy: InjectionStrategy = .replaceFocusedText) {
        self.id = id
        self.name = name
        self.icon = icon
        self.stylePrompt = stylePrompt
        self.temperature = temperature
        self.hotkey = hotkey
        self.contextSources = contextSources
        self.builtIn = builtIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.injectionStrategy = injectionStrategy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, stylePrompt, temperature, hotkey
        case contextSources, builtIn, createdAt, updatedAt, injectionStrategy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.icon = try c.decode(String.self, forKey: .icon)
        self.stylePrompt = try c.decode(String.self, forKey: .stylePrompt)
        self.temperature = try c.decode(Double.self, forKey: .temperature)
        self.hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        // LOR-18: contextSources is canonical. Migrate from legacy "contextMode" string if absent.
        if let stored = try c.decodeIfPresent(Set<ContextSource>.self, forKey: .contextSources) {
            self.contextSources = stored
        } else {
            self.contextSources = try Self.decodeLegacyContextMode(decoder)
        }
        self.builtIn = try c.decode(Bool.self, forKey: .builtIn)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.injectionStrategy = try c.decodeIfPresent(InjectionStrategy.self,
                                                       forKey: .injectionStrategy) ?? .replaceFocusedText
    }

    private static func decodeLegacyContextMode(_ decoder: Decoder) throws -> Set<ContextSource> {
        // Legacy "contextMode" was a top-level string. Read it via a side-channel struct
        // since the main CodingKeys no longer includes that case.
        struct Legacy: Decodable { let contextMode: String? }
        let legacy = try? Legacy(from: decoder)
        switch legacy?.contextMode {
        case "selectionAndClipboard":
            return [.selection, .clipboardTop]
        default:
            return []
        }
    }

    /// Built-in personas seeded on first launch. Order is stable.
    /// Built-ins: name + builtIn flag are immutable in UI; stylePrompt + icon + temperature + hotkey + contextSources editable.
    static func builtInSeeds() -> [Persona] {
        let now = Date()
        return [
            Persona(
                id: "builtin-default",
                name: String(localized: "Speech Polish"),
                icon: "sparkles",
                stylePrompt: """
                    You are a conservative speech recognition error corrector. \
                    ONLY fix clear, obvious transcription mistakes. When in doubt, leave the text unchanged.

                    What to fix:
                    - English words/acronyms wrongly rendered as sound-alike tokens or Chinese characters \
                    (e.g. "pie-thon" → "Python", "jay-son" → "JSON", "A P eye" → "API")
                    - Obvious Chinese homophone errors where context makes the correct character clear
                    - Broken English words or phrases split/merged incorrectly by the recognizer

                    What NOT to do:
                    - Do NOT rephrase, rewrite, or "improve" any text
                    - Do NOT add or remove words beyond fixing recognition errors
                    - Do NOT change text that could plausibly be correct
                    - Do NOT alter punctuation unless clearly wrong

                    If the input appears correct, return it exactly as-is. Return ONLY the text, nothing else.
                    """,
                temperature: 0.3,
                hotkey: nil,
                contextSources: [],
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-translate",
                name: "Auto Translate",
                icon: "globe",
                stylePrompt: "Detect the input language and translate it into English. Keep the tone professional and fluent. Preserve technical terms, code identifiers, product names, and numbers as-is. If the input is already English, return it unchanged apart from fixing obvious transcription errors. Return ONLY the translated text — no explanations, no quotes.",
                temperature: 0.6,
                hotkey: nil,
                contextSources: [],
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-cli",
                name: "CLI Wizard",
                icon: "terminal",
                stylePrompt: "Convert the voice transcription into ONE executable shell command for macOS (zsh). Be concise and accurate for technical users. Prefer tools available on a standard macOS install. Return ONLY the command — a single line, no markdown fences, no leading \"$\", no explanations.",
                temperature: 0.1,
                hotkey: nil,
                contextSources: [],
                builtIn: true,
                createdAt: now,
                updatedAt: now,
                injectionStrategy: .runShell(commandTemplate: "{query}")
            ),
            Persona(
                id: "builtin-context",
                name: "Context",
                icon: "text.quote",
                stylePrompt: """
                    You may receive some of these inputs (any of them can be absent):
                    1. [Selected text] — text currently selected in the foreground app
                    2. [Recent clipboard] — the most recent clipboard text
                    3. [User said] — the user's speech transcription

                    Treat [User said] as the instruction. Apply it to [Selected text] if present, \
                    otherwise to [Recent clipboard].

                    Example:
                    [User said]: change into upper case
                    [Selected text]: 01a6c93f-eb7f-4605-93a3-0c0ea3d5c02d
                    [Return text]: 01A6C93F-EB7F-4605-93A3-0C0EA3D5C02D

                    If [User said] is empty, meaningless, or completely unrelated to \
                    [Selected text] / [Recent clipboard], return an empty string.

                    If there is no context, perform normal transcription correction on the input. \
                    Return ONLY the resulting text — no labels, no explanations.
                    """,
                temperature: 0.5,
                hotkey: nil,
                contextSources: [.selection, .clipboardTop],
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-general-editor",
                name: "General Editor",
                icon: "pencil.and.outline",
                stylePrompt: """
                    You are a precise editor. Input arrives as [Selected text] (the text to rewrite) and \
                    [User said] (a brief instruction). Rewrite [Selected text] according to the instruction. \
                    Return ONLY the rewritten text — no preamble, no explanations, no quotes, no markdown \
                    fences. Preserve the original language unless the instruction asks otherwise.
                    """,
                temperature: 0.4,
                hotkey: nil,
                contextSources: [.selection],
                builtIn: true,
                createdAt: now,
                updatedAt: now,
                injectionStrategy: .replaceSelection
            ),
        ]
    }
}
