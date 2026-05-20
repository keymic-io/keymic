import Foundation

/// Cross-cutting state passed to every tool invocation.
///
/// Tools should consult this struct for working directory, output size
/// limits, and cancellation. Tools must not reach into globals.
public struct ToolContext: Sendable {
    /// Working directory for filesystem-relative paths.
    public let workingDirectory: String

    /// Maximum output size in bytes. Tools should truncate output that
    /// exceeds this. `0` means no limit.
    public let maxOutputBytes: Int

    /// Optional cancellation token. Tools should periodically call
    /// `try Task.checkCancellation()` if they perform long work.
    public let isCancelled: @Sendable () -> Bool

    public init(
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        maxOutputBytes: Int = 1_048_576,    // 1 MB default
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.workingDirectory = workingDirectory
        self.maxOutputBytes = maxOutputBytes
        self.isCancelled = isCancelled
    }
}
