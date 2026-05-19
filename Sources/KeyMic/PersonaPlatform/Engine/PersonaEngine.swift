import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "PersonaEngine")

final class PersonaEngine {
    private let llmClient: LLMClient
    private let contextResolver: ContextResolver
    private let outputRouter: OutputRouter

    enum Progress {
        case resolvingContext
        case callingLLM
        case dispatchingOutput(OutputStrategy)
    }

    init(llmClient: LLMClient,
         contextResolver: ContextResolver,
         outputRouter: OutputRouter) {
        self.llmClient = llmClient
        self.contextResolver = contextResolver
        self.outputRouter = outputRouter
    }

    @discardableResult
    func run(_ invocation: Invocation,
             progress: ((Progress) -> Void)? = nil) async throws -> InvocationResult {
        // 1. Validate: at least one non-whitespace fragment.
        let nonEmpty = invocation.fragments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty else { return .bypassed(reason: .emptyInput) }

        // 2. Resolve context.
        progress?(.resolvingContext)
        try Task.checkCancellation()
        let allFragments = await contextResolver.resolve(persona: invocation.persona,
                                                          prefilled: invocation.fragments)

        // 3. Build prompt.
        try Task.checkCancellation()
        let userText = Self.buildUserText(from: allFragments)

        // 4. Call LLM. Check readiness first (no progress emit on bypass).
        guard llmClient.isReady else { return .bypassed(reason: .llmNotConfigured) }
        progress?(.callingLLM)
        try Task.checkCancellation()
        let refined: String
        do {
            refined = try await llmClient.complete(
                systemPrompt: invocation.persona.stylePrompt,
                userText: userText,
                temperature: invocation.persona.temperature
            )
        } catch is CancellationError {
            throw InvocationError.cancelled
        } catch {
            throw InvocationError.llmFailed(underlying: error)
        }

        // 5. Dispatch output.
        let strategy = invocation.outputOverride ?? invocation.persona.outputStrategy
        progress?(.dispatchingOutput(strategy))
        try Task.checkCancellation()
        do {
            try await outputRouter.dispatch(strategy, text: refined, origin: invocation.originAppBundleID)
        } catch {
            throw InvocationError.outputFailed(strategy: strategy, underlying: error)
        }
        return .injected(text: refined, via: strategy)
    }

    /// Build the user message by joining `[Header]\n<text>` sections in fragment order.
    /// Caps at 7500 UTF-16 units, snapped to character boundary (preserves surrogate pairs).
    static func buildUserText(from fragments: [TextFragment]) -> String {
        let sections: [String] = fragments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { frag in
                let header = headerFor(frag)
                return "\(header)\n\(frag.text)"
            }
        let joined = sections.joined(separator: "\n\n")
        if joined.utf16.count <= 7500 { return joined }
        var trimmed = ""
        for ch in joined {
            if trimmed.utf16.count + ch.utf16.count > 7500 { break }
            trimmed.append(ch)
        }
        return trimmed
    }

    private static func headerFor(_ frag: TextFragment) -> String {
        switch frag.source {
        case .voice: return "[User said]"
        case .selectedText: return "[Selected text]"
        case .clipboardItem:
            if let idx = frag.meta["index"], idx != "0" {
                return "[Clipboard #\(idx)]"
            }
            return "[Recent clipboard]"
        case .userTyped, .phoneInput: return "[Instruction]"
        case .ocrWindow: return "[Visible window text]"
        }
    }
}
