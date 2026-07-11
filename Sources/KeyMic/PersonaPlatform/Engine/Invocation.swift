import AppKit
import Foundation

struct ContextOverride: Equatable {
    let context: PersonaContext
    let sources: Set<ContextSource>
}

struct Invocation {
    let persona: Persona
    let transcript: String
    let originatingApp: NSRunningApplication?
    let outputOverride: InjectionStrategy?
    /// When set, `PersonaEngine.run` uses this user-curated context+sources
    /// instead of auto-gathering via `PersonaContextBuilder`. Used by the
    /// context console. `nil` keeps the existing auto-gather behavior.
    let contextOverride: ContextOverride?

    init(persona: Persona,
         transcript: String,
         originatingApp: NSRunningApplication?,
         outputOverride: InjectionStrategy?,
         contextOverride: ContextOverride? = nil) {
        self.persona = persona
        self.transcript = transcript
        self.originatingApp = originatingApp
        self.outputOverride = outputOverride
        self.contextOverride = contextOverride
    }
}

enum InvocationResult {
    case routed(text: String, via: InjectionStrategy, result: RouteResult)
    case bypassed(reason: BypassReason)
}

enum BypassReason {
    case emptyInput
}

enum InvocationError: Error {
    case llmFailed(underlying: Error)
    case cancelled
}
