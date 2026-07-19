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

        // Content-free adoption signals: built-in personas report their (fixed) name,
        // custom personas report their stable id — NEVER the user's style-prompt text.
        TelemetryService.shared.featureUsed("persona")
        TelemetryService.shared.personaInvoked(
            persona: invocation.persona.builtIn ? invocation.persona.name : invocation.persona.id,
            injectionStrategy: strategy.telemetryName)

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

        let context: PersonaContext
        let sources: Set<ContextSource>
        if let override = invocation.contextOverride {
            context = override.context
            sources = override.sources
        } else {
            context = await PersonaContextBuilder.build(
                for: invocation.persona,
                clipboardStore: clipboardStore,
                onStatusUpdate: onStatusUpdate
            )
            sources = invocation.persona.contextSources
        }
        let userText = context.buildPrompt(
            transcript: transcript,
            sources: sources
        )

        // Map cancellation to InvocationError.cancelled (not a bare CancellationError):
        // VoiceTrigger's generic catch falls back to injecting the raw transcript, which
        // must never happen for a cancelled run.
        if Task.isCancelled { throw InvocationError.cancelled }

        let refined: String
        do {
            refined = try await llmClient.complete(
                systemPrompt: invocation.persona.stylePrompt,
                userText: userText,
                temperature: invocation.persona.temperature
            )
        } catch is CancellationError {
            throw InvocationError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            // URLSession surfaces Swift Task cancellation as URLError(.cancelled),
            // NOT CancellationError — unify so callers see a single cancel signal.
            throw InvocationError.cancelled
        } catch {
            logger.error("LLM request failed: \(error.localizedDescription, privacy: .public)")
            throw InvocationError.llmFailed(underlying: error)
        }

        if Task.isCancelled { throw InvocationError.cancelled }

        // An empty LLM response is a deliberate "inject nothing" signal (personas
        // may return empty for meaningless / unrelated input). Do NOT fall back
        // to the raw transcript — that would inject exactly the noise the persona
        // filtered out.
        guard !refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .bypassed(reason: .emptyLLMResponse)
        }
        let finalText = refined
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
