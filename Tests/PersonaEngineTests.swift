import Foundation

@main
struct PersonaEngineTestRunner {
    static func main() {
        Task {
            await runAll()
            print("PersonaEngineTests passed")
            exit(0)
        }
        RunLoop.main.run()
    }

    static func runAll() async {
        // 1. .bypassed(.emptyInput) when all fragments empty.
        let (engine1, _) = makeEngine(llmReady: true)
        let p = persona(.none)
        let inv1 = Invocation(persona: p, fragments: [], originAppBundleID: nil, outputOverride: nil)
        let r1 = try! await engine1.run(inv1)
        if case .bypassed(.emptyInput) = r1 {} else { fail("emptyInput expected, got \(r1)") }

        // 2. .bypassed(.llmNotConfigured) when LLM not ready.
        let (engine2, spy2) = makeEngine(llmReady: false)
        let inv2 = Invocation(
            persona: p,
            fragments: [TextFragment(source: .voice, text: "hi", meta: [:])],
            originAppBundleID: nil,
            outputOverride: nil
        )
        let r2 = try! await engine2.run(inv2)
        if case .bypassed(.llmNotConfigured) = r2 {} else { fail("llmNotConfigured expected") }
        expect(spy2.completeCalls == 0, "LLM not called when not ready")
        expect(spy2.dispatchCalls.isEmpty, "Router not called when LLM not ready")

        // 3. .injected happy path: voice → LLM → focusedText.
        let (engine3, spy3) = makeEngine(llmReady: true, llmResponse: "refined")
        let inv3 = Invocation(
            persona: persona(.none, output: .replaceFocusedText),
            fragments: [TextFragment(source: .voice, text: "raw voice", meta: [:])],
            originAppBundleID: "com.example.foo",
            outputOverride: nil
        )
        let r3 = try! await engine3.run(inv3)
        if case .injected(let text, let via) = r3 {
            expect(text == "refined", ".injected returns refined text")
            expect(via == .replaceFocusedText, ".injected returns strategy")
        } else { fail("injected expected, got \(r3)") }
        expect(spy3.completeCalls == 1, "LLM called once")
        expect(spy3.dispatchCalls.count == 1, "Router called once")
        expect(spy3.dispatchCalls[0].text == "refined", "Router got refined text")
        expect(spy3.dispatchCalls[0].origin == "com.example.foo", "Router got origin")

        // 4. .outputOverride wins over persona.outputStrategy.
        let (engine4, spy4) = makeEngine(llmReady: true, llmResponse: "x")
        let inv4 = Invocation(
            persona: persona(.none, output: .replaceFocusedText),
            fragments: [TextFragment(source: .userTyped, text: "go", meta: [:])],
            originAppBundleID: nil,
            outputOverride: .clipboard
        )
        let r4 = try! await engine4.run(inv4)
        if case .injected(_, let via) = r4 {
            expect(via == .clipboard, "outputOverride wins (got .clipboard)")
        } else { fail("injected expected") }
        expect(spy4.dispatchCalls[0].strategy == .clipboard, "Router got override strategy")

        // 5. Prompt assembly: source-tagged section headers in order.
        let (engine5, spy5) = makeEngine(llmReady: true, llmResponse: "ok")
        let inv5 = Invocation(
            persona: persona(.none, output: .replaceFocusedText),
            fragments: [
                TextFragment(source: .selectedText, text: "S", meta: [:]),
                TextFragment(source: .clipboardItem, text: "C", meta: [:]),
                TextFragment(source: .voice, text: "V", meta: [:]),
            ],
            originAppBundleID: nil,
            outputOverride: nil
        )
        _ = try! await engine5.run(inv5)
        let userText = spy5.completeCalls > 0 ? spy5.lastUserText : ""
        expect(userText.contains("[Selected text]\nS"), "user message has [Selected text]")
        expect(userText.contains("[Recent clipboard]\nC"), "user message has [Recent clipboard]")
        expect(userText.contains("[User said]\nV"), "user message has [User said]")

        // 6. LLM throws → engine rethrows .llmFailed.
        let (engine6, _) = makeEngine(llmReady: true, llmError: NSError(domain: "x", code: 1))
        let inv6 = Invocation(
            persona: persona(.none, output: .replaceFocusedText),
            fragments: [TextFragment(source: .voice, text: "v", meta: [:])],
            originAppBundleID: nil,
            outputOverride: nil
        )
        do {
            _ = try await engine6.run(inv6)
            fail(".llmFailed expected")
        } catch InvocationError.llmFailed(_) {
            // ok
        } catch {
            fail("expected .llmFailed, got \(error)")
        }
    }

    // MARK: helpers

    static func makeEngine(
        llmReady: Bool,
        llmResponse: String = "",
        llmError: Error? = nil
    ) -> (PersonaEngine, EngineSpy) {
        let spy = EngineSpy()
        spy.llmReady = llmReady
        spy.llmResponse = llmResponse
        spy.llmError = llmError
        return (
            PersonaEngine(
                llmClient: spy,
                contextResolver: ContextResolver(
                    selection: NilSource(.selectedText),
                    clipboard: NilSource(.clipboardItem),
                    clipboardHistory: NilHistory(),
                    windowOCR: NilSource(.ocrWindow)
                ),
                outputRouter: SpyRouter(spy: spy)
            ),
            spy
        )
    }

    static func persona(_ mode: ContextMode, output: OutputStrategy = .replaceFocusedText) -> Persona {
        Persona(
            id: "p", name: "p", icon: "x", stylePrompt: "sys",
            temperature: 0.0, hotkey: nil,
            contextMode: mode, contextCount: 1,
            outputStrategy: output,
            builtIn: false,
            createdAt: Date(), updatedAt: Date()
        )
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }

    static func fail(_ msg: String) -> Never {
        print("FAIL: \(msg)"); exit(1)
    }
}

final class EngineSpy: LLMClient, @unchecked Sendable {
    var llmReady = true
    var llmResponse = ""
    var llmError: Error?
    var completeCalls = 0
    var lastSystemPrompt = ""
    var lastUserText = ""
    var lastTemperature: Double = 0

    var dispatchCalls: [(strategy: OutputStrategy, text: String, origin: String?)] = []

    var isReady: Bool { llmReady }
    func complete(systemPrompt: String, userText: String, temperature: Double) async throws -> String {
        completeCalls += 1
        lastSystemPrompt = systemPrompt
        lastUserText = userText
        lastTemperature = temperature
        if let e = llmError { throw e }
        return llmResponse
    }
    func cancel() {}
}

final class SpyRouter: OutputRouter {
    private let spy: EngineSpy
    init(spy: EngineSpy) {
        self.spy = spy
        super.init(
            focusedText: NoopHandler(),
            replaceSelection: NoopHandler(),
            clipboard: NoopHandler(),
            openURLFactory: { _ in NoopHandler() }
        )
    }
    override func dispatch(_ strategy: OutputStrategy,
                           text: String, origin: String?,
                           options: StrategyOptions = .defaults) async throws {
        spy.dispatchCalls.append((strategy, text, origin))
    }
}

final class NoopHandler: OutputStrategyHandler {
    func dispatch(text: String, origin: String?, options: StrategyOptions) async throws {}
}

final class NilSource: ContextSource {
    let providedKind: TextSource
    init(_ k: TextSource) { providedKind = k }
    func read() async throws -> TextFragment? { nil }
}
final class NilHistory: ClipboardHistorySourceProtocol {
    func read(count: Int) async throws -> [TextFragment] { [] }
}
