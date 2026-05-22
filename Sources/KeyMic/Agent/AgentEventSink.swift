import Foundation
import os

/// Receives events emitted by `AgentSession.run`. Used by `AgentRunner` to fan
/// out events to logs / UI / notifications.
public protocol AgentEventSink: Sendable {
    func receive(_ event: AgentEvent) async
}

/// Logs each event via `os.Logger` (subsystem `io.keymic.app`, category `Agent`).
/// Arguments and assistant content are logged with `.private` privacy; metadata
/// (tool names, sizes, step indices) is `.public`.
public struct ConsoleSink: AgentEventSink {
    public static let shared = ConsoleSink()
    private static let logger = Logger(subsystem: "io.keymic.app", category: "Agent")

    public init() {}

    public func receive(_ event: AgentEvent) async {
        switch event {
        case .step(let i):
            Self.logger.info("step \(i, privacy: .public)")
        case .assistantMessage(let s):
            Self.logger.info("assistant len=\(s.count, privacy: .public) text=\(s, privacy: .private)")
        case .toolCall(let name, let args):
            Self.logger.info("toolCall name=\(name, privacy: .public) argsLen=\(args.count, privacy: .public)")
        case .toolResult(let name, let output, let isError):
            Self.logger.info("toolResult name=\(name, privacy: .public) outLen=\(output.count, privacy: .public) isError=\(isError, privacy: .public)")
        case .done:
            Self.logger.info("done")
        case .error(let err):
            Self.logger.error("error: \(err.localizedDescription, privacy: .public)")
        }
    }
}

/// Forwards each event to every contained sink, sequentially. If one sink throws,
/// the protocol does not allow propagation — failures are absorbed via async/await
/// non-throwing signature (sinks must absorb their own errors).
public struct TeeSink: AgentEventSink {
    private let sinks: [any AgentEventSink]
    public init(_ sinks: [any AgentEventSink]) { self.sinks = sinks }
    public func receive(_ event: AgentEvent) async {
        for sink in sinks { await sink.receive(event) }
    }
}
