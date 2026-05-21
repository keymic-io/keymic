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
        try await testManagerRegistersAdapterWithoutShadowingBuiltinToolName()
        try await testDisconnectUsesExplicitServerOwnershipForDottedNames()
        try await testOverlappingRemoteToolNamesStayNamespaced()
        print("MCPClientManagerTests passed")
    }

    static func testManagerRegistersAdapterWithoutShadowingBuiltinToolName() async throws {
        let registry = ToolRegistry()
        let manager = MCPClientManager()
        try await registry.register(DummyTool(name: "Read"))

        try await manager.registerAdapter(
            makeAdapter(serverName: "remote", remoteName: "Read"),
            forServer: "remote",
            registry: registry
        )

        let names = await registry.allNames()
        assertEqual(names, ["Read", "remote.Read"])
    }

    static func testDisconnectUsesExplicitServerOwnershipForDottedNames() async throws {
        let registry = ToolRegistry()
        let manager = MCPClientManager()
        try await registry.register(DummyTool(name: "Read"))
        try await manager.registerAdapter(makeAdapter(serverName: "a", remoteName: "X"), forServer: "a", registry: registry)
        try await manager.registerAdapter(makeAdapter(serverName: "a.b", remoteName: "X"), forServer: "a.b", registry: registry)
        try await manager.registerAdapter(makeAdapter(serverName: "b", remoteName: "X"), forServer: "b", registry: registry)

        await manager.disconnect(serverName: "a", registry: registry)

        let names = await registry.allNames()
        assertEqual(names, ["Read", "a.b.X", "b.X"])
        let status = await manager.status(for: "a")
        assertEqual(status?.state, .disconnected)
    }

    static func testOverlappingRemoteToolNamesStayNamespaced() async throws {
        let registry = ToolRegistry()
        let manager = MCPClientManager()
        try await manager.registerAdapter(makeAdapter(serverName: "alpha", remoteName: "Search"), forServer: "alpha", registry: registry)
        try await manager.registerAdapter(makeAdapter(serverName: "beta", remoteName: "Search"), forServer: "beta", registry: registry)

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

    static func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
        fputs("Assertion failed: \(message) at \(file):\(line)\n", stderr)
        exit(1)
    }
}
