import Foundation

@main
struct PersonaEngineTestRunner {
    static func main() {
        testInvocationBypassesEmptyInput()
        testInvocationResultRouted()
        testInvocationResultBypassed()
        testInvocationErrorLlmFailed()
        testInvocationErrorCancelled()
        testPersonaInjectionStrategyOverride()
        testPersonaContextSourcesUsed()
        testContextOverrideDefaultsNil()
        testContextOverrideRendersHistorySources()
        print("PersonaEngineTests passed")
    }

    // MARK: - Invocation / InvocationResult

    static func testInvocationBypassesEmptyInput() {
        let p = makePersona()
        let inv = Invocation(persona: p, transcript: "   ", originatingApp: nil, outputOverride: nil)
        let trimmed = inv.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        expect(trimmed.isEmpty, "whitespace-only transcript should be treated as empty")
    }

    static func testInvocationResultRouted() {
        let result: InvocationResult = .routed(text: "hello", via: .replaceFocusedText, result: .injected)
        if case .routed(let text, let via, let routeResult) = result {
            expect(text == "hello", "routed text should match")
            expect(via == .replaceFocusedText, "routed strategy should match")
            expect(routeResult == .injected, "route result should match")
        } else {
            fail("expected .routed")
        }
    }

    static func testInvocationResultBypassed() {
        let result: InvocationResult = .bypassed(reason: .emptyInput)
        if case .bypassed(let reason) = result {
            expect(reason == .emptyInput, "bypass reason should be .emptyInput")
        } else {
            fail("expected .bypassed")
        }
    }

    static func testInvocationErrorLlmFailed() {
        let underlying = NSError(domain: "test", code: 1)
        let error = InvocationError.llmFailed(underlying: underlying)
        if case .llmFailed(let e) = error {
            expect(e.localizedDescription == underlying.localizedDescription, "underlying error should match")
        } else {
            fail("expected .llmFailed")
        }
    }

    static func testInvocationErrorCancelled() {
        let error = InvocationError.cancelled
        if case .cancelled = error {} else { fail("expected .cancelled") }
    }

    // MARK: - Persona + Invocation integration

    static func testPersonaInjectionStrategyOverride() {
        let p = makePersona(injectionStrategy: .clipboard)
        let inv = Invocation(persona: p, transcript: "hi", originatingApp: nil, outputOverride: .replaceFocusedText)
        let resolved = inv.outputOverride ?? inv.persona.injectionStrategy
        expect(resolved == .replaceFocusedText, "outputOverride should win over persona.injectionStrategy")
    }

    static func testPersonaContextSourcesUsed() {
        let p = makePersona(contextSources: [.selection, .clipboardTop])
        expect(p.contextSources.contains(.selection), "should contain .selection")
        expect(p.contextSources.contains(.clipboardTop), "should contain .clipboardTop")
        expect(!p.contextSources.contains(.windowOCR), "should not contain .windowOCR")
    }

    static func testContextOverrideDefaultsNil() {
        let inv = Invocation(persona: makePersona(), transcript: "hi", originatingApp: nil, outputOverride: nil)
        expect(inv.contextOverride == nil, "contextOverride defaults to nil for existing call sites")
    }

    static func testContextOverrideRendersHistorySources() {
        // A persona that declares only .selection, but the console added clipboard-history
        // items. The override's sources must drive buildPrompt so history renders.
        let ctx = PersonaContext(selection: nil, clipboardTop: nil,
                                 clipboardHistory: ["h1", "h2"], windowOCR: nil)
        let override = ContextOverride(context: ctx, sources: [.clipboardHistory])
        let inv = Invocation(persona: makePersona(contextSources: [.selection]),
                             transcript: "T", originatingApp: nil, outputOverride: nil,
                             contextOverride: override)
        let prompt = inv.contextOverride!.context.buildPrompt(
            transcript: inv.transcript, sources: inv.contextOverride!.sources)
        let expected = "[Clipboard history]\n1. h1\n2. h2\n\n[User said]\nT"
        expect(prompt == expected, "override sources drive buildPrompt:\ngot: \(prompt)\nwant: \(expected)")
    }

    // MARK: - Helpers

    static func makePersona(
        contextSources: Set<ContextSource> = [],
        injectionStrategy: InjectionStrategy = .replaceFocusedText
    ) -> Persona {
        Persona(
            id: "test", name: "T", icon: "x", stylePrompt: "sys",
            temperature: 0.0, hotkey: nil,
            contextSources: contextSources,
            builtIn: false,
            createdAt: Date(), updatedAt: Date(),
            injectionStrategy: injectionStrategy
        )
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }

    static func fail(_ msg: String) -> Never {
        print("FAIL: \(msg)"); exit(1)
    }
}
