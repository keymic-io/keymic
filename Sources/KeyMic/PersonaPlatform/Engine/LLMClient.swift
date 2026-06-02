import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "LLMClient")

protocol LLMClient: AnyObject {
    var isReady: Bool { get }
    func complete(systemPrompt: String,
                  userText: String,
                  temperature: Double) async throws -> String
    func cancel()
}

final class OpenAICompatibleLLMClient: LLMClient {
    private let defaults: UserDefaults
    private var currentTask: URLSessionDataTask?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var apiBaseURL: String {
        get { defaults.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: "llmAPIBaseURL") }
    }
    var apiKey: String {
        get { defaults.string(forKey: "llmAPIKey") ?? "" }
        set { defaults.set(newValue, forKey: "llmAPIKey") }
    }
    var model: String {
        get { defaults.string(forKey: "llmModel") ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: "llmModel") }
    }

    var isReady: Bool {
        !apiKey.isEmpty && !apiBaseURL.isEmpty && !model.isEmpty
    }

    func complete(systemPrompt: String,
                  userText: String,
                  temperature: Double) async throws -> String {
        guard isReady else { throw LLMClientError.notReady }

        let base = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw LLMClientError.invalidURL
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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("request — host=\(url.host ?? "?", privacy: .public) model=\(self.model, privacy: .public) temp=\(temperature, privacy: .public) userTextLen=\(userText.count, privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let httpOK = (200..<300).contains(status)
        if httpOK, let content = Self.extractContent(from: data) {
            let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("response — len=\(refined.count, privacy: .public)")
            return refined
        }
        let errMsg = Self.extractErrorMessage(from: data) ?? ""
        let preview = String(data: data.prefix(1024), encoding: .utf8) ?? "<non-utf8>"
        logger.error("invalid response — status=\(status, privacy: .public) bytes=\(data.count, privacy: .public) err=\(errMsg, privacy: .public) preview=\(preview, privacy: .public)")
        throw LLMClientError.invalidResponse(message: errMsg.isEmpty ? nil : errMsg)
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Parsers (verbatim from old LLMRefiner)

    static func extractContent(from data: Data) -> String? {
        if let json = parseFirstJSONObject(data), let s = pickContent(from: json) { return s }
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") { return trimmed }
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

    private static func parseFirstJSONObject(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
            return json
        }
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(of: 0x7B) else { return nil }
        var depth = 0; var inStr = false; var esc = false
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
}

enum LLMClientError: LocalizedError {
    case notReady
    case invalidURL
    case invalidResponse(message: String?)

    var errorDescription: String? {
        switch self {
        case .notReady: return "LLM endpoint not configured"
        case .invalidURL: return "Invalid API base URL"
        case .invalidResponse(let m):
            return m.map { "Invalid response: \($0)" } ?? "Invalid response from LLM API"
        }
    }
}

typealias LLMRefiner = OpenAICompatibleLLMClient

extension OpenAICompatibleLLMClient {
    static let shared = OpenAICompatibleLLMClient()

    func refine(
        _ userText: String,
        systemPrompt: String,
        temperature: Double,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            do {
                let refined = try await complete(
                    systemPrompt: systemPrompt,
                    userText: userText,
                    temperature: temperature
                )
                completion(.success(refined))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
