import Foundation

public enum AgentSessionError: Error, LocalizedError, Sendable {
    /// One or more required `AgentConfig` fields were empty when `run` was called.
    /// `missing` lists the UserDefaults key names (e.g. `["agentAPIKey", "agentModel"]`).
    case notConfigured(missing: [String])

    /// Loop reached `AgentRunOptions.maxSteps` iterations without natural completion.
    case maxStepsExceeded(limit: Int)

    /// Total wall time exceeded `AgentRunOptions.maxWallTime`.
    case maxWallTimeExceeded(limit: TimeInterval)

    /// Consumer cancelled the wrapping `Task`, broke from the `for await`,
    /// or the caller-supplied `ToolContext.isCancelled()` returned `true`.
    case cancelled

    /// Network failure, HTTP non-2xx, or response decode failure. Underlying error preserved
    /// for logs (do not display directly to end users — wrap in your own message).
    case transport(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let missing):
            return "Agent is not configured. Missing: \(missing.joined(separator: ", "))."
        case .maxStepsExceeded(let limit):
            return "Agent stopped: exceeded max steps (\(limit))."
        case .maxWallTimeExceeded(let limit):
            return "Agent stopped: exceeded max wall time (\(Int(limit))s)."
        case .cancelled:
            return "Agent run was cancelled."
        case .transport(let underlying):
            return "Agent transport error: \(underlying.localizedDescription)"
        }
    }
}
