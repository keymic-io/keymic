import Foundation

public enum LocalToolRegistrar {
    public static func register(_ tools: [any Tool], in registry: ToolRegistry) async throws {
        for tool in tools {
            try await registry.register(tool, replacingExisting: true)
        }
    }
}
