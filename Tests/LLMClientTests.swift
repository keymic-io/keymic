import Foundation

@main
struct LLMClientTestRunner {
    static func main() {
        // Pristine UserDefaults under a non-default suite → isReady is false.
        let suite = "io.keymic.app.llm-client.tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let client = OpenAICompatibleLLMClient(defaults: defaults)
        expect(!client.isReady, "fresh defaults → not ready")

        // Configure: ready iff URL + key + model all non-empty.
        defaults.set("https://api.example.com/v1", forKey: "llmAPIBaseURL")
        defaults.set("sk-xxxxx", forKey: "llmAPIKey")
        defaults.set("gpt-4o-mini", forKey: "llmModel")
        expect(client.isReady, "configured → ready")

        // extractContent handles OpenAI chat shape.
        let chat = #"{"choices":[{"message":{"content":"hi"}}]}"#.data(using: .utf8)!
        expect(OpenAICompatibleLLMClient.extractContent(from: chat) == "hi",
            "extractContent: OpenAI chat shape")

        // extractErrorMessage handles { error: { message: ... } }.
        let errJson = #"{"error":{"message":"rate limited"}}"#.data(using: .utf8)!
        expect(OpenAICompatibleLLMClient.extractErrorMessage(from: errJson) == "rate limited",
            "extractErrorMessage: nested .error.message")

        print("LLMClientTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
