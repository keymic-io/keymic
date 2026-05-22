import Foundation

/// Public, transport-agnostic shape of a tool invocation request.
/// `OpenAIChatTransport` translates `OpenAIWireTypes.WireToolCall` ↔ `AgentToolCall`
/// at its boundary, so consumers never see wire types directly.
public struct AgentToolCall: Sendable, Equatable, Codable {
    /// Opaque ID issued by the LLM; echoed back in `tool_result` so the LLM can
    /// correlate results to its earlier requests.
    public let id: String
    /// Tool name (matches `Tool.name`).
    public let name: String
    /// Raw JSON string from the LLM. May be empty (caller coerces to `"{}"`).
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// A single message in an agent conversation. Mirrors the OpenAI chat-completions
/// `messages` array shape so it can be round-tripped through the transport without
/// an additional mapping layer.
public struct AgentMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }

    public let role: Role
    /// Empty string is permitted for assistant turns whose only payload is `toolCalls`.
    public let content: String
    /// Non-nil only when `role == .assistant` and the assistant emitted tool_calls.
    public let toolCalls: [AgentToolCall]?
    /// Required when `role == .tool`. Matches an `AgentToolCall.id` from a prior assistant turn.
    public let toolCallId: String?

    public init(
        role: Role,
        content: String,
        toolCalls: [AgentToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    // MARK: - Convenience constructors

    public static func system(_ content: String) -> AgentMessage {
        AgentMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> AgentMessage {
        AgentMessage(role: .user, content: content)
    }

    public static func assistant(content: String, toolCalls: [AgentToolCall]? = nil) -> AgentMessage {
        AgentMessage(role: .assistant, content: content, toolCalls: toolCalls)
    }

    public static func tool(content: String, toolCallId: String) -> AgentMessage {
        AgentMessage(role: .tool, content: content, toolCallId: toolCallId)
    }
}
