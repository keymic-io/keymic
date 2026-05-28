import Foundation

enum ContextMode: String, Codable, CaseIterable {
    case none
    case selectionAndClipboard

    var displayName: String {
        switch self {
        case .none: return "None"
        case .selectionAndClipboard: return "Selection + Clipboard"
        }
    }
}

struct Persona: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String           // SF Symbol name
    var stylePrompt: String
    var temperature: Double    // 0.0 ... 2.0
    var hotkey: String?        // HotkeyConfig.encode() format, e.g. "alt+q"
    var contextMode: ContextMode
    var builtIn: Bool
    var createdAt: Date
    var updatedAt: Date

    static let temperatureRange: ClosedRange<Double> = 0.0 ... 2.0

    /// Built-in personas seeded on first launch. Order is stable.
    /// Built-ins: name + builtIn flag are immutable in UI; stylePrompt + icon + temperature + hotkey + contextMode editable.
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
                    - English words/acronyms wrongly rendered as Chinese characters \
                    (e.g. "配森" → "Python", "杰森" → "JSON", "阿皮爱" → "API")
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
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-translate",
                name: "Auto Translate",
                icon: "globe",
                stylePrompt: "自动识别输入语言并翻译为英文。保持专业、流畅的表达。Return ONLY the translated text.",
                temperature: 0.6,
                hotkey: nil,
                contextMode: .none,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-cli",
                name: "CLI Wizard",
                icon: "terminal",
                stylePrompt: "将语音转写为可执行的 shell 命令。简洁、准确，适合技术用户。Return ONLY the command, no markdown fences.",
                temperature: 0.1,
                hotkey: nil,
                contextMode: .none,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-context",
                name: "上下文",
                icon: "text.quote",
                stylePrompt: """
                    你将看到三段输入：
                    1. [Selected text] — 用户当前在前台应用中选中的文本（可能为空）
                    2. [Recent clipboard] — 最近一次剪贴板中的文本（可能为空）
                    3. [User said] — 用户语音输入的转写

                    请基于上下文理解 [User said] 的意图，改写为更连贯、更精准的文本。\
                    若上下文为空，则按常规纠错处理。Return ONLY the rewritten text.
                    """,
                temperature: 0.5,
                hotkey: nil,
                contextMode: .selectionAndClipboard,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
        ]
    }
}
