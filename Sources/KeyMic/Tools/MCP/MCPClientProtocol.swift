import Foundation
import MCP

public protocol MCPClientProtocol: AnyObject, Sendable {
    var serverName: String { get async }

    func listTools() async throws -> [MCP.Tool]
    func callTool(name: String, arguments: [String: Value]?) async throws -> (content: [MCP.Tool.Content], isError: Bool)
}
