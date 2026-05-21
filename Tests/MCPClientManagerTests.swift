import Foundation
import MCP

struct DummyTool: Tool {
    let name: String
    let description = "Dummy tool"
    nonisolated(unsafe) let parametersJSONSchema: [String: Any] = ["type": "object", "properties": [:]]

    func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        "ok"
    }
}

final class NeverCalledClient: MCPClientProtocol, @unchecked Sendable {
    let fakeServerName: String

    init(serverName: String) {
        self.fakeServerName = serverName
    }

    var serverName: String {
        get async { fakeServerName }
    }

    func listTools() async throws -> [MCP.Tool] {
        fatalError("NeverCalledClient.listTools should not be called")
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> (content: [MCP.Tool.Content], isError: Bool) {
        fatalError("NeverCalledClient.callTool should not be called")
    }
}

@main
struct MCPClientManagerTests {
    static func main() async throws {
        try await testMCPAdapterDoesNotShadowBuiltinToolName()
        try await testPerServerUnregisterLeavesOtherServersAndBuiltin()
        try await testOverlappingRemoteToolNamesStayNamespaced()
        print("MCPClientManagerTests passed")
    }

    static func testMCPAdapterDoesNotShadowBuiltinToolName() async throws {
        let registry = ToolRegistry()
        try await registry.register(DummyTool(name: "Read"))

        let adapter = MCPToolAdapter(
            serverName: "remote",
            remoteName: "Read",
            description: "Remote read",
            parametersJSONSchema: ["type": "object", "properties": [:]],
            client: NeverCalledClient(serverName: "remote")
        )
        try await registry.register(adapter)

        let names = await registry.allNames()
        assertEqual(names, ["Read", "remote.Read"])
    }

    static func testPerServerUnregisterLeavesOtherServersAndBuiltin() async throws {
        let registry = ToolRegistry()
        try await registry.register(DummyTool(name: "Read"))
        try await registry.register(makeAdapter(serverName: "a", remoteName: "X"))
        try await registry.register(makeAdapter(serverName: "b", remoteName: "X"))

        let namesToRemove = await registry.allNames().filter { $0.hasPrefix("a.") }
        for name in namesToRemove {
            await registry.unregister(name: name)
        }

        let names = await registry.allNames()
        assertEqual(names, ["Read", "b.X"])
    }

    static func testOverlappingRemoteToolNamesStayNamespaced() async throws {
        let registry = ToolRegistry()
        try await registry.register(makeAdapter(serverName: "alpha", remoteName: "Search"))
        try await registry.register(makeAdapter(serverName: "beta", remoteName: "Search"))

        let names = await registry.allNames()
        assertEqual(names, ["alpha.Search", "beta.Search"])
    }

    static func makeAdapter(serverName: String, remoteName: String) -> MCPToolAdapter {
        MCPToolAdapter(
            serverName: serverName,
            remoteName: remoteName,
            description: "Remote \(remoteName)",
            parametersJSONSchema: ["type": "object", "properties": [:]],
            client: NeverCalledClient(serverName: serverName)
        )
    }

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        if actual != expected {
            fail("Expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    static func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
        fputs("Assertion failed: \(message) at \(file):\(line)\n", stderr)
        exit(1)
    }
}
