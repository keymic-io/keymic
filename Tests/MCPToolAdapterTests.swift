import Foundation
import MCP

final class FakeMCPClient: MCPClientProtocol, @unchecked Sendable {
    let fakeServerName: String
    var tools: [MCP.Tool] = []
    var nextContent: [MCP.Tool.Content] = []
    var nextIsError = false
    var callCount = 0
    var lastToolName: String?
    var lastArguments: [String: Value]?

    init(serverName: String = "server") {
        self.fakeServerName = serverName
    }

    var serverName: String {
        get async { fakeServerName }
    }

    func listTools() async throws -> [MCP.Tool] {
        tools
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> (content: [MCP.Tool.Content], isError: Bool) {
        callCount += 1
        lastToolName = name
        lastArguments = arguments
        return (nextContent, nextIsError)
    }
}

@main
struct MCPToolAdapterTests {
    static func main() async throws {
        try await testPrefixedName()
        try await testFactorySchemaExtraction()
        try await testHappyPathCallsRemoteBareNameAndReturnsText()
        try await testErrorResultThrowsToolCallFailed()
        try await testJSONArgumentsConvertToMCPValues()
        try await testEmptyArgumentsBecomeNil()
        try await testNullArgumentsBecomeNil()
        try await testNonObjectArgumentsThrow()
        try await testTextContentFlatteningJoinsLines()
        try await testNonTextPlaceholders()
        try await testCancellationBeforeRemoteCall()
        try await testTruncationKeepsValidUTF8()
        print("MCPToolAdapterTests passed")
    }

    static func makeAdapter(client: FakeMCPClient) -> MCPToolAdapter {
        MCPToolAdapter(
            serverName: "server",
            remoteName: "remote",
            description: "Remote test tool",
            parametersJSONSchema: ["type": "object", "properties": [:]],
            client: client
        )
    }

    static func testPrefixedName() async throws {
        let adapter = makeAdapter(client: FakeMCPClient())
        assertEqual(adapter.name, "server.remote")
    }

    static func testFactorySchemaExtraction() async throws {
        let client = FakeMCPClient()
        let descriptor = MCP.Tool(
            name: "lookup",
            description: "Lookup records",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search query")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(10)
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        )

        let adapter = try MCPToolAdapter.make(from: descriptor, serverName: "mcp", client: client)

        assertEqual(adapter.name, "mcp.lookup")
        assertEqual(adapter.description, "Lookup records")
        assertEqual(adapter.parametersJSONSchema["type"] as? String, "object")
        let properties = adapter.parametersJSONSchema["properties"] as? [String: Any]
        let query = properties?["query"] as? [String: Any]
        assertEqual(query?["type"] as? String, "string")
        assertEqual(query?["description"] as? String, "Search query")
        let required = adapter.parametersJSONSchema["required"] as? [Any]
        assertEqual(required?.first as? String, "query")
    }

    static func testHappyPathCallsRemoteBareNameAndReturnsText() async throws {
        let client = FakeMCPClient()
        client.nextContent = [.text(text: "hello", annotations: nil, _meta: nil)]
        let adapter = makeAdapter(client: client)

        let output = try await adapter.call(argumentsJSON: Data("{\"q\":\"term\"}".utf8), context: ToolContext())

        assertEqual(output, "hello")
        assertEqual(client.callCount, 1)
        assertEqual(client.lastToolName, "remote")
        assertEqual(client.lastArguments?["q"], .string("term"))
    }

    static func testErrorResultThrowsToolCallFailed() async throws {
        let client = FakeMCPClient()
        client.nextIsError = true
        client.nextContent = [.text(text: "remote failed", annotations: nil, _meta: nil)]
        let adapter = makeAdapter(client: client)

        do {
            _ = try await adapter.call(argumentsJSON: Data("{}".utf8), context: ToolContext())
            fail("Expected toolCallFailed")
        } catch MCPClientError.toolCallFailed(let server, let tool, let reason) {
            assertEqual(server, "server")
            assertEqual(tool, "remote")
            assertEqual(reason, "remote failed")
        }
    }

    static func testJSONArgumentsConvertToMCPValues() async throws {
        let client = FakeMCPClient()
        client.nextContent = [.text(text: "ok", annotations: nil, _meta: nil)]
        let adapter = makeAdapter(client: client)
        let json = """
        {
          "string": "value",
          "int": 42,
          "double": 3.5,
          "bool": true,
          "null": null,
          "object": { "nested": false },
          "array": ["a", 2, 2.25, null]
        }
        """

        _ = try await adapter.call(argumentsJSON: Data(json.utf8), context: ToolContext())

        let args = try require(client.lastArguments, "Expected converted arguments")
        assertEqual(args["string"], .string("value"))
        assertEqual(args["int"], .int(42))
        assertEqual(args["double"], .double(3.5))
        assertEqual(args["bool"], .bool(true))
        assertEqual(args["null"], .null)
        assertEqual(args["object"], .object(["nested": .bool(false)]))
        assertEqual(args["array"], .array([.string("a"), .int(2), .double(2.25), .null]))
    }

    static func testEmptyArgumentsBecomeNil() async throws {
        let client = FakeMCPClient()
        client.nextContent = [.text(text: "ok", annotations: nil, _meta: nil)]
        let adapter = makeAdapter(client: client)

        _ = try await adapter.call(argumentsJSON: Data(), context: ToolContext())

        assertTrue(client.lastArguments == nil, "Expected nil arguments for empty Data")
    }

    static func testNullArgumentsBecomeNil() async throws {
        let client = FakeMCPClient()
        client.nextContent = [.text(text: "ok", annotations: nil, _meta: nil)]
        let adapter = makeAdapter(client: client)

        _ = try await adapter.call(argumentsJSON: Data("null".utf8), context: ToolContext())

        assertTrue(client.lastArguments == nil, "Expected nil arguments for top-level JSON null")
    }

    static func testNonObjectArgumentsThrow() async throws {
        let client = FakeMCPClient()
        let adapter = makeAdapter(client: client)

        do {
            _ = try await adapter.call(argumentsJSON: Data("[1,2,3]".utf8), context: ToolContext())
            fail("Expected non-object arguments to throw")
        } catch MCPClientError.toolCallFailed(let server, let tool, let reason) {
            assertEqual(server, "server")
            assertEqual(tool, "remote")
            assertEqual(reason, "arguments must be a JSON object")
        }
    }

    static func testTextContentFlatteningJoinsLines() async throws {
        let client = FakeMCPClient()
        client.nextContent = [
            .text(text: "first", annotations: nil, _meta: nil),
            .text(text: "second", annotations: nil, _meta: nil)
        ]
        let adapter = makeAdapter(client: client)

        let output = try await adapter.call(argumentsJSON: Data("{}".utf8), context: ToolContext())

        assertEqual(output, "first\nsecond")
    }

    static func testNonTextPlaceholders() async throws {
        let client = FakeMCPClient()
        client.nextContent = [
            .image(data: "abc", mimeType: "image/png", annotations: nil, _meta: nil),
            .audio(data: "def", mimeType: "audio/wav", annotations: nil, _meta: nil),
            .resource(resource: Resource.Content.text("body", uri: "file:///tmp/note.txt", mimeType: "text/plain")),
            .resourceLink(uri: "https://example.com", name: "Example", title: "Example Title", mimeType: "text/html")
        ]
        let adapter = makeAdapter(client: client)

        let output = try await adapter.call(argumentsJSON: Data("{}".utf8), context: ToolContext())

        assertTrue(output.contains("[image: image/png]"), "Expected image placeholder")
        assertTrue(output.contains("[audio: audio/wav]"), "Expected audio placeholder")
        assertTrue(output.contains("[resource: file:///tmp/note.txt text/plain]"), "Expected resource placeholder")
        assertTrue(output.contains("[resourceLink: Example https://example.com"), "Expected resourceLink placeholder")
    }

    static func testCancellationBeforeRemoteCall() async throws {
        let client = FakeMCPClient()
        let adapter = makeAdapter(client: client)

        do {
            _ = try await adapter.call(argumentsJSON: Data("{}".utf8), context: ToolContext(isCancelled: { true }))
            fail("Expected CancellationError")
        } catch is CancellationError {
            assertEqual(client.callCount, 0)
        }
    }

    static func testTruncationKeepsValidUTF8() async throws {
        let client = FakeMCPClient()
        client.nextContent = [.text(text: String(repeating: "你好abc", count: 20), annotations: nil, _meta: nil)]
        let adapter = makeAdapter(client: client)
        let context = ToolContext(maxOutputBytes: 60)

        let output = try await adapter.call(argumentsJSON: Data("{}".utf8), context: context)

        assertTrue(output.contains("[output truncated]"), "Expected truncation marker")
        assertTrue(output.data(using: .utf8) != nil, "Expected valid UTF-8")
        assertTrue(output.utf8.count <= 60, "Expected output to fit maxOutputBytes")
    }

    static func assertEqual<T: Equatable>(_ actual: T?, _ expected: T?, file: StaticString = #filePath, line: UInt = #line) {
        if actual != expected {
            fail("Expected \(String(describing: expected)), got \(String(describing: actual))", file: file, line: line)
        }
    }

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        if actual != expected {
            fail("Expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    static func assertTrue(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if !condition {
            fail(message, file: file, line: line)
        }
    }

    static func require<T>(_ value: T?, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        guard let value else {
            fail(message, file: file, line: line)
        }
        return value
    }

    static func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
        fputs("Assertion failed: \(message) at \(file):\(line)\n", stderr)
        exit(1)
    }
}
