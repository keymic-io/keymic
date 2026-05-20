import Foundation

private final class ToolProtocolTests {
    static func main() throws {
        try testEchoToolBasicCall()
        try testEchoToolSchemaShape()
        try testRegistryRegisterAndLookup()
        try testRegistryDuplicateNameThrows()
        try testRegistryReplaceExistingSucceeds()
        try testRegistrySortOrder()
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

    /// A second fixture used to verify allNames/all sort order.
    struct UpperEchoTool: Tool {
        let name = "UpperEcho"
        let description = "Echoes input uppercased."
        let parametersJSONSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"]
            ],
            "required": ["text"]
        ]

        func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
            struct Args: Decodable { let text: String }
            let args = try JSONDecoder().decode(Args.self, from: argumentsJSON)
            return args.text.uppercased()
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

    static func testRegistryRegisterAndLookup() throws {
        let registry = ToolRegistry()
        try runAsync {
            try await registry.register(EchoTool())
            let found = await registry.tool(named: "echo")
            guard found != nil else {
                throw TestFailure("registry could not find registered tool")
            }
            let all = await registry.allNames()
            guard all == ["echo"] else {
                throw TestFailure("allNames mismatch: \(all)")
            }
        }
    }

    static func testRegistryDuplicateNameThrows() throws {
        let registry = ToolRegistry()
        try runAsync {
            try await registry.register(EchoTool())
            do {
                try await registry.register(EchoTool())
                throw TestFailure("expected duplicate-name error")
            } catch ToolRegistryError.duplicateName(let n) where n == "echo" {
                // expected
            }
        }
    }

    static func testRegistryReplaceExistingSucceeds() throws {
        let registry = ToolRegistry()
        try runAsync {
            try await registry.register(EchoTool())
            // Same name, replacingExisting: true — should NOT throw.
            try await registry.register(EchoTool(), replacingExisting: true)
            let all = await registry.allNames()
            guard all == ["echo"] else {
                throw TestFailure("expected single 'echo', got: \(all)")
            }
        }
    }

    static func testRegistrySortOrder() throws {
        let registry = ToolRegistry()
        try runAsync {
            // Register in non-alphabetical order; expect sorted output.
            try await registry.register(EchoTool())          // "echo"
            try await registry.register(UpperEchoTool())     // "UpperEcho"

            // ASCII sort puts uppercase before lowercase: "UpperEcho" < "echo".
            let names = await registry.allNames()
            guard names == ["UpperEcho", "echo"] else {
                throw TestFailure("allNames order wrong: \(names)")
            }

            // all() should be sorted too.
            let tools = await registry.all()
            let toolNames = tools.map { $0.name }
            guard toolNames == ["UpperEcho", "echo"] else {
                throw TestFailure("all() order wrong: \(toolNames)")
            }
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
