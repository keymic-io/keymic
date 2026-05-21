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
/// Registration defaults to throwing on duplicate name; pass
/// `replacingExisting: true` to silently overwrite (e.g. when reloading
/// tools after a config change).
public actor ToolRegistry {
    private var tools: [String: any Tool] = [:]

    public init() {}

    /// Register a tool. Throws `ToolRegistryError.duplicateName` if a tool
    /// with the same name is already registered, unless `replacingExisting`
    /// is true (in which case the previous registration is silently
    /// overwritten).
    ///
    /// Default behavior is throw — this matches the principle that the
    /// safe path is unannotated. Pass `replacingExisting: true` only when
    /// you genuinely intend to overwrite (e.g. reloading tools after a
    /// config change).
    public func register(_ tool: any Tool, replacingExisting: Bool = false) throws {
        if !replacingExisting, tools[tool.name] != nil {
            throw ToolRegistryError.duplicateName(tool.name)
        }
        tools[tool.name] = tool
    }

    public func unregister(name: String) {
        tools.removeValue(forKey: name)
    }

    public func unregister(name: String, where shouldUnregister: @Sendable (any Tool) -> Bool) -> Bool {
        guard let tool = tools[name], shouldUnregister(tool) else {
            return false
        }
        tools.removeValue(forKey: name)
        return true
    }

    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    public func allNames() -> [String] {
        tools.keys.sorted()
    }

    /// Returns all registered tools sorted by name. Use this when feeding
    /// the toolset to an LLM — deterministic ordering maximizes prompt
    /// cache hit rate.
    public func all() -> [any Tool] {
        tools.keys.sorted().compactMap { tools[$0] }
    }
}
