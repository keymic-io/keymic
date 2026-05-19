import Foundation

/// Origin tag for a TextFragment. Persona prompt building keys on this.
enum TextSource: String, Codable {
    case voice           // SpeechEngine transcript
    case selectedText    // AX kAXSelectedTextAttribute
    case clipboardItem   // ClipboardStore current/history
    case userTyped       // R4 panel keystroke input
    case phoneInput      // R6 phone push
    case ocrWindow       // R2.3 focused window OCR
}

struct TextFragment: Equatable, Codable {
    let source: TextSource
    let text: String
    let meta: [String: String]

    init(source: TextSource, text: String, meta: [String: String] = [:]) {
        self.source = source
        self.text = text
        self.meta = meta
    }
}

/// One Persona invocation. Triggers construct, Engine consumes.
struct Invocation {
    let persona: Persona
    let fragments: [TextFragment]
    let originAppBundleID: String?
    let outputOverride: OutputStrategy?
}

enum InvocationResult {
    case injected(text: String, via: OutputStrategy)
    case bypassed(reason: BypassReason)
}

enum BypassReason {
    case llmNotConfigured
    case emptyInput
    case shellConfirmDenied
}

enum InvocationError: Error {
    case llmFailed(underlying: Error)
    case contextResolveFailed(source: TextSource, underlying: Error)
    case outputFailed(strategy: OutputStrategy, underlying: Error)
    case cancelled
}
