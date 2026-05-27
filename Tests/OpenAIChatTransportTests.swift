import Foundation

@main
struct OpenAIChatTransportTests {
    static func main() async throws {
        try await testCompleteWithTextOnlyResponse()
        try await testCompleteWithToolCallsResponse()
        try await testCompleteRejectsNon2xx()
        try await testCompletePropagatesNetworkError()
        print("OpenAIChatTransportTests passed")
    }

    // MARK: - Helpers

    static func makeConfig() -> AgentConfig {
        AgentConfig(apiBaseURL: "https://stub.example/v1", apiKey: "test-key", model: "test-model")
    }

    static func sampleMessages() -> [WireMessage] {
        [WireMessage(role: "user", content: "hi", toolCalls: nil, toolCallId: nil)]
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    // MARK: - Cases

    static func testCompleteWithTextOnlyResponse() async throws {
        StubURLProtocol.handler = { request in
            precondition(request.url?.absoluteString == "https://stub.example/v1/chat/completions")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let body = """
            {"choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}]}
            """
            return (200, Data(body.utf8))
        }
        let transport = OpenAIChatTransport(session: session())
        let turn = try await transport.complete(
            messages: sampleMessages(),
            tools: [],
            config: makeConfig(),
            requestTimeout: 5,
            cancel: { false }
        )
        precondition(turn.content == "hello")
        precondition(turn.toolCalls.isEmpty)
    }

    static func testCompleteWithToolCallsResponse() async throws {
        StubURLProtocol.handler = { _ in
            let body = """
            {"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[
              {"id":"call_a","type":"function","function":{"name":"Read","arguments":"{\\"path\\":\\"/x\\"}"}}
            ]},"finish_reason":"tool_calls"}]}
            """
            return (200, Data(body.utf8))
        }
        let transport = OpenAIChatTransport(session: session())
        let turn = try await transport.complete(
            messages: sampleMessages(),
            tools: [],
            config: makeConfig(),
            requestTimeout: 5,
            cancel: { false }
        )
        precondition(turn.content == "")
        precondition(turn.toolCalls.count == 1)
        precondition(turn.toolCalls[0].id == "call_a")
        precondition(turn.toolCalls[0].name == "Read")
        precondition(turn.toolCalls[0].argumentsJSON == "{\"path\":\"/x\"}")
    }

    static func testCompleteRejectsNon2xx() async throws {
        StubURLProtocol.handler = { _ in
            (401, Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }
        let transport = OpenAIChatTransport(session: session())
        do {
            _ = try await transport.complete(
                messages: sampleMessages(),
                tools: [],
                config: makeConfig(),
                requestTimeout: 5,
                cancel: { false }
            )
            preconditionFailure("expected HTTP 401 to throw")
        } catch {
            // expected
            let msg = error.localizedDescription
            precondition(msg.contains("401") || msg.contains("bad key") || msg.contains("HTTP"),
                         "error should mention 401 or message; got: \(msg)")
        }
    }

    static func testCompletePropagatesNetworkError() async throws {
        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let transport = OpenAIChatTransport(session: session())
        do {
            _ = try await transport.complete(
                messages: sampleMessages(),
                tools: [],
                config: makeConfig(),
                requestTimeout: 5,
                cancel: { false }
            )
            preconditionFailure("expected URLError to propagate")
        } catch let e as URLError {
            precondition(e.code == .notConnectedToInternet)
        } catch {
            preconditionFailure("expected URLError, got: \(error)")
        }
    }
}

/// Minimal URLProtocol that hands off to a per-test closure.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
