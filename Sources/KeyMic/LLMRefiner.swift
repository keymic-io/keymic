import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "LLMRefiner")

/// Stateless LLM endpoint config + per-call refinement.
/// Persona-specific prompt + temperature are passed in by the caller.
@MainActor
final class LLMRefiner {
    static let shared = LLMRefiner()

    var apiBaseURL: String {
        get { UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "llmAPIBaseURL") }
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "llmAPIKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "llmAPIKey") }
    }

    var model: String {
        get { UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini" }
        set { UserDefaults.standard.set(newValue, forKey: "llmModel") }
    }

    /// True iff endpoint is fully configured (URL + apiKey + model).
    /// Cheap synchronous check — does not hit the network.
    var isReady: Bool {
        !apiKey.isEmpty && !apiBaseURL.isEmpty && !model.isEmpty
    }

    private var currentTask: URLSessionDataTask?

    /// Refine using a persona's stylePrompt + temperature. `userText` is the raw
    /// transcript; for context-aware personas the caller pre-formats it with
    /// [Selected text] / [Recent clipboard] / [User said] sections.
    func refine(
        _ userText: String,
        systemPrompt: String,
        temperature: Double,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard isReady else {
            completion(.failure(RefinerError.notReady))
            return
        }

        let baseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            completion(.failure(RefinerError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
            "temperature": temperature,
        ]

        logger.info("request — host=\(url.host ?? "?", privacy: .public) model=\(self.model, privacy: .public) temp=\(temperature, privacy: .public) userTextLen=\(userText.count, privacy: .public)")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("JSON serialization failed: \(error.localizedDescription, privacy: .public)")
            completion(.failure(error))
            return
        }

        currentTask?.cancel()
        currentTask = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                logger.error("network error: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data else {
                logger.error("invalid response — no data")
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let httpOK = (200..<300).contains(status)
            if httpOK, let content = LLMRefiner.extractContent(from: data) {
                let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.info("response — len=\(refined.count, privacy: .public)")
                DispatchQueue.main.async { completion(.success(refined)) }
                return
            }
            let errMsg = LLMRefiner.extractErrorMessage(from: data) ?? ""
            let preview = String(data: data.prefix(1024), encoding: .utf8) ?? "<non-utf8>"
            logger.error("invalid response — status=\(status, privacy: .public) bytes=\(data.count, privacy: .public) err=\(errMsg, privacy: .public) preview=\(preview, privacy: .public)")
            DispatchQueue.main.async { completion(.failure(RefinerError.httpError(status: status, message: errMsg))) }
        }
        currentTask?.resume()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Extract assistant content from a variety of response shapes:
    /// OpenAI chat (`choices[0].message.content`), legacy completions
    /// (`choices[0].text`), streaming-style final (`choices[0].delta.content`),
    /// Anthropic (`content[0].text`), SSE event streams, or a top-level
    /// `content|output|response|text|message|result` string.
    static func extractContent(from data: Data) -> String? {
        if let json = parseFirstJSONObject(data),
           let s = pickContent(from: json) {
            return s
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.contains("data:") && text.contains("\n") {
            var acc = ""
            var fallback: String? = nil
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload.isEmpty || payload == "[DONE]" { continue }
                guard let d = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let chunk = pickDelta(from: obj) { acc += chunk }
                else if let full = pickContent(from: obj) { fallback = full }
            }
            if !acc.isEmpty { return acc }
            if let fallback { return fallback }
        }
        // Plain text body (not JSON, not SSE).
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") {
            return trimmed
        }
        return nil
    }

    private static func pickContent(from json: [String: Any]) -> String? {
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let msg = first["message"] as? [String: Any], let c = msg["content"] as? String { return c }
            if let t = first["text"] as? String { return t }
            if let d = first["delta"] as? [String: Any], let c = d["content"] as? String { return c }
        }
        if let arr = json["content"] as? [[String: Any]] {
            let parts = arr.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }
            if !parts.isEmpty { return parts.joined() }
        }
        for key in ["content", "output", "response", "text", "message", "result"] {
            if let s = json[key] as? String { return s }
        }
        return nil
    }

    private static func pickDelta(from json: [String: Any]) -> String? {
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first,
           let d = first["delta"] as? [String: Any], let c = d["content"] as? String { return c }
        if let d = json["delta"] as? [String: Any], let c = d["text"] as? String { return c }
        return nil
    }

    /// Strict parse first, then fall back to scanning for the first balanced
    /// `{ ... }` block. Tolerates leading/trailing whitespace, BOM, or
    /// multiple-JSON-object bodies.
    private static func parseFirstJSONObject(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
            return json
        }
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(of: 0x7B) else { return nil } // '{'
        var depth = 0
        var inStr = false
        var esc = false
        for i in start..<bytes.count {
            let b = bytes[i]
            if esc { esc = false; continue }
            if inStr {
                if b == 0x5C { esc = true; continue }
                if b == 0x22 { inStr = false }
                continue
            }
            switch b {
            case 0x22: inStr = true
            case 0x7B: depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0 {
                    let slice = data.subdata(in: start..<(i + 1))
                    return try? JSONSerialization.jsonObject(with: slice) as? [String: Any]
                }
            default: break
            }
        }
        return nil
    }

    static func extractErrorMessage(from data: Data) -> String? {
        guard let json = parseFirstJSONObject(data) else { return nil }
        if let err = json["error"] as? [String: Any] {
            return (err["message"] as? String) ?? (err["type"] as? String) ?? (err["code"] as? String)
        }
        if let s = json["error"] as? String { return s }
        if let s = json["message"] as? String { return s }
        return nil
    }

    enum RefinerError: LocalizedError {
        case notReady
        case invalidURL
        case invalidResponse
        case httpError(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notReady: return "LLM endpoint not configured"
            case .invalidURL: return "Invalid API base URL"
            case .invalidResponse: return "Invalid response from LLM API"
            case .httpError(let status, let message):
                return "LLM API error (HTTP \(status)): \(message.isEmpty ? "no details" : message)"
            }
        }
    }
}
