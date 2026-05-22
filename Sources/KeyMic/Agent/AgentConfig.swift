import Foundation

/// Endpoint + credentials for the agent transport. Read from `UserDefaults`.
/// Falls back to the `llmAPI*` keys used by the voice-refinement `LLMRefiner`
/// when the agent-specific key is empty, so a user with an existing voice
/// configuration gets a zero-config agent.
public struct AgentConfig: Sendable, Equatable {
    public var apiBaseURL: String
    public var apiKey: String
    public var model: String

    /// Default base URL when neither `agentAPIBaseURL` nor `llmAPIBaseURL` is set.
    public static let defaultBaseURL = "https://api.openai.com/v1"
    /// Default model when neither `agentModel` nor `llmModel` is set.
    public static let defaultModel = "gpt-4o-mini"

    public init(apiBaseURL: String, apiKey: String, model: String) {
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.model = model
    }

    /// Reads agent keys; falls back to legacy llm* keys when the agent key is empty;
    /// final fallback is the static defaults.
    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> AgentConfig {
        let baseURL = nonEmpty(defaults.string(forKey: "agentAPIBaseURL"))
            ?? nonEmpty(defaults.string(forKey: "llmAPIBaseURL"))
            ?? defaultBaseURL
        let apiKey = nonEmpty(defaults.string(forKey: "agentAPIKey"))
            ?? nonEmpty(defaults.string(forKey: "llmAPIKey"))
            ?? ""
        let model = nonEmpty(defaults.string(forKey: "agentModel"))
            ?? nonEmpty(defaults.string(forKey: "llmModel"))
            ?? defaultModel
        return AgentConfig(apiBaseURL: baseURL, apiKey: apiKey, model: model)
    }

    /// Names of empty required fields (UserDefaults key names, in declaration order).
    public var missingFields: [String] {
        var missing: [String] = []
        if apiBaseURL.isEmpty { missing.append("agentAPIBaseURL") }
        if apiKey.isEmpty { missing.append("agentAPIKey") }
        if model.isEmpty { missing.append("agentModel") }
        return missing
    }

    /// True iff all required fields are non-empty.
    public var isReady: Bool { missingFields.isEmpty }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
