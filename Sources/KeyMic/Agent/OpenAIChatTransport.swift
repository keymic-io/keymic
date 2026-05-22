import Foundation
import os

/// Internal protocol existing only for test injection. Production has a single
/// conformer (`OpenAIChatTransport`). Do NOT add a second conformer without
/// also revisiting the architecture (per spec §4 invariant 2: no transport
/// abstraction in production).
protocol _ChatTransport: Sendable {
    func complete(
        messages: [WireMessage],
        tools: [WireTool],
        config: AgentConfig,
        requestTimeout: TimeInterval,
        cancel: @Sendable @escaping () -> Bool
    ) async throws -> WireAssistantTurn
}

/// Thrown by `OpenAIChatTransport` for HTTP non-2xx responses. Wraps the
/// status code and best-effort decoded error body.
public struct OpenAITransportError: Error, LocalizedError {
    public let statusCode: Int
    public let message: String?

    public var errorDescription: String? {
        if let message {
            return "HTTP \(statusCode): \(message)"
        }
        return "HTTP \(statusCode)"
    }
}

/// Single concrete transport: POST `{baseURL}/chat/completions`, decode response,
/// distill into `WireAssistantTurn`. Cooperative cancellation via the `cancel`
/// closure passed to `complete(...)`.
public struct OpenAIChatTransport: _ChatTransport, Sendable {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "OpenAIChatTransport")
    private let session: URLSession

    /// Defaults to a fresh ephemeral session; tests inject one with a URLProtocol stub.
    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func complete(
        messages: [WireMessage],
        tools: [WireTool],
        config: AgentConfig,
        requestTimeout: TimeInterval,
        cancel: @Sendable @escaping () -> Bool
    ) async throws -> WireAssistantTurn {
        let url = try buildURL(from: config.apiBaseURL)
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body = ChatRequest(
            model: config.model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: tools.isEmpty ? nil : "auto"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // deterministic prompt cache keys
        request.httpBody = try encoder.encode(body)

        Self.logger.info("POST chat/completions model=\(config.model, privacy: .public) toolsCount=\(tools.count) msgCount=\(messages.count)")

        if cancel() { throw CancellationError() }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        }

        if cancel() { throw CancellationError() }

        let httpResponse = response as? HTTPURLResponse
        let status = httpResponse?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let errMessage = extractErrorMessage(from: data)
            Self.logger.error("HTTP \(status) — \(errMessage ?? "<no message>", privacy: .public)")
            throw OpenAITransportError(statusCode: status, message: errMessage)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw OpenAITransportError(statusCode: status, message: "response has no choices")
        }
        let content = choice.message.content ?? ""
        let toolCalls: [AgentToolCall] = (choice.message.toolCalls ?? []).map { wire in
            AgentToolCall(id: wire.id, name: wire.function.name, argumentsJSON: wire.function.arguments)
        }
        return WireAssistantTurn(content: content, toolCalls: toolCalls)
    }

    private func buildURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/chat/completions") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(512), encoding: .utf8)
        }
        if let err = json["error"] as? [String: Any] {
            return (err["message"] as? String) ?? (err["type"] as? String)
        }
        return json["message"] as? String
    }
}
