import Foundation

enum ContextMode: String, Codable, CaseIterable {
    case none
    case selection
    case clipboard
    case clipboardHistory          // count comes from persona.contextCount
    case selectionAndClipboard
    case windowOCR

    var displayName: String {
        switch self {
        case .none: return String(localized: "None")
        case .selection: return String(localized: "Selected text")
        case .clipboard: return String(localized: "Clipboard")
        case .clipboardHistory: return String(localized: "Clipboard history")
        case .selectionAndClipboard: return String(localized: "Selection + Clipboard")
        case .windowOCR: return String(localized: "Window OCR")
        }
    }
}

enum OutputStrategy: Codable, Equatable {
    case replaceFocusedText
    case replaceSelection
    case clipboard
    case openURL(template: String)
    case runShell(command: String, confirm: Bool)
    case iTermPane(confirm: Bool)
}

struct Persona: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String           // SF Symbol name
    var stylePrompt: String
    var temperature: Double    // 0.0 ... 2.0
    var hotkey: String?        // HotkeyConfig.encode() format, e.g. "alt+q"
    var contextMode: ContextMode
    var contextCount: Int      // used when contextMode == .clipboardHistory
    var outputStrategy: OutputStrategy
    var builtIn: Bool
    var createdAt: Date
    var updatedAt: Date

    static let temperatureRange: ClosedRange<Double> = 0.0 ... 2.0

    /// Built-in personas seeded on first launch. Order is stable.
    /// Built-ins: name + builtIn flag are immutable in UI; stylePrompt + icon
    /// + temperature + hotkey + contextMode + contextCount + outputStrategy editable.
    static func builtInSeeds() -> [Persona] {
        let now = Date()
        return [
            Persona(
                id: "builtin-default",
                name: "Default",
                icon: "sparkles",
                stylePrompt: """
                    You are a conservative speech recognition error corrector. \
                    ONLY fix clear, obvious transcription mistakes. When in doubt, leave the text unchanged.

                    What to fix:
                    - English words/acronyms wrongly rendered as sound-alike tokens \
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
                contextMode: .none,
                contextCount: 1,
                outputStrategy: .replaceFocusedText,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-translate",
                name: "Auto Translate",
                icon: "globe",
                stylePrompt: "Automatically detect the input language and translate it into English. Keep the tone professional and fluent. Return ONLY the translated text.",
                temperature: 0.6,
                hotkey: nil,
                contextMode: .none,
                contextCount: 1,
                outputStrategy: .replaceFocusedText,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-cli",
                name: "CLI Wizard",
                icon: "terminal",
                stylePrompt: "Convert voice transcription into executable shell commands. Be concise and accurate for technical users. Return ONLY the command, with no markdown fences.",
                temperature: 0.1,
                hotkey: nil,
                contextMode: .none,
                contextCount: 1,
                outputStrategy: .replaceFocusedText,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-context",
                name: "Context",
                icon: "text.quote",
                stylePrompt: """
                    You will receive three inputs:
                    1. [Selected text] — text currently selected in the foreground app (may be empty)
                    2. [Recent clipboard] — the most recent clipboard text (may be empty)
                    3. [User said] — the user's speech transcription

                    Use the context to infer the intent of [User said], then rewrite it into clearer and more accurate text.\
                    If context is empty, perform normal transcription correction. Return ONLY the rewritten text.
                    """,
                temperature: 0.5,
                hotkey: nil,
                contextMode: .selectionAndClipboard,
                contextCount: 1,
                outputStrategy: .replaceFocusedText,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
        ]
    }
}
