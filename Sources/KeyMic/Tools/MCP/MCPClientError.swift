import Foundation

public enum MCPClientError: Error, LocalizedError, Sendable {
    case notConnected(server: String)
    case connectionFailed(server: String, reason: String)
    case connectionTimeout(server: String)
    case toolCallFailed(server: String, tool: String, reason: String)
    case toolCallTimeout(server: String, tool: String)
    case processLaunchFailed(server: String, reason: String)
    case serverNotFound(String)
    case authMissing(server: String, accountKey: String)
    case configInvalid(reason: String)
    case unsupportedTransport(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected(let server):
            return "MCP server '\(server)' is not connected."
        case .connectionFailed(let server, let reason):
            return "Failed to connect to MCP server '\(server)': \(reason)"
        case .connectionTimeout(let server):
            return "Timed out while connecting to MCP server '\(server)'."
        case .toolCallFailed(let server, let tool, let reason):
            return "MCP tool '\(tool)' on server '\(server)' failed: \(reason)"
        case .toolCallTimeout(let server, let tool):
            return "Timed out while calling MCP tool '\(tool)' on server '\(server)'."
        case .processLaunchFailed(let server, let reason):
            return "Failed to launch MCP server '\(server)': \(reason)"
        case .serverNotFound(let server):
            return "MCP server '\(server)' was not found in the current configuration."
        case .authMissing(let server, let accountKey):
            return "Missing credentials for MCP server '\(server)'. Expected Keychain account key '\(accountKey)'."
        case .configInvalid(let reason):
            return "The MCP configuration is invalid: \(reason)"
        case .unsupportedTransport(let transport):
            return "Unsupported MCP transport type '\(transport)'."
        }
    }
}
