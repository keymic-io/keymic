import Foundation

/// Stream of events emitted by `AgentSession.run`. Produced in the order:
/// optional initial `.step(0)`, then zero or more (`.assistantMessage`,
/// then per tool: `.toolCall` followed by `.toolResult`) interleavings,
/// then exactly one terminating `.done` or `.error`. No events follow the
/// terminator (the stream finishes).
public enum AgentEvent: Sendable {
    /// Emitted at the start of each iteration of the agent loop. `index` is 0-based.
    case step(index: Int)

    /// Assistant turn carrying non-empty text content. Suppressed when content is empty
    /// (e.g. when the assistant returns only `toolCalls`).
    case assistantMessage(String)

    /// LLM is invoking a tool. `argumentsJSON` is the raw JSON bytes (already
    /// coerced — empty arguments become `"{}"`).
    case toolCall(name: String, argumentsJSON: Data)

    /// Result of a single tool invocation. `isError = true` includes registry misses,
    /// permission denials, JSON-parse failures, timeouts, and tool `throws`.
    case toolResult(name: String, output: String, isError: Bool)

    /// LLM produced no `tool_calls` in the latest assistant turn — natural end of run.
    case done

    /// Terminating error: max steps / wall time exceeded, cancellation, not configured,
    /// or transport failure. The stream finishes immediately after this event.
    case error(AgentSessionError)
}
