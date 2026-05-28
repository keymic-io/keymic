import AppKit
import Foundation

struct Invocation {
    let persona: Persona
    let transcript: String
    let originatingApp: NSRunningApplication?
    let outputOverride: InjectionStrategy?
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
