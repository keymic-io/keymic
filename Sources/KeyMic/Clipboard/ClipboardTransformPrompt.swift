import Foundation

/// Pure helpers for the Clipboard Transformer LLM call.
/// Foundation-only so the standalone test runner can exercise it without AppKit/SwiftData.
enum ClipboardTransformPrompt {
    /// Per-item cap (UTF-16 units).
    static let perItemCap: Int = 50_000
    /// Combined input cap (UTF-16 units).
    static let combinedCap: Int = 100_000

    /// Fallback system prompt when the `builtin-clipboard-transformer` persona is missing.
    /// Mirrors the seed in `Persona.builtInSeeds()`.
    static let systemPromptFallback: String = """
        You will receive N clipboard items, each labelled [Item k]. Produce ONE concise output \
        that synthesises / summarises / reformats them according to the implicit user intent \
        (default: summarise into a single clear paragraph). Return ONLY the result — no preamble, \
        no item labels, no markdown fences. Preserve the dominant language of the inputs.
        """

    /// Builds the user message: `[Item k]\n<text>` blocks, blank-line separated.
    static func composeBatchUserMessage(items: [String]) -> String {
        items.enumerated()
            .map { idx, text in "[Item \(idx + 1)]\n\(text)" }
            .joined(separator: "\n\n")
    }

    /// Returns nil if within caps, else a localized error string.
    static func validateSize(items: [String]) -> String? {
        for (idx, text) in items.enumerated() {
            if text.utf16.count > perItemCap {
                return String(localized: "Item \(idx + 1) too large (\(text.utf16.count / 1024) KB > \(perItemCap / 1024) KB cap)")
            }
        }
        let combined = items.reduce(0) { $0 + $1.utf16.count }
        if combined > combinedCap {
            return String(localized: "Combined input too large (\(combined / 1024) KB > \(combinedCap / 1024) KB cap)")
        }
        return nil
    }
}
