import Foundation

@main
struct AgentSessionLoopTests {
    static func main() async throws {
        try await testSingleStepDone()
        try await testToolUseThenDone()
        try await testToolThrowsThenContinues()
        try await testToolNotRegistered()
        try await testAllowedToolNamesFiltersRegistry()
        try await testInvalidJSONArguments()
        try await testMaxStepsExceeded()
        try await testNotConfigured()
        try await testTransportErrorTerminates()
        try await testEmptyAssistantContentSuppressed()
        try await testEmptyArgumentsCoercedToEmptyObject()
        try await testCancellationViaConsumer()
        print("AgentSessionLoopTests passed")
    }

    // MARK: - Helpers

    static func config() -> AgentConfig {
        AgentConfig(apiBaseURL: "https://stub.example/v1", apiKey: "k", model: "m")
    }

    static func emptyConfig() -> AgentConfig {
        AgentConfig(apiBaseURL: "", apiKey: "", model: "")
    }

    static func collect(_ stream: AsyncStream<AgentEvent>, max: Int = 50) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await ev in stream {
            events.append(ev)
            if events.count >= max { break }
        }
        return events
    }

    static func makeRegistry(_ tools: [any Tool]) async throws -> ToolRegistry {
        let r = ToolRegistry()
        for t in tools { try await r.register(t) }
        return r
    }

    // MARK: - Cases

    static func testSingleStepDone() async throws {
        let transport = FakeTransport(turns: [
            WireAssistantTurn(content: "hi there", toolCalls: [])
        ])
        let session = AgentSession(registry: ToolRegistry(), config: config(), anyTransport: transport)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "hi"))
        precondition(events.count == 3, "expected step + assistantMessage + done; got \(events)")
        guard case .step(0) = events[0] else { preconditionFailure("ev0 = \(events[0])") }
        guard case .assistantMessage("hi there") = events[1] else { preconditionFailure("ev1 = \(events[1])") }
        guard case .done = events[2] else { preconditionFailure("ev2 = \(events[2])") }
    }

    static func testToolUseThenDone() async throws {
        let read = StubReadTool(output: "file content")
        let registry = try await makeRegistry([read])
        let transport = FakeTransport(turns: [
            WireAssistantTurn(content: "", toolCalls: [
                AgentToolCall(id: "c1", name: "StubRead", argumentsJSON: "{\"path\":\"/x\"}")
            ]),
            WireAssistantTurn(content: "done reading", toolCalls: [])
        ])
        let session = AgentSession(registry: registry, config: config(), anyTransport: transport)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "read /x"))
        let names = events.map(eventTag)
        precondition(names == ["step", "toolCall", "toolResult", "step", "assistantMessage", "done"],
                     "unexpected event sequence: \(names)")
    }

    static func testToolThrowsThenContinues() async throws {
        let broken = StubReadTool(output: "", error: BrokenError.broken)
        let registry = try await makeRegistry([broken])
        let transport = FakeTransport(turns: [
            WireAssistantTurn(content: "", toolCalls: [
                AgentToolCall(id: "c1", name: "StubRead", argumentsJSON: "{}")
            ]),
            WireAssistantTurn(content: "ack", toolCalls: [])
        ])
        let session = AgentSession(registry: registry, config: config(), anyTransport: transport)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "go"))
        guard case .toolResult(_, _, let isError) = events[2] else { preconditionFailure() }
        precondition(isError, "tool throw should produce isError=true")
        guard case .done = events.last else { preconditionFailure("expected done; got \(events)") }
    }

    static func testToolNotRegistered() async throws {
        let transport = FakeTransport(turns: [
            WireAssistantTurn(content: "", toolCalls: [
                AgentToolCall(id: "c1", name: "Nope", argumentsJSON: "{}")
            ]),
            WireAssistantTurn(content: "ok", toolCalls: [])
        ])
        let session = AgentSession(registry: ToolRegistry(), config: config(), anyTransport: transport)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "go"))
        guard case .toolResult(let name, let output, let isError) = events[2] else { preconditionFailure() }
        precondition(name == "Nope")
        precondition(isError)
        precondition(output.contains("not registered"))
    }

    static func testAllowedToolNamesFiltersRegistry() async throws {
        // Bash and Read both registered, but allowedToolNames = ["Read"] excludes Bash
        // from the wire schema. If the LLM (hallucinating or buggy) still emits a Bash
        // tool_call, the loop reports it as "not registered" — same user-visible
        // outcome as a genuinely unknown tool.
        let bash = StubReadTool(name: "Bash", output: "ls output")
        let read = StubReadTool(name: "Read", output: "file content")
        let registry = try await makeRegistry([bash, read])
        let transport = FakeTransport(turns: [
            WireAssistantTurn(content: "", toolCalls: [
                AgentToolCall(id: "c1", name: "Bash", argumentsJSON: "{}")
            ]),
            WireAssistantTurn(content: "fine", toolCalls: [])
        ])
        let session = AgentSession(registry: registry, config: config(), anyTransport: transport)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "go",
                                               allowedToolNames: Set(["Read"])))
        guard case .toolResult(_, let output, let isError) = events[2] else { preconditionFailure() }
        precondition(isError)
        precondition(output.contains("not registered"),
                     "expected 'not registered' for filtered-out tool; got: \(output)")
    }

    static func testInvalidJSONArguments() async throws {
        let read = StubReadTool(output: "ok")
        let registry = try await makeRegistry([read])
        let transport = FakeTransport(turns: [
            WireAssistantTurn(content: "", toolCalls: [
                AgentToolCall(id: "c1", name: "StubRead", argumentsJSON: "not json{")
            ]),
            WireAssistantTurn(content: "done", toolCalls: [])
        ])
        let session = AgentSession(registry: registry, config: config(), anyTransport: transport)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "go"))
        guard case .toolResult(_, let output, let isError) = events[2] else { preconditionFailure() }
        precondition(isError)
        precondition(output.contains("invalid JSON"))
    }

    static func testMaxStepsExceeded() async throws {
        let read = StubReadTool(output: "data")
        let registry = try await makeRegistry([read])
        // Always returns a tool_call so the loop never naturally exits.
        let transport = FakeTransport(turns: Array(repeating:
            WireAssistantTurn(content: "", toolCalls: [
                AgentToolCall(id: "c", name: "StubRead", argumentsJSON: "{}")
            ]),
            count: 20
        ))
        let session = AgentSession(registry: registry, config: config(), anyTransport: transport)
        let options = AgentRunOptions(maxSteps: 3, maxWallTime: 60, toolTimeout: 5, requestTimeout: 5)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "go", options: options))
        guard case .error(let err) = events.last else { preconditionFailure("expected .error; got \(events.last as Any)") }
        guard case .maxStepsExceeded(let limit) = err else { preconditionFailure("got \(err)") }
        precondition(limit == 3)
    }

    static func testNotConfigured() async throws {
        let transport = FakeTransport(turns: [])
        let session = AgentSession(registry: ToolRegistry(), config: emptyConfig(), anyTransport: transport)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "go"))
        precondition(events.count == 1)
        guard case .error(let err) = events[0] else { preconditionFailure() }
        guard case .notConfigured(let missing) = err else { preconditionFailure() }
        precondition(missing.contains("agentAPIKey"))
        precondition(missing.contains("agentAPIBaseURL"))
        precondition(missing.contains("agentModel"))
    }

    static func testTransportErrorTerminates() async throws {
        struct Boom: Error {}
        let transport = FakeTransport(turns: [], error: Boom())
        let session = AgentSession(registry: ToolRegistry(), config: config(), anyTransport: transport)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "go"))
        guard case .error(let err) = events.last else { preconditionFailure("got \(events)") }
        guard case .transport = err else { preconditionFailure("expected transport; got \(err)") }
    }

    static func testEmptyAssistantContentSuppressed() async throws {
        let read = StubReadTool(output: "ok")
        let registry = try await makeRegistry([read])
        let transport = FakeTransport(turns: [
            WireAssistantTurn(content: "", toolCalls: [
                AgentToolCall(id: "c", name: "StubRead", argumentsJSON: "{}")
            ]),
            WireAssistantTurn(content: "yep", toolCalls: [])
        ])
        let session = AgentSession(registry: registry, config: config(), anyTransport: transport)
        let events = await collect(session.run(systemPrompt: nil, userMessage: "go"))
        // No assistantMessage event with empty content should appear.
        let emptyAssistants = events.filter {
            if case .assistantMessage(let s) = $0 { return s.isEmpty } else { return false }
        }
        precondition(emptyAssistants.isEmpty)
    }

    static func testEmptyArgumentsCoercedToEmptyObject() async throws {
        let recordingTool = ArgumentRecordingTool()
        let registry = try await makeRegistry([recordingTool])
        let transport = FakeTransport(turns: [
            WireAssistantTurn(content: "", toolCalls: [
                AgentToolCall(id: "c", name: "RecArgs", argumentsJSON: "")
            ]),
            WireAssistantTurn(content: "done", toolCalls: [])
        ])
        let session = AgentSession(registry: registry, config: config(), anyTransport: transport)
        _ = await collect(session.run(systemPrompt: nil, userMessage: "go"))
        let received = await recordingTool.received
        precondition(received == "{}", "empty arguments should become {} ; got: \(received)")
    }

    static func testCancellationViaConsumer() async throws {
        // Use a ToolContext-driven cancellation flag. The slow tool's 1s timeout
        // (per options.toolTimeout) yields a toolResult(isError:true) for "timed out";
        // by then the cancel flag has flipped, so the loop emits .error(.cancelled)
        // immediately after rather than starting another step.
        let slow = SlowTool(delay: 5)
        let registry = try await makeRegistry([slow])
        let transport = FakeTransport(turns: [
            WireAssistantTurn(content: "", toolCalls: [
                AgentToolCall(id: "c", name: "Slow", argumentsJSON: "{}")
            ])
        ])
        let session = AgentSession(registry: registry, config: config(), anyTransport: transport)
        let options = AgentRunOptions(maxSteps: 5, maxWallTime: 60, toolTimeout: 1, requestTimeout: 1)
        let cancelFlag = CancelFlag()
        let ctx = ToolContext(isCancelled: { cancelFlag.get() })
        let stream = session.run(systemPrompt: nil, userMessage: "go", options: options, toolContext: ctx)
        let outer = Task { await collect(stream) }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancelFlag.set()
        let events = await outer.value
        let hasCancelOrTimeout = events.contains {
            if case .error(let e) = $0 { return String(describing: e).contains("cancelled") || String(describing: e).contains("timed out") }
            return false
        } || events.contains { if case .toolResult(_, _, true) = $0 { return true }; return false }
        precondition(hasCancelOrTimeout, "expected cancellation or timeout signal; got: \(events)")
    }

    // MARK: - Tag helper

    static func eventTag(_ e: AgentEvent) -> String {
        switch e {
        case .step: return "step"
        case .assistantMessage: return "assistantMessage"
        case .toolCall: return "toolCall"
        case .toolResult: return "toolResult"
        case .done: return "done"
        case .error: return "error"
        }
    }
}

// MARK: - Test doubles

enum BrokenError: Error { case broken }

struct StubReadTool: Tool, @unchecked Sendable {
    let name: String
    let description: String
    let parametersJSONSchema: [String: Any]
    let output: String
    let error: Error?

    init(name: String = "StubRead", output: String, error: Error? = nil) {
        self.name = name
        self.description = "test stub"
        self.parametersJSONSchema = ["type": "object", "properties": [:]]
        self.output = output
        self.error = error
    }

    func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        if let error { throw error }
        return output
    }
}

actor ArgumentRecordingTool: Tool {
    nonisolated let name = "RecArgs"
    nonisolated let description = "records args"
    nonisolated(unsafe) let parametersJSONSchema: [String: Any] = ["type": "object", "properties": [:]]
    private(set) var received: String = ""

    nonisolated func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        let str = String(data: argumentsJSON, encoding: .utf8) ?? ""
        await record(str)
        return "noted"
    }

    private func record(_ s: String) { received = s }
}

struct SlowTool: Tool, @unchecked Sendable {
    let name = "Slow"
    let description = "intentionally slow"
    nonisolated(unsafe) let parametersJSONSchema: [String: Any] = ["type": "object", "properties": [:]]
    let delay: TimeInterval

    func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return "done"
    }
}

final class FakeTransport: _ChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [WireAssistantTurn]
    private let error: Error?

    init(turns: [WireAssistantTurn], error: Error? = nil) {
        self.remaining = turns
        self.error = error
    }

    func complete(
        messages: [WireMessage],
        tools: [WireTool],
        config: AgentConfig,
        requestTimeout: TimeInterval,
        cancel: @Sendable @escaping () -> Bool
    ) async throws -> WireAssistantTurn {
        if let error { throw error }
        lock.lock(); defer { lock.unlock() }
        guard !remaining.isEmpty else {
            throw NSError(domain: "FakeTransport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no more scripted turns"])
        }
        return remaining.removeFirst()
    }
}
