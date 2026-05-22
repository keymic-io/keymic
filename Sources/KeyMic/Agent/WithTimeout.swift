import Foundation

/// Thrown by `withTimeout` when the wrapped operation does not complete in time.
public struct TimeoutError: Error, LocalizedError {
    public let seconds: TimeInterval
    public init(seconds: TimeInterval) { self.seconds = seconds }
    public var errorDescription: String? { "Operation timed out after \(seconds)s" }
}

/// Runs `operation` with a wall-clock deadline. Returns the operation's value on
/// success; throws `TimeoutError` if the deadline elapses first; rethrows the
/// operation's own error otherwise.
///
/// Implementation uses a `TaskGroup` race between the operation and a `Task.sleep`.
/// The losing branch is cancelled — operations that honor cooperative cancellation
/// will stop promptly.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TimeoutError(seconds: seconds)
        }
        return result
    }
}
