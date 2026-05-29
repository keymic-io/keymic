import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "PersonaEngine")

@MainActor
final class PersonaEngine {
    private let llmClient: LLMClient
    private let clipboardStore: ClipboardStore
    private let outputRouter: OutputRouter

    init(llmClient: LLMClient,
         clipboardStore: ClipboardStore,
         outputRouter: OutputRouter) {
        self.llmClient = llmClient
        self.clipboardStore = clipboardStore
        self.outputRouter = outputRouter
    }

    func cancel() {
        llmClient.cancel()
    }

    @discardableResult
    func run(
        _ invocation: Invocation,
        onStatusUpdate: @escaping (String) -> Void = { _ in }
    ) async throws -> InvocationResult {
        let transcript = invocation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return .bypassed(reason: .emptyInput)
        }

        let strategy = invocation.outputOverride ?? invocation.persona.injectionStrategy

        if !llmClient.isReady {
            let routeResult = await outputRouter.route(
                PersonaOutput(
                    text: transcript,
                    strategy: strategy,
                    originatingApp: invocation.originatingApp,
                    context: nil
                )
            )
            return .routed(text: transcript, via: strategy, result: routeResult)
        }

        let context = await PersonaContextBuilder.build(
            for: invocation.persona,
            clipboardStore: clipboardStore,
            onStatusUpdate: onStatusUpdate
        )
        let userText = context.buildPrompt(
            transcript: transcript,
            sources: invocation.persona.contextSources
        )

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
            logger.error("LLM request failed: \(error.localizedDescription, privacy: .public)")
            throw InvocationError.llmFailed(underlying: error)
        }

        try Task.checkCancellation()

        let finalText = refined.isEmpty ? transcript : refined
        let routeResult = await outputRouter.route(
            PersonaOutput(
                text: finalText,
                strategy: strategy,
                originatingApp: invocation.originatingApp,
                context: context
            )
        )
        return .routed(text: finalText, via: strategy, result: routeResult)
    }
}
