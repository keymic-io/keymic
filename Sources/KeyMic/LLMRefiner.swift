import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "LLMRefiner")

private func logToFile(_ message: String) {
    let msg = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KeyMic.log")
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(msg.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logURL.path, contents: msg.data(using: .utf8))
    }
}

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

        logToFile("Request: \(url.absoluteString) model=\(model) temp=\(temperature)")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        currentTask = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                logToFile("Network error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
            logToFile("Refined response received (\(refined.count) chars)")
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
