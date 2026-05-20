import Foundation

private final class ToolProtocolTests {
    static func main() throws {
        try testEchoToolBasicCall()
        try testEchoToolSchemaShape()
        print("ToolProtocolTests passed")
    }

    /// A minimal in-test Tool implementation to exercise the protocol.
    struct EchoTool: Tool {
        let name = "echo"
        let description = "Echoes back the input text."
        let parametersJSONSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "Text to echo"]
            ],
            "required": ["text"]
        ]

        func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
            struct Args: Decodable { let text: String }
            let args = try JSONDecoder().decode(Args.self, from: argumentsJSON)
            return args.text
        }
    }

    static func testEchoToolBasicCall() throws {
        let tool = EchoTool()
        let input = #"{"text":"hi"}"#.data(using: .utf8)!
        let context = ToolContext(workingDirectory: "/tmp")
        let result = try runAsync { try await tool.call(argumentsJSON: input, context: context) }
        guard result == "hi" else {
            throw TestFailure("expected 'hi', got '\(result)'")
        }
    }

    static func testEchoToolSchemaShape() throws {
        let tool = EchoTool()
        guard let type = tool.parametersJSONSchema["type"] as? String, type == "object" else {
            throw TestFailure("schema type missing or wrong")
        }
        guard tool.parametersJSONSchema["properties"] is [String: Any] else {
            throw TestFailure("schema properties missing")
        }
    }

    struct TestFailure: Error { let message: String; init(_ m: String) { message = m } }

    /// Bridge async → sync for the standalone test runner.
    static func runAsync<T>(_ work: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}

@main
private enum ToolProtocolTestRunner {
    static func main() throws {
        try ToolProtocolTests.main()
    }
}
