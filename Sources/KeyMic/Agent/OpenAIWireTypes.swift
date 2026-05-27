import Foundation

// MARK: - Request

/// Wire-level shape of a single message in the `messages` array sent to
/// `/v1/chat/completions`. Mirrors OpenAI's JSON exactly. The conversion
/// from `AgentMessage` happens inside `OpenAIChatTransport`.
struct WireMessage: Codable, Sendable, Equatable {
    let role: String                       // "system" / "user" / "assistant" / "tool"
    /// Always emitted (never omitted). Assistant turns with only `tool_calls`
    /// send `""`. OpenAI and every observed OpenAI-compatible endpoint accept
    /// empty-string content alongside `tool_calls`; omitting the field entirely
    /// has caused 400s on stricter endpoints.
    let content: String
    let toolCalls: [WireToolCall]?         // assistant only
    let toolCallId: String?                // tool only

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

/// Wire-level shape of a tool advertisement in the `tools` array.
struct WireTool: Codable, Sendable, Equatable {
    let type: String                       // always "function"
    let function: WireToolFunction
}

struct WireToolFunction: Codable, Sendable, Equatable {
    let name: String
    let description: String
    /// JSON Schema for the tool's parameters. Encoded via `JSONSerialization`
    /// (the underlying value is `[String: Any]` from `Tool.parametersJSONSchema`).
    let parameters: AnyJSON
}

struct ChatRequest: Codable, Sendable, Equatable {
    let model: String
    let messages: [WireMessage]
    let tools: [WireTool]?                 // omitted entirely when empty
    let toolChoice: String?                // "auto" when tools are present; nil otherwise

    enum CodingKeys: String, CodingKey {
        case model, messages, tools
        case toolChoice = "tool_choice"
    }
}

// MARK: - Response

/// Wire-level shape of a tool invocation produced by the assistant.
struct WireToolCall: Codable, Sendable, Equatable {
    let id: String
    let type: String                       // always "function"
    let function: WireToolCallFunction
}

struct WireToolCallFunction: Codable, Sendable, Equatable {
    let name: String
    let arguments: String                  // raw JSON string (may be empty)
}

/// A single message inside `ChatResponse.choices[i].message`.
struct WireChoiceMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String?                   // null when only tool_calls
    let toolCalls: [WireToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}

struct WireChoice: Codable, Sendable, Equatable {
    let index: Int
    let message: WireChoiceMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, message
        case finishReason = "finish_reason"
    }
}

struct ChatResponse: Codable, Sendable, Equatable {
    let id: String?
    let model: String?
    let choices: [WireChoice]
}

// MARK: - Parsed assistant turn (internal representation passed to AgentSession)

/// Distilled shape produced by `OpenAIChatTransport.complete(...)` for the loop's
/// consumption: just the assistant's content + tool_calls (mapped to `AgentToolCall`).
struct WireAssistantTurn: Sendable, Equatable {
    let content: String                    // empty string when assistant sent only tool_calls
    let toolCalls: [AgentToolCall]
}

// MARK: - AnyJSON

/// `Codable` wrapper around a `JSONSerialization`-compatible value, used so we can
/// embed `Tool.parametersJSONSchema` (a `[String: Any]` JSON Schema) inside a Codable
/// request body without losing fidelity.
struct AnyJSON: Codable, @unchecked Sendable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self.value = v; return }
        if let v = try? container.decode(Int.self) { self.value = v; return }
        if let v = try? container.decode(Double.self) { self.value = v; return }
        if let v = try? container.decode(String.self) { self.value = v; return }
        if let v = try? container.decode([AnyJSON].self) { self.value = v.map(\.value); return }
        if let v = try? container.decode([String: AnyJSON].self) {
            self.value = v.mapValues(\.value); return
        }
        if container.decodeNil() { self.value = NSNull(); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try AnyJSON.encodeValue(value, to: &container)
    }

    private static func encodeValue(_ v: Any, to container: inout SingleValueEncodingContainer) throws {
        switch v {
        case let x as Bool: try container.encode(x)
        case let x as Int: try container.encode(x)
        case let x as Int64: try container.encode(x)
        case let x as Double: try container.encode(x)
        case let x as String: try container.encode(x)
        case let x as [Any]: try container.encode(x.map(AnyJSON.init))
        case let x as [String: Any]: try container.encode(x.mapValues(AnyJSON.init))
        case is NSNull: try container.encodeNil()
        default:
            throw EncodingError.invalidValue(
                v,
                EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported JSON value: \(type(of: v))")
            )
        }
    }

    static func == (lhs: AnyJSON, rhs: AnyJSON) -> Bool {
        return jsonEquals(lhs.value, rhs.value)
    }

    private static func jsonEquals(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNull, is NSNull): return true
        case let (x as Bool, y as Bool): return x == y
        case let (x as Int, y as Int): return x == y
        case let (x as Double, y as Double): return x == y
        case let (x as String, y as String): return x == y
        case let (x as [Any], y as [Any]):
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy(jsonEquals)
        case let (x as [String: Any], y as [String: Any]):
            guard x.keys == y.keys else { return false }
            return x.allSatisfy { k, v in y[k].map { jsonEquals(v, $0) } ?? false }
        default: return false
        }
    }
}
