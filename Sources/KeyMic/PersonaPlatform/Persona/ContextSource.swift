import Foundation

/// Where a persona pulls context from when assembling its LLM prompt.
/// Declared on `Persona.contextSources: Set<ContextSource>`. Order in this enum
/// defines the canonical section order in `PersonaContext.buildPrompt`.
enum ContextSource: String, Codable, CaseIterable, Hashable {
    /// Focused element's selected text (via SelectionTextProvider / LOR-17 SelectedTextReader).
    case selection
    /// Current `NSPasteboard.general.string(forType: .string)`.
    case clipboardTop
    /// Recent N items from ClipboardStore; N supplied by the consumer at prompt-build time.
    case clipboardHistory
    /// Placeholder — provider lands with LOR-20.
    case windowOCR

    var displayName: String {
        switch self {
        case .selection: return String(localized: "Selected text")
        case .clipboardTop: return String(localized: "Clipboard")
        case .clipboardHistory: return String(localized: "Clipboard history")
        case .windowOCR: return String(localized: "Window text")
        }
    }
}
