import Foundation

@main
struct AgentConfigTests {
    static func main() {
        testEmptyDefaultsProducesPlaceholders()
        testAgentKeysWinOverLlmKeys()
        testLlmKeysProvideFallback()
        testMissingFieldsReportsKeyNames()
        testIsReadyOnlyWhenAllPopulated()
        testRunOptionsDefaults()
        print("AgentConfigTests passed")
    }

    static func makeDefaults(_ pairs: [String: String]) -> UserDefaults {
        let suite = "AgentConfigTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        for (k, v) in pairs { d.set(v, forKey: k) }
        return d
    }

    static func testEmptyDefaultsProducesPlaceholders() {
        let cfg = AgentConfig.fromDefaults(makeDefaults([:]))
        precondition(cfg.apiBaseURL == AgentConfig.defaultBaseURL)
        precondition(cfg.apiKey == "")
        precondition(cfg.model == AgentConfig.defaultModel)
        precondition(!cfg.isReady)
        precondition(cfg.missingFields == ["agentAPIKey"])
    }

    static func testAgentKeysWinOverLlmKeys() {
        let cfg = AgentConfig.fromDefaults(makeDefaults([
            "agentAPIBaseURL": "https://agent.example/v1",
            "agentAPIKey": "agent-key",
            "agentModel": "agent-model",
            "llmAPIBaseURL": "https://llm.example/v1",
            "llmAPIKey": "llm-key",
            "llmModel": "llm-model",
        ]))
        precondition(cfg.apiBaseURL == "https://agent.example/v1")
        precondition(cfg.apiKey == "agent-key")
        precondition(cfg.model == "agent-model")
        precondition(cfg.isReady)
    }

    static func testLlmKeysProvideFallback() {
        let cfg = AgentConfig.fromDefaults(makeDefaults([
            "llmAPIBaseURL": "https://llm.example/v1",
            "llmAPIKey": "llm-key",
            "llmModel": "llm-model",
        ]))
        precondition(cfg.apiBaseURL == "https://llm.example/v1")
        precondition(cfg.apiKey == "llm-key")
        precondition(cfg.model == "llm-model")
        precondition(cfg.isReady)
    }

    static func testMissingFieldsReportsKeyNames() {
        let cfg = AgentConfig(apiBaseURL: "", apiKey: "", model: "")
        precondition(cfg.missingFields == ["agentAPIBaseURL", "agentAPIKey", "agentModel"])
    }

    static func testIsReadyOnlyWhenAllPopulated() {
        precondition(!AgentConfig(apiBaseURL: "u", apiKey: "k", model: "").isReady)
        precondition(!AgentConfig(apiBaseURL: "u", apiKey: "", model: "m").isReady)
        precondition(!AgentConfig(apiBaseURL: "", apiKey: "k", model: "m").isReady)
        precondition(AgentConfig(apiBaseURL: "u", apiKey: "k", model: "m").isReady)
    }

    static func testRunOptionsDefaults() {
        let o = AgentRunOptions()
        precondition(o.maxSteps == 10)
        precondition(o.maxWallTime == 120)
        precondition(o.toolTimeout == 30)
        precondition(o.requestTimeout == 60)
    }
}
