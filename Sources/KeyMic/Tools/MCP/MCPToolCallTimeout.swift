import Foundation

struct MCPToolCallTimeoutError: Error {}

enum MCPToolCallTimeout {
    static func run<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () -> Void
    ) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await operation()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    throw MCPToolCallTimeoutError()
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch is MCPToolCallTimeoutError {
            onTimeout()
            throw MCPToolCallTimeoutError()
        }
    }
}
