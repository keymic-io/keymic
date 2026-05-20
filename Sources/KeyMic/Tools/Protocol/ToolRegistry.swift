import Foundation

public enum ToolRegistryError: Error, LocalizedError {
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            return "Tool with name '\(name)' is already registered."
        }
    }
}

/// Actor that owns the set of tools available to an agent.
///
/// Two registration paths:
/// - `register(_:)` silently overwrites any previous tool with the same name.
///   Use this when re-loading tools after config change.
/// - `registerThrowing(_:)` throws on duplicate name. Use this when populating
///   from a trusted source where collision is a bug.
public actor ToolRegistry {
    private var tools: [String: any Tool] = [:]

    public init() {}

    public func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    public func registerThrowing(_ tool: any Tool) throws {
        if tools[tool.name] != nil {
            throw ToolRegistryError.duplicateName(tool.name)
        }
        tools[tool.name] = tool
    }

    public func unregister(name: String) {
        tools.removeValue(forKey: name)
    }

    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    public func allNames() -> [String] {
        tools.keys.sorted()
    }

    public func all() -> [any Tool] {
        tools.values.map { $0 }
    }
}
