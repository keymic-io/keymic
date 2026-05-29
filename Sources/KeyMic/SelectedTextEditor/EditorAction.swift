import Foundation

/// Quick-action chips offered in the Selected Text Editor panel.
/// Each case maps to a fixed instruction template; `.freeForm` defers entirely to the user's typed/spoken instruction.
enum EditorAction: String, CaseIterable, Identifiable, Equatable {
    case expand
    case shrink
    case translate
    case polish
    case freeForm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .expand: return String(localized: "Expand")
        case .shrink: return String(localized: "Shrink")
        case .translate: return String(localized: "Translate")
        case .polish: return String(localized: "Polish")
        case .freeForm: return String(localized: "Custom…")
        }
    }

    var sfSymbol: String {
        switch self {
        case .expand: return "arrow.up.left.and.arrow.down.right"
        case .shrink: return "arrow.down.right.and.arrow.up.left"
        case .translate: return "character.bubble"
        case .polish: return "wand.and.stars"
        case .freeForm: return "text.cursor"
        }
    }

    /// Instruction text appended to the user's typed/spoken instruction when building the LLM prompt.
    /// `.freeForm` has an empty template — the user's text is the only instruction.
    var promptTemplate: String {
        switch self {
        case .expand:
            return "Expand the selected text by ~30% with relevant detail. Stay on topic."
        case .shrink:
            return "Make the selected text more concise. Preserve meaning. Aim for ~40% shorter."
        case .translate:
            return "Translate the selected text into English. Keep tone and terminology."
        case .polish:
            return "Polish grammar, clarity, and flow without changing meaning."
        case .freeForm:
            return ""
        }
    }
}
