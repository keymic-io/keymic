import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "LLMRefiner")

/// Stateless LLM endpoint config + per-call refinement.
/// Persona-specific prompt + temperature are passed in by the caller.
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("invalid response — status=\(status, privacy: .public) bytes=\(data.count, privacy: .public)")
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("response — len=\(refined.count, privacy: .public)")
            DispatchQueue.main.async { completion(.success(refined)) }
        }
        currentTask?.resume()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    enum RefinerError: LocalizedError {
        case notReady
        case invalidURL
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notReady: return "LLM endpoint not configured"
            case .invalidURL: return "Invalid API base URL"
            case .invalidResponse: return "Invalid response from LLM API"
            }
        }
    }
}
