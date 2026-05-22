import Foundation
import os

/// Multi-turn OpenAI tool-calling loop. One `run(...)` returns a fresh
/// `AsyncStream<AgentEvent>`. The actor itself holds no per-run state between
/// calls — `priorMessages` is supplied by the caller for chat continuity.
public actor AgentSession {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "AgentSession")

    private let registry: ToolRegistry
    private let config: AgentConfig
    private let transport: any _ChatTransport

    public init(
        registry: ToolRegistry,
        config: AgentConfig = .fromDefaults(),
        transport: OpenAIChatTransport = OpenAIChatTransport()
    ) {
        self.registry = registry
        self.config = config
        self.transport = transport
    }

    /// Test-only initializer accepting any `_ChatTransport`.
    init(
        registry: ToolRegistry,
        config: AgentConfig,
        anyTransport: any _ChatTransport
    ) {
        self.registry = registry
        self.config = config
        self.transport = anyTransport
    }

    public nonisolated func run(
        systemPrompt: String?,
        userMessage: String,
        allowedToolNames: Set<String>? = nil,
        priorMessages: [AgentMessage] = [],
        options: AgentRunOptions = AgentRunOptions(),
        toolContext: ToolContext = ToolContext()
    ) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let cancelByConsumer = CancelFlag()
            let task = Task { [self] in
                await self.runLoop(
                    systemPrompt: systemPrompt,
                    userMessage: userMessage,
                    allowedToolNames: allowedToolNames,
                    priorMessages: priorMessages,
                    options: options,
                    toolContext: toolContext,
                    cancelByConsumer: cancelByConsumer,
                    yield: { continuation.yield($0) }
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in
                cancelByConsumer.set()
                task.cancel()
            }
        }
    }

    private func runLoop(
        systemPrompt: String?,
        userMessage: String,
        allowedToolNames: Set<String>?,
        priorMessages: [AgentMessage],
        options: AgentRunOptions,
        toolContext: ToolContext,
        cancelByConsumer: CancelFlag,
        yield: @escaping (AgentEvent) -> Void
    ) async {
        // 1. Config pre-flight.
        guard config.isReady else {
            yield(.error(.notConfigured(missing: config.missingFields)))
            return
        }

        // 2. Compose initial messages.
        var messages: [AgentMessage] = []
        if let sp = systemPrompt, !sp.isEmpty {
            messages.append(.system(sp))
        }
        messages.append(contentsOf: priorMessages)
        messages.append(.user(userMessage))

        // 3. Snapshot tools + build wire schema.
        let allTools = await registry.all()
        let tools = allTools.filter { allowedToolNames?.contains($0.name) ?? true }
        let wireTools = ToolSchemaBuilder.build(tools)
        let toolsByName: [String: any Tool] = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        // 4. Compose cancellation predicate: caller + consumer + Task.
        let composedCancel: @Sendable () -> Bool = {
            toolContext.isCancelled() || cancelByConsumer.get() || Task.isCancelled
        }
        let composedCtx = ToolContext(
            workingDirectory: toolContext.workingDirectory,
            maxOutputBytes: toolContext.maxOutputBytes,
            isCancelled: composedCancel
        )

        // 5. Main loop.
        let startInstant = ContinuousClock().now
        var step = 0
        var didTerminate = false
        while step < options.maxSteps {
            if composedCancel() {
                yield(.error(.cancelled)); didTerminate = true; break
            }
            let elapsed = ContinuousClock().now - startInstant
            if elapsed >= .seconds(options.maxWallTime) {
                yield(.error(.maxWallTimeExceeded(limit: options.maxWallTime)))
                didTerminate = true; break
            }

            yield(.step(index: step))

            let turn: WireAssistantTurn
            do {
                turn = try await transport.complete(
                    messages: messages.map(Self.toWire),
                    tools: wireTools,
                    config: config,
                    requestTimeout: options.requestTimeout,
                    cancel: composedCancel
                )
            } catch is CancellationError {
                yield(.error(.cancelled)); didTerminate = true; break
            } catch {
                yield(.error(.transport(underlying: error))); didTerminate = true; break
            }

            if !turn.content.isEmpty {
                yield(.assistantMessage(turn.content))
            }
            messages.append(.assistant(content: turn.content, toolCalls: turn.toolCalls.isEmpty ? nil : turn.toolCalls))

            if turn.toolCalls.isEmpty {
                yield(.done); didTerminate = true; break
            }

            var loopTerminated = false
            for call in turn.toolCalls {
                let argsData: Data = call.argumentsJSON.isEmpty
                    ? Data("{}".utf8)
                    : Data(call.argumentsJSON.utf8)
                yield(.toolCall(name: call.name, argumentsJSON: argsData))

                let result = await invokeOneTool(
                    call: call,
                    argsData: argsData,
                    toolsByName: toolsByName,
                    ctx: composedCtx,
                    timeout: options.toolTimeout
                )

                yield(.toolResult(name: call.name, output: result.output, isError: result.isError))
                messages.append(.tool(content: result.output, toolCallId: call.id))

                if composedCancel() {
                    yield(.error(.cancelled)); didTerminate = true; loopTerminated = true; break
                }
            }
            if loopTerminated { break }

            step += 1
        }

        if !didTerminate && step == options.maxSteps {
            yield(.error(.maxStepsExceeded(limit: options.maxSteps)))
        }
    }

    /// Resolve, validate, time-bound, and invoke a single tool. Never throws.
    ///
    /// `toolsByName` is already filtered by `allowedToolNames` upstream — any
    /// tool name the LLM emits that isn't in this dictionary is either truly
    /// unregistered or was excluded by the allow-list. Either way the LLM sees
    /// "not registered" (defense-in-depth lookup; no separate "not allowed"
    /// branch needed because the LLM was never advertised those tools).
    private func invokeOneTool(
        call: AgentToolCall,
        argsData: Data,
        toolsByName: [String: any Tool],
        ctx: ToolContext,
        timeout: TimeInterval
    ) async -> (output: String, isError: Bool) {
        guard let tool = toolsByName[call.name] else {
            return ("tool '\(call.name)' not registered", true)
        }
        // Validate args parse as JSON object.
        do {
            let obj = try JSONSerialization.jsonObject(with: argsData)
            if !(obj is [String: Any]) {
                return ("invalid JSON arguments for tool '\(call.name)': not an object", true)
            }
        } catch {
            return ("invalid JSON arguments for tool '\(call.name)': \(error.localizedDescription)", true)
        }

        do {
            let output = try await withTimeout(seconds: timeout) {
                try await tool.call(argumentsJSON: argsData, context: ctx)
            }
            return (output, false)
        } catch is AgentTimeoutError {
            return ("tool '\(call.name)' timed out after \(Int(timeout))s", true)
        } catch is CancellationError {
            // Re-surface as a "tool was cancelled" result; the outer loop's
            // composedCancel() check will then transition the run to .error(.cancelled).
            return ("tool '\(call.name)' was cancelled", true)
        } catch {
            return ("tool '\(call.name)' failed: \(error.localizedDescription)", true)
        }
    }

    // MARK: - AgentMessage → WireMessage mapping

    nonisolated private static func toWire(_ m: AgentMessage) -> WireMessage {
        let wireToolCalls = m.toolCalls?.map { agent in
            WireToolCall(
                id: agent.id,
                type: "function",
                function: WireToolCallFunction(name: agent.name, arguments: agent.argumentsJSON)
            )
        }
        // `content` is always emitted; assistant turns with only tool_calls send "".
        // Tested in production against OpenAI, DeepSeek, qwen, and llama.cpp — all accept this.
        return WireMessage(
            role: m.role.rawValue,
            content: m.content,
            toolCalls: wireToolCalls,
            toolCallId: m.toolCallId
        )
    }
}

/// Sendable mutable boolean for cross-actor cancellation signalling.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
