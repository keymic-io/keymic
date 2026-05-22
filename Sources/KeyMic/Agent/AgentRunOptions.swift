import Foundation

/// Tunables for one `AgentSession.run` invocation. Defaults are intentionally
/// conservative — Settings UI may override them.
public struct AgentRunOptions: Sendable {
    /// Maximum number of loop iterations before forcing termination with
    /// `.maxStepsExceeded`. Each iteration = one LLM round-trip + zero or more
    /// tool invocations.
    public var maxSteps: Int

    /// Maximum wall time for the entire run. Checked at each loop boundary.
    public var maxWallTime: TimeInterval

    /// Per-tool wall time. Exceeding this funnels back as `.toolResult(isError: true)`
    /// (the loop continues — does NOT abort the whole run).
    public var toolTimeout: TimeInterval

    /// Per-HTTP-request timeout passed to the transport's `URLSession`.
    public var requestTimeout: TimeInterval

    public init(
        maxSteps: Int = 10,
        maxWallTime: TimeInterval = 120,
        toolTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 60
    ) {
        self.maxSteps = maxSteps
        self.maxWallTime = maxWallTime
        self.toolTimeout = toolTimeout
        self.requestTimeout = requestTimeout
    }
}
